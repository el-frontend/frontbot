import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum AssetKind: String, Sendable {
    case image
    case guideSource = "guide_source"
    case logo
}

/// Copia archivos del usuario a la carpeta de la marca y los registra como `brand_asset`.
/// El tipo se detecta por contenido (bytes mágicos), nunca por la extensión.
public struct AssetImporter: Sendable {
    public static let maxImageBytes = 8 * 1024 * 1024
    /// Lado máximo de una imagen descargada: más grande cuesta cientos de MB al dibujarla.
    public static let maxImageSide = 8000
    let db: AppDatabase
    let paths: AppPaths

    public init(db: AppDatabase, paths: AppPaths) {
        self.db = db
        self.paths = paths
    }

    public func importImage(from url: URL, brandId: String) throws -> BrandAsset {
        try requireBrand(brandId)
        let data = try Data(contentsOf: url)
        if data.count > Self.maxImageBytes {
            let mb = Double(data.count) / 1_048_576
            throw ValidationError(String(localized: "La imagen pesa \(String(format: "%.1f", mb)) MB; el máximo es 8 MB."))
        }
        let ext: String
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { ext = "jpg" }
        else if data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { ext = "png" }
        else { throw ValidationError(String(localized: "Formato no admitido: solo JPEG o PNG.")) }
        return try store(data, ext: ext, kind: .image, brandId: brandId)
    }

    /// Imagen descargada (logo o foto). JPEG y PNG se guardan tal cual; WebP y GIF pasan a PNG (primer cuadro).
    public func importImage(data: Data, brandId: String, kind: AssetKind) throws -> BrandAsset {
        guard kind == .image || kind == .logo else { throw ValidationError(String(localized: "Tipo de imagen no válido.")) }
        try requireBrand(brandId)
        if data.count > Self.maxImageBytes { throw ValidationError(String(localized: "La imagen pesa más de 8 MB.")) }
        let isJPEG = data.starts(with: [0xFF, 0xD8, 0xFF])
        let isPNG = data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let isWebP = data.count >= 12 && data.prefix(4) == Data("RIFF".utf8) && data.subdata(in: 8..<12) == Data("WEBP".utf8)
        let isGIF = data.starts(with: Array("GIF8".utf8))
        guard isJPEG || isPNG || isWebP || isGIF else { throw ValidationError(String(localized: "Formato no admitido: solo JPEG, PNG, WebP o GIF.")) }
        try Self.checkDimensions(data)
        if isJPEG { return try store(data, ext: "jpg", kind: kind, brandId: brandId) }
        if isPNG { return try store(data, ext: "png", kind: kind, brandId: brandId) }
        return try store(try Self.pngData(from: data), ext: "png", kind: kind, brandId: brandId)
    }

    /// Lee el tamaño de la cabecera sin decodificar: rechaza lo ilegible y lo enorme (bombas de descompresión).
    static func checkDimensions(_ data: Data) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else {
            throw ValidationError(String(localized: "No se pudo leer la imagen."))
        }
        guard width <= maxImageSide, height <= maxImageSide else {
            throw ValidationError(String(localized: "La imagen mide \(width)×\(height) px; el máximo es \(maxImageSide) px por lado."))
        }
    }

    static func pngData(from data: Data) throws -> Data {
        let unreadable = ValidationError(String(localized: "No se pudo leer la imagen."))
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw unreadable }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { throw unreadable }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw unreadable }
        return out as Data
    }

    public func importGuidePDF(from url: URL, brandId: String) throws -> BrandAsset {
        try requireBrand(brandId)
        let data = try Data(contentsOf: url)
        guard data.starts(with: Array("%PDF".utf8)) else { throw ValidationError(String(localized: "El archivo no es un PDF.")) }
        return try store(data, ext: "pdf", kind: .guideSource, brandId: brandId)
    }

    private func requireBrand(_ brandId: String) throws {
        guard try db.brand(id: brandId) != nil else { throw ValidationError(String(localized: "No existe marca con id \(brandId).")) }
    }

    private func store(_ data: Data, ext: String, kind: AssetKind, brandId: String) throws -> BrandAsset {
        let id = UUID().uuidString
        let dir = paths.assetsDir(brandId)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("\(id).\(ext)")
        try data.write(to: dest, options: .atomic)
        let asset = BrandAsset(id: id, brandId: brandId, kind: kind.rawValue, path: dest.path, createdAt: .dbNow())
        do {
            try db.insertAsset(asset)
        } catch {
            try? FileManager.default.removeItem(at: dest)
            throw error
        }
        return asset
    }
}
