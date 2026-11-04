import XCTest
@testable import FrontbotCore

/// Sidecar real en modo fake (FRONTBOT_FAKE_AGENT=1): la sesión de Codex se simula con FRONTBOT_FAKE_CODEX_SESSION.
final class AgentClientCodexTests: XCTestCase {
    var db: AppDatabase!
    var agent: Agent!

    func makeClient(session: Bool) throws -> AgentClient {
        setenv("FRONTBOT_FAKE_CODEX_SESSION", session ? "1" : "0", 1)
        db = try AppDatabase.inMemory()
        let ws = try db.ensureDefaultWorkspace()
        agent = try db.createAgent(workspaceId: ws.id, draft: AgentDraft(name: "C", instructions: "x", provider: .codex), status: .active)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let node = ProcessInfo.processInfo.environment["FRONTBOT_NODE"] ?? "/opt/homebrew/bin/node"
        let script = AgentClientTests.repoRoot.appendingPathComponent("agent/dist/main.js").path
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: node), "No hay node en \(node)")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: script), "Compila el sidecar: cd agent && npm run build")
        let config = AgentConfig(nodePath: node, scriptPath: script, apiKey: nil, model: AgentConfig.defaultModel, fakeAgent: true)
        return AgentClient(config: config, db: db, files: BrandFiles(paths: AppPaths(root: root)), workspaceId: ws.id, cancelGrace: .seconds(1))
    }

    private func finished(_ stream: AsyncStream<AgentUpdate>, _ runId: String) async -> AgentRun? {
        for await update in stream { if case .finished(let r) = update, r.id == runId { return r } }
        return nil
    }

    func testCodexStatusConnected() async throws {
        let client = try makeClient(session: true)
        let status = try await client.codexStatus()
        XCTAssertTrue(status.connected)
        XCTAssertEqual(status.email, "fake@frontbot.test")
        let connected = await client.codexConnected
        XCTAssertTrue(connected)
        await client.stop()
    }

    func testRunSendsSessionRuntime() async throws {
        let client = try makeClient(session: true)
        _ = try await client.codexStatus()
        let stream = await client.updates()
        let run = try await client.run(prompt: "hola", agent: agent, brand: nil)
        let done = await finished(stream, run.id)
        XCTAssertEqual(done?.runtime, "session")
        await client.stop()
    }

    func testRunWithoutSessionUsesApi() async throws {
        let client = try makeClient(session: false)
        await client.setCodexConnected(false)
        let stream = await client.updates()
        let run = try await client.run(prompt: "hola", agent: agent, brand: nil)
        let done = await finished(stream, run.id)
        XCTAssertEqual(done?.runtime, "api")
        await client.stop()
    }

    func testSidecarGetsCodexHome() {
        let config = AgentConfig(nodePath: "/n", scriptPath: "/s", apiKey: nil, model: AgentConfig.defaultModel, fakeAgent: false)
        let env = AgentClient.sidecarEnvironment(config: config, inherited: ["PATH": "/bin", "FRONTBOT_FAKE_CODEX_SESSION": "1"], codexHome: "/data/codex-home")
        XCTAssertEqual(env["FRONTBOT_CODEX_HOME"], "/data/codex-home")
        XCTAssertNil(env["FRONTBOT_FAKE_CODEX_SESSION"], "solo pasa en modo fake")
    }
}
