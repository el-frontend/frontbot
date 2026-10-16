import XCTest
@testable import FrontbotCore

final class ConversationStoreTests: XCTestCase {
    var db: AppDatabase!
    var ws: Workspace!

    override func setUpWithError() throws {
        db = try AppDatabase.inMemory()
        ws = try db.ensureDefaultWorkspace()
    }

    func testCreateTitlesFromTheFirstPrompt() throws {
        let long = String(repeating: "a", count: 80)
        let c = try db.createConversation(workspaceId: ws.id, agentId: try db.ensureDefaultAgent(workspaceId: ws.id).id, brandId: nil, firstPrompt: "  Ideas para\nInstagram  ")
        XCTAssertEqual(c.title, "Ideas para Instagram")
        XCTAssertEqual(try db.createConversation(workspaceId: ws.id, agentId: try db.ensureDefaultAgent(workspaceId: ws.id).id, brandId: nil, firstPrompt: long).title.count, 61)
    }

    func testMessagesKeepTheirOrderAndRole() throws {
        let c = try db.createConversation(workspaceId: ws.id, agentId: try db.ensureDefaultAgent(workspaceId: ws.id).id, brandId: nil, firstPrompt: "hola")
        try db.appendMessage(conversationId: c.id, role: .user, text: "hola")
        try db.appendMessage(conversationId: c.id, role: .tool, text: "→ brands_list")
        try db.appendMessage(conversationId: c.id, role: .agent, text: "¡Hola!")
        let messages = try db.messages(conversationId: c.id)
        XCTAssertEqual(messages.map(\.role), [.user, .tool, .agent])
        XCTAssertEqual(messages.map(\.text), ["hola", "→ brands_list", "¡Hola!"])
    }

    func testRecentConversationsAreOrderedByLastActivity() throws {
        let old = try db.createConversation(workspaceId: ws.id, agentId: try db.ensureDefaultAgent(workspaceId: ws.id).id, brandId: nil, firstPrompt: "vieja")
        let new = try db.createConversation(workspaceId: ws.id, agentId: try db.ensureDefaultAgent(workspaceId: ws.id).id, brandId: nil, firstPrompt: "nueva")
        XCTAssertEqual(try db.conversations(workspaceId: ws.id, limit: 10).map(\.id), [new.id, old.id])
        try db.appendMessage(conversationId: old.id, role: .user, text: "sigo aquí")
        XCTAssertEqual(try db.conversations(workspaceId: ws.id, limit: 10).map(\.id), [old.id, new.id])
        XCTAssertEqual(try db.conversations(workspaceId: ws.id, limit: 1).count, 1)
    }

    func testDeletingAConversationDeletesItsMessages() throws {
        let c = try db.createConversation(workspaceId: ws.id, agentId: try db.ensureDefaultAgent(workspaceId: ws.id).id, brandId: nil, firstPrompt: "hola")
        try db.appendMessage(conversationId: c.id, role: .user, text: "hola")
        try db.deleteConversation(id: c.id)
        XCTAssertTrue(try db.conversations(workspaceId: ws.id, limit: 10).isEmpty)
        XCTAssertTrue(try db.messages(conversationId: c.id).isEmpty)
    }

    func testAppendingToAMissingConversationFails() {
        XCTAssertThrowsError(try db.appendMessage(conversationId: "nope", role: .user, text: "x"))
    }
}

extension ConversationStoreTests {
    func testNeedsSummaryOnlyWithNewAgentRepliesSinceLastSummary() throws {
        let c = try db.createConversation(workspaceId: ws.id, agentId: try db.ensureDefaultAgent(workspaceId: ws.id).id, brandId: nil, firstPrompt: "hola")
        try db.appendMessage(conversationId: c.id, role: .user, text: "hola")
        XCTAssertFalse(try db.conversationNeedsSummary(id: c.id), "sin respuesta del agente no hay nada que resumir")
        try db.appendMessage(conversationId: c.id, role: .agent, text: "¡Hola!")
        XCTAssertTrue(try db.conversationNeedsSummary(id: c.id))
        try db.markSummarized(id: c.id)
        XCTAssertFalse(try db.conversationNeedsSummary(id: c.id))
        try db.appendMessage(conversationId: c.id, role: .agent, text: "otra cosa")
        XCTAssertTrue(try db.conversationNeedsSummary(id: c.id))
    }
}

final class AgentModelTests: XCTestCase {
    func testCatalogStartsWithTheDefault() {
        XCTAssertEqual(AgentModel.all.first?.id, AgentConfig.defaultModel)
        XCTAssertTrue(AgentModel.all.contains { $0.id == "claude-opus-5-5" })
    }

    func testShortNames() {
        XCTAssertEqual(AgentModel.shortName("claude-sonnet-5-5"), "sonnet-5.5")
        XCTAssertEqual(AgentModel.shortName("claude-opus-5-5"), "opus-5.5")
        XCTAssertEqual(AgentModel.shortName("claude-haiku-4-5-20251001"), "haiku-4.5")
    }

    func testUnknownStoredModelFallsBackToTheDefault() {
        XCTAssertEqual(AgentModel.resolve("claude-opus-5-5"), "claude-opus-5-5")
        XCTAssertEqual(AgentModel.resolve("gpt-9"), AgentConfig.defaultModel)
        XCTAssertEqual(AgentModel.resolve(nil), AgentConfig.defaultModel)
    }
}
