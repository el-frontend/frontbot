import Foundation
import GRDB

/// Biblioteca común de skills: carpetas estándar (`SKILL.md` + archivos) indexadas en SQLite.
public struct SkillLibrary: Sendable {
    let db: AppDatabase
    let paths: AppPaths

    public init(db: AppDatabase, paths: AppPaths) {
        self.db = db
        self.paths = paths
    }

    static let scriptExtensions: Set<String> = ["py", "sh", "bash", "js", "mjs", "cjs", "ts", "rb", "pl"]
    static let maxDraftFiles = 20
    static let maxDraftFileBytes = 200_000

    public func directory(for skill: Skill) -> URL { paths.skillDir(skill.name) }

    // MARK: Consultas

    public func all() throws -> [Skill] {
        try db.writer.read { try Skill.order(Column("status"), Column("name")).fetchAll($0) }
    }

    public func skill(id: String) throws -> Skill? {
        try db.writer.read { try Skill.fetchOne($0, key: id) }
    }

    public func skill(named name: String) throws -> Skill? {
        try db.writer.read { try Skill.filter(Column("name") == name).fetchOne($0) }
    }

    public func skills(assignedTo agentId: String, activeOnly: Bool) throws -> [Skill] {
        try db.writer.read { db in
            var sql = "SELECT skill.* FROM skill JOIN agentSkill ON agentSkill.skillId = skill.id WHERE agentSkill.agentId = ?"
            if activeOnly { sql += " AND skill.status = 'active'" }
            return try Skill.fetchAll(db, sql: sql + " ORDER BY skill.name", arguments: [agentId])
        }
    }

    public func agentIds(using skillId: String) throws -> [String] {
        try db.writer.read { try String.fetchAll($0, sql: "SELECT agentId FROM agentSkill WHERE skillId = ?", arguments: [skillId]) }
    }

