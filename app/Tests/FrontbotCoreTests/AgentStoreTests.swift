import XCTest
import GRDB
@testable import FrontbotCore

final class AgentStoreTests: XCTestCase {
    var db: AppDatabase!
    var ws: Workspace!

    override func setUpWithError() throws {
        db = try AppDatabase.inMemory()
        ws = try db.ensureDefaultWorkspace()
    }

    func testDefaultAgentIsCreatedOnceAndFirst() throws {
        let frontbot = try db.ensureDefaultAgent(workspaceId: ws.id)
        XCTAssertEqual(frontbot.name, "Frontbot")
        XCTAssertTrue(frontbot.isDefault)
        XCTAssertEqual(frontbot.status, .active)
        XCTAssertEqual(try db.ensureDefaultAgent(workspaceId: ws.id).id, frontbot.id)
        _ = try db.createAgent(workspaceId: ws.id, draft: AgentDraft(name: "Aaa", instructions: "x"), status: .active)
        XCTAssertEqual(try db.agents(workspaceId: ws.id).first?.id, frontbot.id, "Frontbot va primero aunque otro nombre ordene antes")
    }

    func testExistingConversationsMoveToTheDefaultAgent() throws {
        try db.writer.write { db in
            try db.execute(sql: """
                INSERT INTO conversation (id, workspaceId, title, createdAt, updatedAt, activity)
                VALUES ('old', ?, 'vieja', '2026-10-01 10:00:00.000', '2026-10-01 10:00:00.000', 1)
                """, arguments: [self.ws.id])
        }
        let frontbot = try db.ensureDefaultAgent(workspaceId: ws.id)
        XCTAssertEqual(try db.conversations(workspaceId: ws.id, limit: 10).first?.agentId, frontbot.id)
    }

    func testCreateValidatesAndActivates() throws {
        XCTAssertThrowsError(try db.createAgent(workspaceId: ws.id, draft: AgentDraft(name: "  ", instructions: "x"), status: .draft))
        XCTAssertThrowsError(try db.createAgent(workspaceId: ws.id, draft: AgentDraft(name: "A", instructions: ""), status: .draft))
        let draft = try db.createAgent(workspaceId: ws.id, draft: AgentDraft(name: " Analista ", instructions: "Analiza."), status: .draft)
        XCTAssertEqual(draft.name, "Analista")
        XCTAssertEqual(draft.model, AgentConfig.defaultModel)
        XCTAssertEqual(try db.activateAgent(id: draft.id).status, .active)
    }

    func testUpdateKeepsIdentity() throws {
        let a = try db.createAgent(workspaceId: ws.id, draft: AgentDraft(name: "A", instructions: "x"), status: .active)
        var d = AgentDraft(agent: a)
        d.instructions = "nuevas"
        d.browser = true
        let updated = try db.updateAgent(id: a.id, draft: d)
        XCTAssertEqual(updated.instructions, "nuevas")
        XCTAssertTrue(updated.browser)
        XCTAssertEqual(updated.createdAt, a.createdAt)
    }

    func testProviderAndModelRoundTripForBothProviders() throws {
        let claude = try db.createAgent(workspaceId: ws.id, draft: AgentDraft(name: "Claude", instructions: "x"), status: .active)
        let codex = try db.createAgent(workspaceId: ws.id,
                                      draft: AgentDraft(name: "Codex", instructions: "x", provider: .codex, model: "gpt-5"), status: .active)
        XCTAssertEqual(try db.agent(id: claude.id)?.provider, .claude)
        XCTAssertEqual(try db.agent(id: claude.id)?.model, AgentConfig.defaultModel)
        XCTAssertEqual(try db.agent(id: codex.id)?.provider, .codex)
        XCTAssertEqual(try db.agent(id: codex.id)?.model, "gpt-5")
    }

    func testUpdatingAgentPreservesProviderAndNormalizesIncompatibleModel() throws {
        let agent = try db.createAgent(workspaceId: ws.id,
                                       draft: AgentDraft(name: "Codex", instructions: "x", provider: .codex, model: "gpt-5"), status: .active)
        var draft = AgentDraft(agent: agent)
        draft.instructions = "updated"
        let updated = try db.updateAgent(id: agent.id, draft: draft)
        XCTAssertEqual(updated.provider, .codex)
        XCTAssertEqual(updated.model, "gpt-5")

        draft.model = "claude-sonnet-5-5"
        XCTAssertEqual(try db.updateAgent(id: agent.id, draft: draft).model, AgentProvider.defaultModel(for: .codex))
    }

    func testV11AgentsMigrateToClaudeProvider() throws {
        let writer = try DatabaseQueue()
        try AppDatabase.migrator.migrate(writer, upTo: "v11-workdir")
        try writer.write { db in
            try db.execute(sql: "INSERT INTO workspace (id, name, createdAt) VALUES ('legacy-workspace', 'Legacy', '2026-10-01 10:00:00.000')")
            try db.execute(sql: """
                INSERT INTO agent (id, workspaceId, name, icon, description, instructions, model, browser, trading,
                                   status, isDefault, templateId, createdAt, updatedAt, networkDomains)
                VALUES ('legacy-agent', 'legacy-workspace', 'Legacy', 'person', '', 'instructions', 'claude-opus-5-5',
                        0, 0, 'active', 0, NULL, '2026-10-01 10:00:00.000', '2026-10-01 10:00:00.000', NULL)
                """)
        }

        let migrated = try AppDatabase(writer)
        let agent = try XCTUnwrap(migrated.agent(id: "legacy-agent"))
        XCTAssertEqual(agent.provider, .claude)
        XCTAssertEqual(agent.model, "claude-opus-5-5")
    }

