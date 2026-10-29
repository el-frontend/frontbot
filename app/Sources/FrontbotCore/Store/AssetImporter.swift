import Foundation

public enum AssetKind: String, Sendable {
    case image
    case guideSource = "guide_source"
    case logo
}

/// Copia archivos del usuario a la carpeta de la marca y los registra como `brand_asset`.
/// El tipo se detecta por contenido (bytes mágicos), nunca por la extensión.
public struct AssetImporter: Sendable {
    public static let maxImageBytes = 8 * 1024 * 1024
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