    /// Rutas relativas de los archivos del skill, ordenadas.
    public func files(of skill: Skill) throws -> [String] {
        let dir = directory(for: skill).standardizedFileURL.resolvingSymlinksInPath()
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        return e.compactMap { item -> String? in
            guard let url = item as? URL, (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  url.lastPathComponent != ".DS_Store" else { return nil }
            return String(url.resolvingSymlinksInPath().path.dropFirst(dir.path.count + 1))
        }.sorted()
    }

    public func manifestText(of skill: Skill) throws -> String {
        try String(contentsOf: directory(for: skill).appendingPathComponent("SKILL.md"), encoding: .utf8)
    }

    // MARK: Importar

    /// Copia una carpeta con `SKILL.md` a la biblioteca (activo, origen importado).
    public func importFolder(_ source: URL) throws -> Skill {
        let manifestURL = source.appendingPathComponent("SKILL.md")
        guard let text = try? String(contentsOf: manifestURL, encoding: .utf8) else {
            throw ValidationError("La carpeta no tiene un SKILL.md.")
        }
        let manifest = try SkillManifest.parse(text)
        try Self.rejectSymlinks(in: source)
        guard try skill(named: manifest.name) == nil else { throw ValidationError("Ya existe un skill llamado \(manifest.name).") }
        let dest = paths.skillDir(manifest.name)
        try FileManager.default.createDirectory(at: paths.skillsDir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: source, to: dest)
        do {
            // Solo name y description: campos como allowed-tools, hooks o model podrían ampliar lo que el skill puede hacer.
            try SkillManifest.render(name: manifest.name, description: manifest.description, body: manifest.body)
                .write(to: dest.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
            return try insert(name: manifest.name, description: manifest.description, source: .imported, status: .active,
                              hasScripts: Self.containsScripts(dest), createdBy: nil)
        } catch {
            try? FileManager.default.removeItem(at: dest)
            throw error
        }
    }

    /// Descomprime un .zip (con el skill en la raíz o en una sola carpeta) e importa esa carpeta.
    public func importZip(_ zip: URL) throws -> Skill {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("frontbot-skill-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, tmp.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw ValidationError("No se pudo descomprimir el .zip.") }
        try Self.rejectEscapes(in: tmp)
        if FileManager.default.fileExists(atPath: tmp.appendingPathComponent("SKILL.md").path) { return try importFolder(tmp) }
        let folders = try FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { $0.lastPathComponent != "__MACOSX" && $0.hasDirectoryPath }
        guard folders.count == 1 else { throw ValidationError("El .zip debe contener un solo skill (una carpeta con SKILL.md).") }
        return try importFolder(folders[0])
    }

    // MARK: Crear

    /// Skill escrito por el usuario: activo desde el principio.
    public func createUserSkill(name: String, description: String, body: String, files: [String: String] = [:]) throws -> Skill {
        try write(name: name, description: description, body: body, files: files, source: .user, status: .active, createdBy: nil)
    }

    /// Skill propuesto por un agente: borrador asignado a ese agente, hasta que el usuario lo active.
    public func createDraft(agentId: String, name: String, description: String, body: String, files: [String: String]) throws -> Skill {
        let skill = try write(name: name, description: description, body: body, files: files, source: .agent, status: .draft, createdBy: agentId)
        try assign(skillId: skill.id, to: agentId)
        return skill
    }

    /// Un agente solo puede editar los borradores que él creó.
    public func updateDraft(agentId: String, name: String, description: String?, body: String?, files: [String: String]?) throws -> Skill {
        guard var skill = try skill(named: name) else { throw ValidationError("No existe un skill llamado \(name).") }
        guard skill.status == .draft else { throw ValidationError("\(name) ya está activo: solo el usuario puede cambiarlo.") }
        guard skill.createdByAgentId == agentId else { throw ValidationError("\(name) no es un borrador tuyo.") }
        let current = try SkillManifest.parse(try manifestText(of: skill))
        let newDescription = description ?? current.description
        try Self.validateFiles(files ?? [:])
        let dir = directory(for: skill)
        try SkillManifest.render(name: name, description: newDescription, body: body ?? current.body)
            .write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try writeFiles(files ?? [:], in: dir)
        skill.description = newDescription
        skill.hasScripts = Self.containsScripts(dir)
        skill.updatedAt = .dbNow()
        try db.writer.write { try skill.update($0) }
        return skill
    }

    /// El usuario edita un skill (cualquier estado) reescribiendo su SKILL.md; el nombre no cambia.
    public func saveManifest(id: String, text: String) throws -> Skill {
        guard var skill = try skill(id: id) else { throw ValidationError("No existe el skill.") }
        let manifest = try SkillManifest.parse(text)
        guard manifest.name == skill.name else { throw ValidationError("El name del frontmatter debe seguir siendo \(skill.name).") }
        try text.write(to: directory(for: skill).appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        skill.description = manifest.description
        skill.updatedAt = .dbNow()
        try db.writer.write { try skill.update($0) }
        return skill
    }

    // MARK: Estado y asignaciones

    /// Solo el usuario activa skills: ninguna herramienta llama a esto.
    public func activate(id: String) throws -> Skill {
        guard var skill = try skill(id: id) else { throw ValidationError("No existe el skill.") }
        skill.status = .active
        skill.updatedAt = .dbNow()
        try db.writer.write { try skill.update($0) }
        return skill
    }

    public func assign(skillId: String, to agentId: String) throws {
        try db.writer.write { try AgentSkill(agentId: agentId, skillId: skillId).insert($0, onConflict: .ignore) }
    }

    public func unassign(skillId: String, from agentId: String) throws {
        _ = try db.writer.write { try AgentSkill.filter(Column("agentId") == agentId && Column("skillId") == skillId).deleteAll($0) }
    }

    public func delete(id: String) throws {
        guard let skill = try skill(id: id) else { return }
        _ = try db.writer.write { try skill.delete($0) }
        try? FileManager.default.removeItem(at: directory(for: skill))
    }

    /// Skills iniciales de una plantilla: se crean si faltan (activos) y se asignan al agente.
    public func installTemplateSkills(for agent: Agent) throws {
        for seed in TemplateSkills.skills(for: agent.templateId) {
            let skill = try skill(named: seed.name) ?? createUserSkill(name: seed.name, description: seed.description, body: seed.body)
            try assign(skillId: skill.id, to: agent.id)
        }
    }

    // MARK: Internos

    private func write(name: String, description: String, body: String, files: [String: String],
                       source: SkillSource, status: SkillStatus, createdBy: String?) throws -> Skill {
        let text = SkillManifest.render(name: name, description: description, body: body)
        _ = try SkillManifest.parse(text) // valida nombre y descripción
        try Self.validateFiles(files)
        guard try skill(named: name) == nil else { throw ValidationError("Ya existe un skill llamado \(name).") }
        let dir = paths.skillDir(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try text.write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try writeFiles(files, in: dir)
        return try insert(name: name, description: description.trimmingCharacters(in: .whitespacesAndNewlines), source: source,
                          status: status, hasScripts: Self.containsScripts(dir), createdBy: createdBy)
    }

    private func insert(name: String, description: String, source: SkillSource, status: SkillStatus,
                        hasScripts: Bool, createdBy: String?) throws -> Skill {
        let now = Date.dbNow()
        let skill = Skill(id: UUID().uuidString, name: name, description: description, source: source, status: status,
                          hasScripts: hasScripts, createdByAgentId: createdBy, version: 1, createdAt: now, updatedAt: now)
        try db.writer.write { try skill.insert($0) }
        return skill
    }

    private func writeFiles(_ files: [String: String], in dir: URL) throws {
        for (path, text) in files {
            let url = dir.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Rutas relativas sin `..` ni absolutas; SKILL.md se escribe aparte.
    static func validateFiles(_ files: [String: String]) throws {
        guard files.count <= maxDraftFiles else { throw ValidationError("Un skill admite hasta \(maxDraftFiles) archivos de apoyo.") }
        for (path, text) in files {
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !path.isEmpty, !path.hasPrefix("/"), !parts.contains(".."), !parts.contains(""),
                  !path.contains("\\"), path != "SKILL.md" else {
                throw ValidationError("Ruta de archivo inválida en el skill: \(path). Usa rutas relativas como notas/ejemplo.md.")
            }
            guard text.utf8.count <= maxDraftFileBytes else { throw ValidationError("\(path) supera los 200 KB.") }
        }
    }

    static func containsScripts(_ dir: URL) -> Bool {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return false }
        return e.contains { item in
            guard let url = item as? URL else { return false }
            return scriptExtensions.contains(url.pathExtension.lowercased())
        }
    }

    static func rejectSymlinks(in dir: URL) throws {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return }
        for case let url as URL in e where (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw ValidationError("El skill contiene enlaces simbólicos (\(url.lastPathComponent)); no se importa.")
        }
    }

    /// Nada de lo extraído puede quedar fuera de la carpeta temporal (zip-slip).
    static func rejectEscapes(in dir: URL) throws {
        let base = dir.resolvingSymlinksInPath().path
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return }
        for case let url as URL in e where !url.resolvingSymlinksInPath().path.hasPrefix(base + "/") {
            throw ValidationError("El .zip contiene rutas que salen de su carpeta; no se importa.")
        }
        try rejectSymlinks(in: dir)
    }
}