    func testDeletingAnAgentDeletesItsConversationsButNotFrontbot() throws {
        let frontbot = try db.ensureDefaultAgent(workspaceId: ws.id)
        let a = try db.createAgent(workspaceId: ws.id, draft: AgentDraft(name: "A", instructions: "x"), status: .active)
        _ = try db.createConversation(workspaceId: ws.id, agentId: a.id, brandId: nil, firstPrompt: "hola")
        try db.deleteAgent(id: a.id)
        XCTAssertTrue(try db.conversations(workspaceId: ws.id, limit: 10).isEmpty)
        XCTAssertThrowsError(try db.deleteAgent(id: frontbot.id)) { error in
            XCTAssertEqual((error as? ValidationError)?.message, "Frontbot no se puede borrar.")
        }
    }

    func testFoldersPerAgent() throws {
        let a = try db.createAgent(workspaceId: ws.id, draft: AgentDraft(name: "A", instructions: "x"), status: .active)
        try db.addFolder(agentId: a.id, path: "/Users/x/marcas")
        try db.addFolder(agentId: a.id, path: "/Users/x/marcas")
        try db.addFolder(agentId: a.id, path: "/Users/x/fotos")
        XCTAssertEqual(try db.folders(agentId: a.id), ["/Users/x/marcas", "/Users/x/fotos"])
        XCTAssertEqual(try db.folders(agentId: try db.ensureDefaultAgent(workspaceId: ws.id).id), [])
        try db.removeFolder(agentId: a.id, path: "/Users/x/marcas")
        XCTAssertEqual(try db.folders(agentId: a.id), ["/Users/x/fotos"])
        try db.deleteAgent(id: a.id)
        XCTAssertEqual(try db.folders(agentId: a.id), [])
        XCTAssertThrowsError(try db.addFolder(agentId: "nope", path: "/x"))
    }

    func testCryptoTraderTemplate() throws {
        let template = try XCTUnwrap(AgentTemplate.all.first { $0.id == "crypto-trader" })
        let agent = try db.createAgent(workspaceId: ws.id, draft: template.draft, status: .active)
        XCTAssertEqual(agent.name, "Crypto Trader")
        XCTAssertEqual(agent.templateId, "crypto-trader")
        XCTAssertTrue(agent.browser)
        XCTAssertTrue(agent.trading)
        XCTAssertTrue(agent.instructions.contains("stop loss"))
        XCTAssertTrue(agent.instructions.contains("lab_propose_skill"))
        XCTAssertFalse(agent.instructions.contains("guárdala como skill"))
    }
}

final class AgentToolTests: XCTestCase {
    var db: AppDatabase!
    var handler: ToolHandler!
    var ws: Workspace!

    override func setUpWithError() throws {
        db = try AppDatabase.inMemory()
        ws = try db.ensureDefaultWorkspace()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        handler = ToolHandler(db: db, files: BrandFiles(paths: AppPaths(root: root)), workspaceId: ws.id)
    }

    func testFrontbotCreatesAgentDrafts() throws {
        let frontbot = try db.ensureDefaultAgent(workspaceId: ws.id)
        let result = try handler.handle(method: "tool.agents_create_draft", params: [
            "agent_id": .string(frontbot.id), "name": "Investigador", "description": "Busca papers",
            "instructions": "Investiga a fondo.", "model": "claude-opus-5-5", "browser": true,
        ])
        let agent = try XCTUnwrap(try db.agent(id: try XCTUnwrap(result["agent_id"]?.stringValue)))
        XCTAssertEqual(agent.status, .draft)
        XCTAssertEqual(agent.model, "claude-opus-5-5")
        XCTAssertTrue(agent.browser)
    }

    func testOnlyFrontbotCanCreateAgents() throws {
        let other = try db.createAgent(workspaceId: ws.id, draft: AgentDraft(name: "A", instructions: "x"), status: .active)
        XCTAssertThrowsError(try handler.handle(method: "tool.agents_create_draft", params: [
            "agent_id": .string(other.id), "name": "B", "instructions": "y",
        ])) { error in
            XCTAssertEqual((error as? ValidationError)?.message, "Solo Frontbot puede crear agentes.")
        }
    }

    func testUnknownModelFallsBackToDefault() throws {
        let frontbot = try db.ensureDefaultAgent(workspaceId: ws.id)
        let result = try handler.handle(method: "tool.agents_create_draft", params: [
            "agent_id": .string(frontbot.id), "name": "B", "instructions": "y", "model": "gpt-9",
        ])
        XCTAssertEqual(try db.agent(id: result["agent_id"]!.stringValue!)?.model, AgentConfig.defaultModel)
    }
}
