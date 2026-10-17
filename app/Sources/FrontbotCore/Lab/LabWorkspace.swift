import Foundation

/// Espacio de trabajo de un agente en su laboratorio. Toda ruta se resuelve (`..`, `\`, enlaces) y debe caer
/// dentro de su raíz: el tema, `shared/`, un skill asignado (solo lectura) o un dataset (solo lectura).
public struct LabWorkspace: Sendable {
    public static let maxFileBytes = 1_000_000
    public static let defaultMaxAgentBytes = 200_000_000
    public static let maxListEntries = 500

    let paths: AppPaths
    let db: AppDatabase
    public let agentId: String
    public let topicId: String?
    let maxAgentBytes: Int

    public init(paths: AppPaths, db: AppDatabase, agentId: String, topicId: String?, maxAgentBytes: Int = LabWorkspace.defaultMaxAgentBytes) {
        self.paths = paths
        self.db = db
        self.agentId = agentId
        self.topicId = topicId
        self.maxAgentBytes = maxAgentBytes
    }

    private enum Area { case topic, shared, skill, dataset }

    // MARK: Operaciones

    public func write(_ path: String, content: String) throws {
        guard content.utf8.count <= Self.maxFileBytes else { throw ValidationError("El archivo supera \(Self.maxFileBytes / 1_000_000) MB.") }
        let url = try resolve(path, forWriting: true)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            throw ValidationError("\(path) es una carpeta, no un archivo.")
        }
        let previous = Self.lstatSize(url.path) ?? 0
        let used = usedBytes
        guard used - previous + content.utf8.count <= maxAgentBytes else {
            throw ValidationError("Tu laboratorio llegó al límite de \(maxAgentBytes >= 1_000_000 ? "\(maxAgentBytes / 1_000_000) MB" : "\(maxAgentBytes) bytes"): borra o resume archivos antes de escribir más.")
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Tras crear las carpetas se vuelve a comprobar: ninguna puede haber sido un enlace.
        guard try resolve(path, forWriting: true).path == url.path else { throw ValidationError("Ruta fuera de tu laboratorio: \(path).") }
        try Data(content.utf8).write(to: url, options: .atomic)
    }

    public func read(_ path: String) throws -> (text: String, truncated: Bool) {
        let url = try resolve(path, forWriting: false)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
            throw ValidationError("No existe el archivo \(path).")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let cap = AgentFiles.maxReadBytes
        let data = try handle.read(upToCount: cap + 1) ?? Data()
        if data.prefix(8192).contains(0) { throw ValidationError("\(url.lastPathComponent) es un archivo binario: solo se leen archivos de texto.") }
        return (String(decoding: data.prefix(cap), as: UTF8.self), data.count > cap)
    }

    /// Sin argumento: la raíz del tema más los accesos a `shared/`, a los skills asignados y a los datasets.
    public func list(_ dir: String?) throws -> [String] {
        let trimmed = dir?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty || trimmed == "." {
            var result: [String] = []
            if topicId != nil { result += try entries(of: try resolve("", forWriting: false), prefix: "") }
            result.append("shared/")
            result += try assignedSkills().map { "skill:\($0.name)/" }
            let datasets = (try? FileManager.default.contentsOfDirectory(atPath: paths.datasetsDir.path)) ?? []
            result += datasets.filter { !$0.hasPrefix(".") }.sorted().map { "dataset:\($0)/" }
            return result
        }
        let url = try resolve(trimmed, forWriting: false)
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        guard !exists || isDir.boolValue else { throw ValidationError("\(trimmed) no es una carpeta.") }
        let prefix = trimmed.split(separator: "/").filter { $0 != "." }.joined(separator: "/")
        return try entries(of: url, prefix: prefix.isEmpty ? "" : prefix + "/")
    }

    /// Ruta real dentro de la raíz que le corresponde. Para escribir solo valen el tema y `shared/`.
    public func resolve(_ path: String, forWriting: Bool) throws -> URL {
        let outside = ValidationError("Ruta fuera de tu laboratorio: \(path).")
        guard !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0") else { throw outside }
        var parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init).filter { $0 != "." }
        guard !parts.contains("..") else { throw outside }
        guard Self.safeComponent(agentId) else { throw outside }

