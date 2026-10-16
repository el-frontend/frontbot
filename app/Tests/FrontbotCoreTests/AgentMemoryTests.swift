import XCTest
@testable import FrontbotCore

final class AgentMemoryTests: XCTestCase {
    var db: AppDatabase!
    var ws: Workspace!
    var agent: Agent!
    var handler: ToolHandler!

    override func setUpWithError() throws {
        db = try AppDatabase.inMemory()
        ws = try db.ensureDefaultWorkspace()
        agent = try db.createAgent(workspaceId: ws.id, draft: AgentTemplate.cryptoTrader.draft, status: .active)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        handler = ToolHandler(db: db, files: BrandFiles(paths: AppPaths(root: root)), workspaceId: ws.id)
    }

    func testRememberValidatesAndListsNewestFirst() throws {
        XCTAssertThrowsError(try db.remember(agentId: agent.id, text: "  "))
        XCTAssertThrowsError(try db.remember(agentId: agent.id, text: String(repeating: "x", count: 501)))
        _ = try db.remember(agentId: agent.id, text: "Opera BTC en 4h")
        _ = try db.remember(agentId: agent.id, text: " Riesgo máximo 1% ")
        XCTAssertEqual(try db.memories(agentId: agent.id).map(\.text), ["Riesgo máximo 1%", "Opera BTC en 4h"])
    }

    func testMemoryIsCappedFirstInFirstOut() throws {
        for i in 1...AppDatabase.memoryLimit { _ = try db.remember(agentId: agent.id, text: "nota \(i)") }
        let result = try db.remember(agentId: agent.id, text: "nota nueva")
        XCTAssertTrue(result.evictedOldest)
        let texts = try db.memories(agentId: agent.id).map(\.text)
        XCTAssertEqual(texts.count, AppDatabase.memoryLimit)
        XCTAssertEqual(texts.first, "nota nueva")
        XCTAssertFalse(texts.contains("nota 1"))
    }

    func testForgetOnlyTouchesTheAgentsOwnNotes() throws {
        let frontbot = try db.ensureDefaultAgent(workspaceId: ws.id)
        let note = try db.remember(agentId: frontbot.id, text: "de Frontbot").memory
        XCTAssertThrowsError(try db.forget(agentId: agent.id, memoryId: note.id!))
        try db.forget(agentId: frontbot.id, memoryId: note.id!)
        XCTAssertTrue(try db.memories(agentId: frontbot.id).isEmpty)
    }

    func testClearMemory() throws {
        _ = try db.remember(agentId: agent.id, text: "a")
        try db.clearMemory(agentId: agent.id)
        XCTAssertTrue(try db.memories(agentId: agent.id).isEmpty)
    }

    func testMemoryTools() throws {
        let saved = try handler.handle(method: "tool.memory_remember", params: ["agent_id": .string(agent.id), "text": "Prefiere velas de 4h"])
        XCTAssertEqual(saved["evicted_oldest"], false)
        let list = try handler.handle(method: "tool.memory_list", params: ["agent_id": .string(agent.id)])
        let first = try XCTUnwrap(list["memories"]?.arrayValue?.first)
        XCTAssertEqual(first["text"], "Prefiere velas de 4h")
        _ = try handler.handle(method: "tool.memory_forget", params: ["agent_id": .string(agent.id), "memory_id": first["id"]!])
        XCTAssertEqual(try handler.handle(method: "tool.memory_list", params: ["agent_id": .string(agent.id)])["memories"], [])
    }

    func testPromptMemoryIsTrimmedToBudgetKeepingTheNewest() throws {
        let notes = (1...10).map { AgentMemory(id: Int64($0), agentId: "a", text: String(repeating: "\($0 % 10)", count: 1_000), createdAt: Date()) }
            .reversed() as [AgentMemory] // las más nuevas primero, como devuelve el store
        let trimmed = MemoryPrompt.trimmed(Array(notes), budget: 3_500)
        XCTAssertEqual(trimmed.map(\.id), [10, 9, 8])
    }
}

final class AgentMemoryRunTests: XCTestCase {
    func makeClient() throws -> (AgentClient, AppDatabase, Workspace) {
        let db = try AppDatabase.inMemory()
        let ws = try db.ensureDefaultWorkspace()
        let node = ProcessInfo.processInfo.environment["FRONTBOT_NODE"] ?? "/opt/homebrew/bin/node"
        let script = AgentClientTests.repoRoot.appendingPathComponent("agent/dist/main.js").path
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: node), "usa FRONTBOT_NODE=$(which node)")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let client = AgentClient(config: AgentConfig(nodePath: node, scriptPath: script, apiKey: nil, model: "m", fakeAgent: true),
                                 db: db, files: BrandFiles(paths: AppPaths(root: root)), workspaceId: ws.id)
        return (client, db, ws)
    }

    func texts(_ stream: AsyncStream<AgentUpdate>, _ runId: String) async -> [String] {
        var texts: [String] = []
        for await update in stream {
            if case .event(let id, "text", let text) = update, id == runId { texts.append(text) }
            if case .finished(let r) = update, r.id == runId { break }
        }
        return texts
    }

    func testRunSendsTheAgentsMemory() async throws {
        let (client, db, ws) = try makeClient()
        let agent = try db.ensureDefaultAgent(workspaceId: ws.id)
        _ = try db.remember(agentId: agent.id, text: "vieja")
        _ = try db.remember(agentId: agent.id, text: "nueva")
        let stream = await client.updates()
        let run = try await client.run(prompt: "memoria", agent: agent, brand: nil)
        let result = await texts(stream, run.id)
        XCTAssertTrue(result.contains("Memoria: nueva | vieja"), "\(result)")
        await client.stop()
    }

    func testSummarizeRunWritesToMemory() async throws {
        let (client, db, ws) = try makeClient()
        let agent = try db.ensureDefaultAgent(workspaceId: ws.id)
        let stream = await client.updates()
        let run = try await client.run(prompt: "", agent: agent, brand: nil,
                                       history: [ChatTurn(role: .user, text: "a"), ChatTurn(role: .agent, text: "b")], summarize: true)
        _ = await texts(stream, run.id)
        XCTAssertEqual(try db.memories(agentId: agent.id).first?.text, "Resumen de prueba: 2 turnos")
        await client.stop()
    }
}

