import XCTest
import GRDB
@testable import FrontbotCore

final class AgentClientStudyTests: XCTestCase {
    var db: AppDatabase!
    var agent: Agent!
    var root: URL!

    func makeClient() throws -> AgentClient {
        db = try AppDatabase.inMemory()
        let ws = try db.ensureDefaultWorkspace()
        agent = try db.createAgent(workspaceId: ws.id, draft: AgentDraft(name: "A", instructions: "x"), status: .active)
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let node = ProcessInfo.processInfo.environment["FRONTBOT_NODE"] ?? "/opt/homebrew/bin/node"
        let script = AgentClientTests.repoRoot.appendingPathComponent("agent/dist/main.js").path
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: node), "No hay node en \(node)")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: script), "Compila el sidecar: cd agent && npm run build")
        let config = AgentConfig(nodePath: node, scriptPath: script, apiKey: nil, model: AgentConfig.defaultModel, fakeAgent: true)
        return AgentClient(config: config, db: db, files: BrandFiles(paths: AppPaths(root: root)), workspaceId: ws.id)
    }

    func finished(_ stream: AsyncStream<AgentUpdate>, _ runId: String) async -> AgentRun? {
        for await update in stream { if case .finished(let r) = update, r.id == runId { return r } }
        return nil
    }

    func context() throws -> AgentClient.StudyContext {
        let topic = try db.openTopic(agentId: agent.id, question: "¿q?", why: "w", origin: .user, now: .dbNow())
        let session = try db.startLabSession(topicId: topic.id, now: .dbNow())
        return AgentClient.StudyContext(topic: topic, session: session, budgetTokens: 100_000, allowOpus: false)
    }

    func testStudyRunFinishesSessionWithTokensAndOutcome() async throws {
        let client = try makeClient()
        let ctx = try context()
        let stream = await client.updates()
        let run = try await client.run(prompt: "estudiar y pausar", agent: agent, brand: nil, study: ctx)
        let result = await finished(stream, run.id)
        XCTAssertEqual(result?.status, .done)
        let session = try XCTUnwrap(try db.labSession(id: ctx.session.id))
        XCTAssertEqual(session.status, .done)
        XCTAssertEqual(session.tokens, 1234)
        XCTAssertEqual(session.outcome, .pause)
        XCTAssertEqual(session.models, [LabModelUsage(model: "claude-haiku-4-5-20251001", tokens: 1234)])
        XCTAssertEqual(try db.topic(id: ctx.topic.id)?.status, .paused)
        XCTAssertEqual(try db.entries(topicId: ctx.topic.id).map(\.text), ["nota de prueba"])
        await client.stop()
    }

    func testStudyRunWithoutEndDefaultsToContinue() async throws {
        let client = try makeClient()
        let ctx = try context()
        let stream = await client.updates()
        let run = try await client.run(prompt: "estudiar", agent: agent, brand: nil, study: ctx)
        _ = await finished(stream, run.id)
        let session = try XCTUnwrap(try db.labSession(id: ctx.session.id))
        XCTAssertEqual(session.outcome, .continue)
        XCTAssertEqual(try db.topic(id: ctx.topic.id)?.status, .studying)
        XCTAssertEqual(try db.topic(id: ctx.topic.id)?.sessions, 1)
        await client.stop()
    }

    func testCrashDuringStudyMarksFailed() async throws {
        let client = try makeClient()
        let ctx = try context()
        let stream = await client.updates()
        let run = try await client.run(prompt: "crash", agent: agent, brand: nil, study: ctx)
        let result = await finished(stream, run.id)
        XCTAssertEqual(result?.status, .failed)
        let session = try XCTUnwrap(try db.labSession(id: ctx.session.id))
        XCTAssertEqual(session.status, .failed)
        XCTAssertEqual(try db.topic(id: ctx.topic.id)?.consecutiveFailures, 1)
        await client.stop()
    }
}
