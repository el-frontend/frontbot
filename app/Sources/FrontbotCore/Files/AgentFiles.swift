import Foundation

/// Acceso de un agente a los archivos del usuario: solo dentro de las carpetas que autorizó y nunca en los datos de la app.
/// Toda ruta se resuelve (`~`, `..`, enlaces simbólicos) antes de comprobar dónde cae.
public struct AgentFiles: Sendable {
    public static let maxReadBytes = 512_000
    public static let maxWriteBytes = 1_000_000
    public static let maxListEntries = 500

    public enum Kind: String, Sendable { case file, directory, symlink }
    public struct Entry: Equatable, Sendable {
        public let name: String
        public let kind: Kind
        public let size: Int?
    }
    public struct Listing: Equatable, Sendable { public let path: String; public let entries: [Entry]; public let truncated: Bool }
    public struct Contents: Equatable, Sendable { public let path: String; public let text: String; public let truncated: Bool }
    /// Escritura validada y pendiente de aprobación; no toca el disco hasta `commit`.
    public struct PreparedWrite: Equatable, Sendable {
        public let path: String
        public let content: String
        public let replaces: Bool
        public let previousSize: Int?
    }

    let folders: [String]
    let protected: [String]

    /// `folders`: las autorizadas por el usuario. `protected`: rutas vetadas aunque caigan dentro (datos de Frontbot).
    public init(folders: [String], protected: [URL]) {
        self.folders = folders.map { Self.realPath($0) ?? $0 }
        self.protected = protected.map { Self.realPath($0.path) ?? $0.path }
    }

    /// Carpeta que el usuario quiere autorizar: debe existir y no estar dentro de los datos de la app. Devuelve su ruta real.
    public static func validatedFolder(_ path: String, protected: [URL]) throws -> String {
        guard let real = realPath(path), isDirectory(real) else { throw ValidationError(String(localized: "\(path) no es una carpeta.")) }
        if protected.contains(where: { Self.path(real, isInside: realPath($0.path) ?? $0.path) }) {
            throw ValidationError(String(localized: "No se pueden autorizar carpetas dentro de los datos de Frontbot."))
        }
        return real
    }

    public func resolve(_ raw: String) throws -> URL {
        var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if path == "~" || path.hasPrefix("~/") { path = NSHomeDirectory() + path.dropFirst() }
        guard path.hasPrefix("/") else {
            throw ValidationError("Usa una ruta absoluta dentro de tus carpetas: \(folders.joined(separator: ", ")).")
        }
        // Se resuelve el tramo que existe; lo que falta (un archivo nuevo) no puede contener enlaces.
        var existing = URL(fileURLWithPath: path).standardized
        var missing: [String] = []
        while !Self.exists(existing.path) {
            missing.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        guard let real = Self.realPath(existing.path) else { throw ValidationError("No se puede resolver \(raw).") }
        let resolved = missing.reduce(URL(fileURLWithPath: real)) { $0.appendingPathComponent($1) }.path
        guard folders.contains(where: { Self.path(resolved, isInside: $0) }) else {
            throw ValidationError("\(raw) está fuera de tus carpetas autorizadas: \(folders.joined(separator: ", ")).")
        }
        guard !protected.contains(where: { Self.path(resolved, isInside: $0) }) else {
            throw ValidationError("Los datos de Frontbot no se pueden leer ni modificar con estas herramientas.")
        }
        return URL(fileURLWithPath: resolved)
    }

    public func list(_ raw: String) throws -> Listing {
        let dir = try resolve(raw)
        guard Self.isDirectory(dir.path) else { throw ValidationError("\(raw) no es una carpeta.") }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        let urls = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)
            .filter { url in !protected.contains { Self.path(url.path, isInside: $0) } }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let entries = urls.prefix(Self.maxListEntries).map { url -> Entry in
            let values = try? url.resourceValues(forKeys: Set(keys))
            let kind: Kind = values?.isSymbolicLink == true ? .symlink : values?.isDirectory == true ? .directory : .file
            return Entry(name: url.lastPathComponent, kind: kind, size: kind == .file ? values?.fileSize : nil)
        }
        return Listing(path: dir.path, entries: entries, truncated: urls.count > Self.maxListEntries)
    }

    public func read(_ raw: String) throws -> Contents {
        let url = try resolve(raw)
        guard Self.exists(url.path), !Self.isDirectory(url.path) else { throw ValidationError("No existe el archivo \(raw).") }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.maxReadBytes + 1) ?? Data()
        if data.prefix(8192).contains(0) { throw ValidationError("\(url.lastPathComponent) es un archivo binario: solo se leen archivos de texto.") }
        let truncated = data.count > Self.maxReadBytes
        return Contents(path: url.path, text: String(decoding: data.prefix(Self.maxReadBytes), as: UTF8.self), truncated: truncated)
    }

    public func prepareWrite(_ raw: String, content: String) throws -> PreparedWrite {
        guard content.utf8.count <= Self.maxWriteBytes else {
            throw ValidationError("El contenido supera \(Self.maxWriteBytes / 1_000) KB.")
        }
        let url = try resolve(raw)
        if Self.isDirectory(url.path) { throw ValidationError("\(raw) es una carpeta, no un archivo.") }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
        return PreparedWrite(path: url.path, content: content, replaces: Self.exists(url.path), previousSize: size)
    }

    /// Escribe lo aprobado. Se vuelve a resolver por si la ruta cambió (p. ej. un enlace) mientras esperaba.
    public func commit(_ write: PreparedWrite) throws {
        guard try resolve(write.path).path == write.path else { throw ValidationError("La ruta cambió mientras esperaba la aprobación.") }
        let url = URL(fileURLWithPath: write.path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try write.content.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: Rutas

    static func path(_ path: String, isInside root: String) -> Bool {
        root == "/" || path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    /// Sin seguir enlaces: un enlace roto también "existe" (y luego falla al resolverse).
    private static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
