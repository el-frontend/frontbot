import Foundation

/// `tool.brands_import_image`: descarga una imagen pública a los assets de la marca.
/// Asíncrona (va a la red) y con tope por corrida, para que una página no llene la marca de imágenes.
public actor ImageImportTool {
    public static let maxLogos = 1
    public static let maxImages = 8

    let importer: AssetImporter
    let fetcher: RemoteImageFetcher
    private var used: [String: (logos: Int, images: Int)] = [:]

    public init(importer: AssetImporter, fetcher: RemoteImageFetcher = RemoteImageFetcher()) {
        self.importer = importer
        self.fetcher = fetcher
    }

    public func handle(_ params: JSONValue) async throws -> JSONValue {
        guard let runId = params["run_id"]?.stringValue, let brandId = params["brand_id"]?.stringValue,
              let url = params["url"]?.stringValue, let rawKind = params["kind"]?.stringValue else {
            throw ValidationError("Faltan run_id, brand_id, url o kind.")
        }
        guard let kind = AssetKind(rawValue: rawKind), kind == .image || kind == .logo else {
            throw ValidationError("kind debe ser image o logo.")
        }
        guard try importer.db.brand(id: brandId) != nil else { throw ValidationError("No existe marca con id \(brandId).") }
        // El cupo se reserva antes de descargar (el actor se suelta en el await) y se devuelve si algo falla.
        var count = used[runId] ?? (0, 0)
        if kind == .logo {
            guard count.logos < Self.maxLogos else { throw ValidationError("Ya importaste 1 logo en esta corrida.") }
            count.logos += 1
        } else {
            guard count.images < Self.maxImages else { throw ValidationError("Ya importaste 8 imágenes en esta corrida.") }
            count.images += 1
        }
        used[runId] = count
        do {
            let data = try await fetcher.fetch(url)
            let asset = try importer.importImage(data: data, brandId: brandId, kind: kind)
            return ["asset_id": .string(asset.id), "kind": .string(asset.kind)]
        } catch {
            if var current = used[runId] {
                if kind == .logo { current.logos -= 1 } else { current.images -= 1 }
                used[runId] = current
            }
            throw error
        }
    }

    public func endRun(_ runId: String) {
        used[runId] = nil
    }
}
