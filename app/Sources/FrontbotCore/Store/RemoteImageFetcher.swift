import Foundation

/// Trae una imagen pública para los assets de una marca. La red la toca la app, no el agente:
/// mismas protecciones que los datasets del laboratorio (solo https público, sin cookies, tope de bytes).
public struct RemoteImageFetcher: Sendable {
    public static let timeout: TimeInterval = 20
    let downloader: DatasetDownloader

    public init(downloader: DatasetDownloader = URLSessionDatasetDownloader(resourceTimeout: RemoteImageFetcher.timeout)) {
        self.downloader = downloader
    }

    public func fetch(_ raw: String) async throws -> Data {
        guard var parts = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = parts.scheme?.lowercased(), scheme == "https" || scheme == "http", parts.host?.isEmpty == false else {
            throw ValidationError(String(localized: "Solo se descargan imágenes de links http(s)."))
        }
        parts.scheme = "https"
        guard let url = parts.url else { throw ValidationError(String(localized: "Solo se descargan imágenes de links http(s).")) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("frontbot-image-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try await downloader.download(url, to: file, maxBytes: AssetImporter.maxImageBytes)
        return try Data(contentsOf: file)
    }
}
