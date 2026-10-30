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

    /// Antes de reemplazar la guía guarda la anterior en `guide.prev.md`, para que nada la pise en silencio.
    public func writeGuide(brandId: String, markdown: String) throws {
        try checkId(brandId)
        if let current = try readGuide(brandId: brandId), current != markdown {
            try write(current, to: paths.previousGuide(brandId))
        }
        try write(markdown, to: paths.guide(brandId))
    }

    public func hasPreviousGuide(brandId: String) throws -> Bool {
        try checkId(brandId)
        return FileManager.default.fileExists(atPath: paths.previousGuide(brandId).path)
    }

    /// Intercambia la guía y la anterior: restaurar dos veces deja todo como estaba.
    public func restorePreviousGuide(brandId: String) throws {
        guard try hasPreviousGuide(brandId: brandId) else {
            throw ValidationError(String(localized: "No hay una guía anterior que restaurar."))
        }
        let fm = FileManager.default
        let guide = paths.guide(brandId), previous = paths.previousGuide(brandId)
        guard fm.fileExists(atPath: guide.path) else {
            try fm.moveItem(at: previous, to: guide)
            return
        }
        let tmp = paths.brandDir(brandId).appendingPathComponent("guide.swap-\(UUID().uuidString).md")
        try fm.moveItem(at: guide, to: tmp)
        try fm.moveItem(at: previous, to: guide)
        try fm.moveItem(at: tmp, to: previous)
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
