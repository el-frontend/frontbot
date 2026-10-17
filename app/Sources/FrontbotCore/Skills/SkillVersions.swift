import Foundation
import GRDB

/// Cómo lo que aprende un agente se convierte en skill: solo el usuario aprueba y cada cambio queda versionado.
public struct SkillVersions: Sendable {
    let library: SkillLibrary
    private var db: AppDatabase { library.db }
    private var paths: AppPaths { library.paths }

    public init(library: SkillLibrary) { self.library = library }

    // MARK: Versiones

    /// Copia la carpeta del skill a `.versions/<name>/<version>/` y registra la fila.
    @discardableResult
    public func snapshot(_ skill: Skill, proposalId: String?) throws -> SkillVersion {
        let fm = FileManager.default
        let dest = paths.skillVersionsDir(skill.name).appendingPathComponent(String(skill.version), isDirectory: true)
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: dest)
        try fm.copyItem(at: library.directory(for: skill), to: dest)
        let row = SkillVersion(id: UUID().uuidString, skillId: skill.id, number: skill.version, proposalId: proposalId,
                               snapshotPath: dest.path, createdAt: .dbNow())
        try db.writer.write { db in
            try db.execute(sql: "DELETE FROM skillVersion WHERE skillId = ? AND number = ?", arguments: [skill.id, skill.version])
            try row.insert(db)
        }
        return row
    }

    public func versions(skillId: String) -> [SkillVersion] {
        (try? db.writer.read { try SkillVersion.filter(Column("skillId") == skillId).order(Column("number")).fetchAll($0) }) ?? []
    }

    public func revert(skillId: String, to number: Int) throws -> Skill {
        guard var skill = try library.skill(id: skillId) else { throw ValidationError("No existe el skill.") }
        guard let target = versions(skillId: skillId).first(where: { $0.number == number }),
              FileManager.default.fileExists(atPath: target.snapshotPath) else {
            throw ValidationError("No existe la versión \(number) de \(skill.name).")
        }
        try snapshot(skill, proposalId: nil)
        let fm = FileManager.default
        let dir = library.directory(for: skill)
        try? fm.removeItem(at: dir)
        try fm.copyItem(at: URL(fileURLWithPath: target.snapshotPath), to: dir)
        let manifest = try SkillManifest.parse(try library.manifestText(of: skill))
        skill.description = manifest.description
        skill.hasScripts = SkillLibrary.containsScripts(dir)
        skill.version += 1
        skill.updatedAt = .dbNow()
        try db.writer.write { try skill.update($0) }
        return skill
    }

    // MARK: Propuestas

    public func pendingProposals(agentId: String?) -> [SkillProposal] {
        (try? db.writer.read { db in
            var req = SkillProposal.filter(Column("status") == SkillProposalStatus.pending.rawValue)
            if let agentId { req = req.filter(Column("agentId") == agentId) }
            return try req.order(Column("createdAt")).fetchAll(db)
        }) ?? []
    }

    public func propose(agentId: String, topicId: String?, kind: SkillProposalKind, skillName: String, description: String,
                        body: String, files: [String: String], evidenceSummary: String) throws -> SkillProposal {
        let text = SkillManifest.render(name: skillName, description: description, body: body)
        let manifest = try SkillManifest.parse(text) // valida nombre y descripción
        try SkillLibrary.validateFiles(files)
        let existing = try library.skill(named: manifest.name)
        var baseVersion: Int?
        switch kind {
        case .new:
            guard existing == nil else { throw ValidationError("Ya existe un skill llamado \(manifest.name).") }
        case .update:
            guard let skill = existing else { throw ValidationError("No existe un skill llamado \(manifest.name).") }
            guard try library.agentIds(using: skill.id).contains(agentId) else {
                throw ValidationError("\(manifest.name) no está asignado a este agente.")
            }
            baseVersion = skill.version
        }
        let proposal = SkillProposal(id: UUID().uuidString, agentId: agentId, topicId: topicId, kind: kind, skillName: manifest.name,
                                     description: manifest.description, body: body, files: files,
                                     evidenceSummary: evidenceSummary, baseVersion: baseVersion, status: .pending,
                                     comment: nil, createdAt: .dbNow(), decidedAt: nil)
        try db.writer.write { try proposal.insert($0) }
        if let topicId { try db.setTopicStatus(id: topicId, .resolved, reason: nil, now: .dbNow()) }
        return proposal
    }

    /// Archivos de la propuesta frente a los actuales (`SKILL.md` renderizado incluido).
    public func proposalFiles(_ p: SkillProposal) -> [(path: String, old: String?, new: String)] {
        let dir = paths.skillDir(p.skillName)
        func current(_ path: String) -> String? {
            p.kind == .update ? try? String(contentsOf: dir.appendingPathComponent(path), encoding: .utf8) : nil
        }
        let manifest = SkillManifest.render(name: p.skillName, description: p.description, body: p.body)
        return [(path: "SKILL.md", old: current("SKILL.md"), new: manifest)]
            + p.files.keys.sorted().map { (path: $0, old: current($0), new: p.files[$0] ?? "") }
    }

    public func approve(proposalId: String) throws -> Skill {
        let p = try pending(proposalId)
        let skill: Skill
        switch p.kind {
        case .new:
            skill = try library.createSkill(name: p.skillName, description: p.description, body: p.body, files: p.files,
                                            source: .agent, status: .active, createdBy: p.agentId)
            try library.assign(skillId: skill.id, to: p.agentId)
        case .update:
            guard var current = try library.skill(named: p.skillName),
                  try library.agentIds(using: current.id).contains(p.agentId),
                  current.version == p.baseVersion else {
                throw ValidationError("El skill cambió desde que se propuso: recházala para que el agente vuelva a proponer.")
            }
            try snapshot(current, proposalId: p.id)
            let dir = library.directory(for: current)
            try SkillManifest.render(name: p.skillName, description: p.description, body: p.body)
                .write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
            try library.writeFiles(p.files, in: dir)
            current.description = p.description.trimmingCharacters(in: .whitespacesAndNewlines)
            current.hasScripts = SkillLibrary.containsScripts(dir)
            current.version += 1
            current.updatedAt = .dbNow()
            try db.writer.write { try current.update($0) }
            skill = current
        }
        try decide(p, .approved, comment: nil)
        if let topicId = p.topicId { try db.setTopicStatus(id: topicId, .graduated, reason: nil, now: .dbNow()) }
        return skill
    }

    /// Rechaza y devuelve el tema al estudio. Si ya no hay sitio entre los abiertos, pasa a `paused`;
    /// si tampoco cabe (pausado cuenta como abierto), queda `resolved` con el feedback registrado.
    public func reject(proposalId: String, comment: String?) throws {
        let p = try pending(proposalId)
        let trimmed = comment?.trimmingCharacters(in: .whitespacesAndNewlines)
        let feedback = (trimmed?.isEmpty == false) ? trimmed : nil
        try decide(p, .rejected, comment: feedback)
        guard let topicId = p.topicId, try db.topic(id: topicId) != nil else { return }
        _ = try db.addEntry(topicId: topicId, sessionId: nil, kind: feedback == nil ? .note : .feedback,
                            text: feedback ?? "Rechazada sin comentario", evidence: nil, sources: [], model: nil)
        guard try db.topic(id: topicId)?.status == .resolved else { return }
        if (try? db.setTopicStatus(id: topicId, .studying, reason: nil, now: .dbNow())) != nil { return }
        _ = try? db.setTopicStatus(id: topicId, .paused, reason: "Propuesta rechazada", now: .dbNow())
    }

    // MARK: Internos

    private func pending(_ id: String) throws -> SkillProposal {
        guard let p = try db.writer.read({ try SkillProposal.fetchOne($0, key: id) }) else { throw ValidationError("No existe la propuesta.") }
        guard p.status == .pending else { throw ValidationError("La propuesta ya fue decidida.") }
        return p
    }

    private func decide(_ p: SkillProposal, _ status: SkillProposalStatus, comment: String?) throws {
        var p = p
        p.status = status
        p.comment = comment
        p.decidedAt = .dbNow()
        try db.writer.write { try p.update($0) }
    }
}
