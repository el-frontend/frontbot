import XCTest
@testable import FrontbotCore

final class ChatHistoryTests: XCTestCase {
    func testKeepsLast20Turns() {
        let turns = (1...25).map { ChatTurn(role: $0 % 2 == 0 ? .agent : .user, text: "m\($0)") }
        let t = ChatHistory.trimmed(turns)
        XCTAssertEqual(t.count, 20)
        XCTAssertEqual(t.first?.text, "m6")
        XCTAssertEqual(t.last?.text, "m25")
    }

    func testClipsLongTurns() {
        let t = ChatHistory.trimmed([ChatTurn(role: .user, text: String(repeating: "é", count: 5_000))])
        XCTAssertEqual(t.first?.text.count, 4_001)
        XCTAssertEqual(t.first?.text.last, "…")
    }

    func testJSON() {
        XCTAssertEqual(ChatHistory.json([ChatTurn(role: .agent, text: "hola")]), [["role": "agent", "text": "hola"]])
    }

    func testFakeAgentReceivesHistory() async throws {
        let db = try AppDatabase.inMemory()
        let ws = try db.ensureDefaultWorkspace()
        let node = ProcessInfo.processInfo.environment["FRONTBOT_NODE"] ?? "/opt/homebrew/bin/node"
        let script = AgentClientTests.repoRoot.appendingPathComponent("agent/dist/main.js").path
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: node), "usa FRONTBOT_NODE=$(which node)")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let client = AgentClient(config: AgentConfig(nodePath: node, scriptPath: script, apiKey: nil, model: "m", fakeAgent: true),
                                 db: db, files: BrandFiles(paths: AppPaths(root: root)), workspaceId: ws.id)
        let stream = await client.updates()
        let run = try await client.run(prompt: "hola", brand: nil, history: [ChatTurn(role: .user, text: "a"), ChatTurn(role: .agent, text: "b")])
        var texts: [String] = []
        for await update in stream {
            if case .event(let id, "text", let text) = update, id == run.id { texts.append(text) }
            if case .finished(let r) = update, r.id == run.id { break }
        }
        XCTAssertTrue(texts.contains("Historial: 2"))
        await client.stop()
    }
}
