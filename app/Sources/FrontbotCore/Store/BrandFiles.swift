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

    public static let guideHistoryLimit = 10

    /// Antes de reemplazar la guía guarda la actual en el historial, para que nada la pise en silencio
    /// (ni siquiera varias escrituras seguidas del agente).
    public func writeGuide(brandId: String, markdown: String) throws {
        try checkId(brandId)
        if let current = try readGuide(brandId: brandId), current != markdown {
            try pushHistory(current, brandId: brandId)
        }
        try write(markdown, to: paths.guide(brandId))
    }

    public func hasPreviousGuide(brandId: String) throws -> Bool {
        try checkId(brandId)
        return !(try history(brandId)).isEmpty
    }

    /// Deshace la última escritura: vuelve a la versión anterior y la saca del historial.
    public func restorePreviousGuide(brandId: String) throws {
        try checkId(brandId)
        guard let last = try history(brandId).last else {
            throw ValidationError(String(localized: "No hay una guía anterior que restaurar."))
        }
        try write(try String(contentsOf: last, encoding: .utf8), to: paths.guide(brandId))
        try FileManager.default.removeItem(at: last)
    }

    /// Archivos del historial, del más viejo al más nuevo (nombres numerados con ceros a la izquierda).
    private func history(_ brandId: String) throws -> [URL] {
        let dir = paths.guideHistoryDir(brandId)
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func pushHistory(_ text: String, brandId: String) throws {
        var files = try history(brandId)
        let next = (files.last.flatMap { Int($0.deletingPathExtension().lastPathComponent) } ?? 0) + 1
        try write(text, to: paths.guideHistoryDir(brandId).appendingPathComponent(String(format: "%08d.md", next)))
        files = try history(brandId)
        for old in files.dropLast(Self.guideHistoryLimit) { try FileManager.default.removeItem(at: old) }
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