        let area: Area
        let base: URL
        if parts.first == "shared" {
            area = .shared
            base = paths.labSharedDir(agentId)
            parts.removeFirst()
        } else if let head = parts.first, head.hasPrefix("skill:") {
            area = .skill
            let name = String(head.dropFirst("skill:".count))
            guard Self.safeComponent(name) else { throw outside }
            guard try assignedSkills().contains(where: { $0.name == name }) else {
                throw ValidationError("El skill \(name) no está asignado a este agente.")
            }
            base = paths.skillDir(name)
            parts.removeFirst()
        } else if let head = parts.first, head.hasPrefix("dataset:") {
            area = .dataset
            let name = String(head.dropFirst("dataset:".count))
            guard Self.safeComponent(name) else { throw outside }
            base = paths.datasetDir(name)
            parts.removeFirst()
        } else {
            area = .topic
            guard let topicId, Self.safeComponent(topicId) else { throw ValidationError("Este trabajo no tiene un tema abierto donde guardar archivos.") }
            base = paths.labTopicDir(agentId, topicId)
        }
        if forWriting, area == .skill || area == .dataset {
            throw ValidationError("Los skills y los datasets son de solo lectura: escribe en tu tema o en shared/.")
        }

        // La raíz debe ser exactamente su carpeta bajo el padre real: si un script la cambió por un enlace, no vale.
        guard let parent = Self.resolveExisting(base.deletingLastPathComponent().path),
              let root = Self.resolveExisting(base.path),
              root == URL(fileURLWithPath: parent).appendingPathComponent(base.lastPathComponent).path else { throw outside }
        guard let resolved = Self.resolveExisting(parts.reduce(base) { $0.appendingPathComponent($1) }.path) else { throw outside }
        guard Self.path(resolved, isInside: root) else { throw outside }
        return URL(fileURLWithPath: resolved)
    }

    // MARK: Auxiliares

    var usedBytes: Int { Self.directorySize(paths.labDir(agentId)) }

    private func assignedSkills() throws -> [Skill] {
        try SkillLibrary(db: db, paths: paths).skills(assignedTo: agentId, activeOnly: true)
    }

    private func entries(of dir: URL, prefix: String) throws -> [String] {
        guard Self.lstatSize(dir.path) != nil else { return [] } // aún no se ha escrito nada
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        return names.prefix(Self.maxListEntries).map { name in
            var isDir: ObjCBool = false
            let url = dir.appendingPathComponent(name)
            // Un enlace se muestra como archivo: leerlo pasa por `resolve`, que decide si vale.
            let isLink = (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
            let directory = !isLink && FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
            return prefix + name + (directory ? "/" : "")
        }
    }

    /// Un nombre suelto (agente, tema, skill, dataset) que no puede salirse de su carpeta.
    static func safeComponent(_ s: String) -> Bool {
        !s.isEmpty && s != "." && s != ".." && !s.contains("/") && !s.contains("\\") && !s.contains("\0")
    }

    /// Resuelve enlaces del tramo que existe; lo que falta (un archivo nuevo) no puede contener ninguno.
    static func resolveExisting(_ full: String) -> String? {
        var existing = URL(fileURLWithPath: full).standardized
        var tail: [String] = []
        while lstatSize(existing.path) == nil {
            guard existing.path != "/" else { return nil }
            tail.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        guard let real = realpath(existing.path, nil) else { return nil }
        defer { free(real) }
        return tail.reduce(URL(fileURLWithPath: String(cString: real))) { $0.appendingPathComponent($1) }.path
    }

    static func path(_ path: String, isInside root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    /// Tamaño sin seguir enlaces; `nil` si no existe (un enlace roto sí existe).
    static func lstatSize(_ path: String) -> Int? {
        var info = stat()
        return lstat(path, &info) == 0 ? Int(info.st_size) : nil
    }

    static func directorySize(_ dir: URL) -> Int {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return 0 }
        var total = 0
        for case let url as URL in e {
            var info = stat()
            if lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG { total += Int(info.st_size) }
        }
        return total
    }
}
