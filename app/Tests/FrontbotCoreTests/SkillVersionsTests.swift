import XCTest
@testable import FrontbotCore

final class SkillVersionsTests: XCTestCase {
    var db: AppDatabase!
    var root: URL!
    var paths: AppPaths!
    var library: SkillLibrary!
    var versions: SkillVersions!
    var agent: Agent!
    let changed = "El skill cambió desde que se propuso: recházala para que el agente vuelva a proponer."

    override func setUpWithError() throws {
        db = try AppDatabase.inMemory()
        let ws = try db.ensureDefaultWorkspace()
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        paths = AppPaths(root: root)
        library = SkillLibrary(db: db, paths: paths)
        versions = SkillVersions(library: library)
        agent = try db.createAgent(workspaceId: ws.id, draft: AgentDraft(name: "A", instructions: "x"), status: .active)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func topic() throws -> LabTopic {
        try db.openTopic(agentId: agent.id, question: "¿q?", why: "w", origin: .agent, now: .dbNow())
    }

    func propose(_ kind: SkillProposalKind, name: String = "mi-skill", body: String = "Nuevo", topic t: LabTopic? = nil,
                 files: [String: String] = [:]) throws -> SkillProposal {
        try versions.propose(agentId: agent.id, topicId: (t ?? topic()).id, kind: kind, skillName: name,
                             description: "Úsalo para algo", body: body, files: files, evidenceSummary: "evidencia")
    }

    func existing() throws -> Skill {
        let s = try library.createUserSkill(name: "mi-skill", description: "Viejo", body: "Viejo texto", files: ["notas/a.md": "A", "b.md": "B"])
        try library.assign(skillId: s.id, to: agent.id)
        return s
    }

    func testApproveNewCreatesActiveAssignedSkill() throws {
        let t = try topic()
        let p = try propose(.new, topic: t, files: ["x.md": "X"])
        XCTAssertEqual(try db.topic(id: t.id)?.status, .resolved)
        let s = try versions.approve(proposalId: p.id)
        XCTAssertEqual(s.status, .active)
        XCTAssertEqual(s.source, .agent)
        XCTAssertEqual(s.createdByAgentId, agent.id)
        XCTAssertEqual(s.version, 1)
        XCTAssertEqual(try library.skills(assignedTo: agent.id, activeOnly: true).map(\.name), ["mi-skill"])
        XCTAssertEqual(try db.topic(id: t.id)?.status, .graduated)
        XCTAssertEqual(try versions.pendingProposals(agentId: agent.id), [])
    }

    func testNewFailsIfNameExists() throws {
        _ = try existing()
        XCTAssertThrowsError(try propose(.new))
    }

    func testApproveUpdateSnapshotsAndBumpsVersion() throws {
        let s = try existing()
        let t = try topic()
        let p = try propose(.update, topic: t, files: ["b.md": "B2"])
        XCTAssertEqual(p.baseVersion, 1)
        let files = versions.proposalFiles(p)
        XCTAssertEqual(files.first { $0.path == "b.md" }?.old, "B")
        XCTAssertEqual(files.first { $0.path == "b.md" }?.new, "B2")
        XCTAssertNotNil(files.first { $0.path == "SKILL.md" }?.old)
        let updated = try versions.approve(proposalId: p.id)
        XCTAssertEqual(updated.version, 2)
        let old = try String(contentsOf: paths.skillVersionsDir("mi-skill").appendingPathComponent("1/SKILL.md"), encoding: .utf8)
        XCTAssertTrue(old.contains("Viejo texto"))
        XCTAssertTrue(try library.manifestText(of: updated).contains("Nuevo"))
        // los archivos no incluidos no cambian
        XCTAssertEqual(try String(contentsOf: paths.skillDir("mi-skill").appendingPathComponent("notas/a.md"), encoding: .utf8), "A")
        XCTAssertEqual(try String(contentsOf: paths.skillDir("mi-skill").appendingPathComponent("b.md"), encoding: .utf8), "B2")
        XCTAssertEqual(try db.topic(id: t.id)?.status, .graduated)
        XCTAssertEqual(try versions.versions(skillId: s.id).map(\.number), [1])
    }

    func testUserEditBumpsVersionAndBlocksStaleProposal() throws {
        let s = try existing()
        let p = try propose(.update)
        let edited = try library.saveManifest(id: s.id, text: SkillManifest.render(name: "mi-skill", description: "Editado", body: "Del usuario"))
        XCTAssertEqual(edited.version, 2)
        XCTAssertThrowsError(try versions.approve(proposalId: p.id)) { XCTAssertEqual(($0 as? ValidationError)?.message, self.changed) }
        XCTAssertEqual(try db.writer.read { try SkillProposal.fetchOne($0, key: p.id) }?.status, .pending)
    }

    func testApproveFailsIfSkillUnassignedOrDeleted() throws {
        let s = try existing()
        let p = try propose(.update)
        try library.unassign(skillId: s.id, from: agent.id)
        XCTAssertThrowsError(try versions.approve(proposalId: p.id))
        try library.assign(skillId: s.id, to: agent.id)
        try library.delete(id: s.id)
        XCTAssertThrowsError(try versions.approve(proposalId: p.id))
        XCTAssertEqual(try db.writer.read { try SkillProposal.fetchOne($0, key: p.id) }?.status, .pending)
    }

    func testRejectAddsFeedbackAndReopens() throws {
        let t = try topic()
        let p = try propose(.new, topic: t)
        try versions.reject(proposalId: p.id, comment: "Falta evidencia")
        XCTAssertEqual(try db.topic(id: t.id)?.status, .studying)
        let e = try db.entries(topicId: t.id)
        XCTAssertEqual(e.last?.kind, .feedback)
        XCTAssertEqual(e.last?.text, "Falta evidencia")
        let rejected = try db.writer.read { try SkillProposal.fetchOne($0, key: p.id) }
        XCTAssertEqual(rejected?.status, .rejected)
        XCTAssertEqual(rejected?.comment, "Falta evidencia")
    }

    func testRejectWithoutCommentAddsNote() throws {
        let t = try topic()
        let p = try propose(.new, topic: t)
        try versions.reject(proposalId: p.id, comment: nil)
        XCTAssertEqual(try db.entries(topicId: t.id).last?.kind, .note)
        XCTAssertEqual(try db.entries(topicId: t.id).last?.text, "Rechazada sin comentario")
    }

    func testRejectAtTheLimitLeavesTopicResolved() throws {
        let t = try topic()
        let p = try propose(.new, topic: t)
        _ = try topic(); _ = try topic(); _ = try topic()
        try versions.reject(proposalId: p.id, comment: "no")
        XCTAssertEqual(try db.topic(id: t.id)?.status, .resolved)
        XCTAssertEqual(try db.entries(topicId: t.id).last?.kind, .feedback)
    }

    func testRevertRestoresAndBumps() throws {
        let s = try existing()
        let p = try propose(.update, files: ["b.md": "B2"])
        _ = try versions.approve(proposalId: p.id)
        let r = try versions.revert(skillId: s.id, to: 1)
        XCTAssertEqual(r.version, 3)
        XCTAssertTrue(try library.manifestText(of: r).contains("Viejo texto"))
        XCTAssertEqual(try String(contentsOf: paths.skillDir("mi-skill").appendingPathComponent("b.md"), encoding: .utf8), "B")
        XCTAssertEqual(try versions.versions(skillId: s.id).map(\.number), [1, 2])
        let v2 = try String(contentsOf: paths.skillVersionsDir("mi-skill").appendingPathComponent("2/SKILL.md"), encoding: .utf8)
        XCTAssertTrue(v2.contains("Nuevo"))
        XCTAssertThrowsError(try versions.revert(skillId: s.id, to: 99))
    }

    func testUpdateRequiresAssignedSkill() throws {
        XCTAssertThrowsError(try propose(.update), "no existe")
        let s = try existing()
        try library.unassign(skillId: s.id, from: agent.id)
        XCTAssertThrowsError(try propose(.update), "no asignado")
    }

    func testProposeValidatesLikeDrafts() throws {
        XCTAssertThrowsError(try propose(.new, name: "Mal Nombre"))
        XCTAssertThrowsError(try propose(.new, files: ["../x": "x"]))
    }
}
