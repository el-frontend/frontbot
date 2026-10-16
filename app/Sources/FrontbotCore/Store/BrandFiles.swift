import Foundation

public struct BrandFiles: Sendable {
    public let paths: AppPaths

    public init(paths: AppPaths) { self.paths = paths }

    private func checkId(_ id: String) throws(ValidationError) {
        guard UUID(uuidString: id) != nil else { throw ValidationError("Id inválido: \(id).") }
    }

    public func readGuide(brandId: String) throws -> String? {
        try checkId(brandId)
        let url = paths.guide(brandId)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try String(contentsOf: url, encoding: .utf8)
    }

    public func writeGuide(brandId: String, markdown: String) throws {
        try checkId(brandId)
        try write(markdown, to: paths.guide(brandId))
    }

    /// Borra la carpeta de la marca (guía e imágenes). Si no existe, no hace nada.
    public func deleteBrand(brandId: String) throws {
        try checkId(brandId)
        let dir = paths.brandDir(brandId)
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        try FileManager.default.removeItem(at: dir)
    }

    public func writeIdeaReport(ideaId: String, markdown: String) throws -> URL {
        try checkId(ideaId)
        let url = paths.ideaReport(ideaId)
        try write(markdown, to: url)
        return url
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}
