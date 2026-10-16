import XCTest
@testable import FrontbotCore

final class AgentClientTests: XCTestCase {
    var db: AppDatabase!
    var ws: Workspace!
    var root: URL!

    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    func makeClient(apiKey: String? = nil, fake: Bool = true) throws -> AgentClient {
        db = try AppDatabase.inMemory()
        ws = try db.ensureDefaultWorkspace()
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let node = ProcessInfo.processInfo.environment["FRONTBOT_NODE"] ?? "/opt/homebrew/bin/node"
        let script = Self.repoRoot.appendingPathComponent("agent/dist/main.js").path
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: node), "No hay node en \(node); usa FRONTBOT_NODE=$(which node)")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: script), "Compila el sidecar: cd agent && npm run build")
        let config = AgentConfig(nodePath: node, scriptPath: script, apiKey: apiKey, model: AgentConfig.defaultModel, fakeAgent: fake)
        return AgentClient(config: config, db: db, files: BrandFiles(paths: AppPaths(root: root)), workspaceId: ws.id)
    }

    /// Siempre suscribirse ANTES de llamar a run(): el agente falso puede terminar en milisegundos.
    /// Cada llamada usa un stream nuevo (un AsyncStream no se reitera tras un `break`).
    func finished(_ stream: AsyncStream<AgentUpdate>, _ runId: String) async -> AgentRun? {
        for await update in stream { if case .finished(let r) = update, r.id == runId { return r } }
        return nil
    }

    func testFakeRunCreatesDraftThroughTools() async throws {
        let client = try makeClient()
        let brand = try db.createBrand(workspaceId: ws.id, name: "Café Sol", industry: "", networks: [.instagram])
        let stream = await client.updates()
        let run = try await client.run(prompt: "crear post", brand: brand)
        let result = await finished(stream, run.id)
        XCTAssertEqual(result?.status, .done)
        XCTAssertEqual(result?.resultSummary, "Tienes 1 marca(s).")
        XCTAssertEqual(try db.posts(brandId: brand.id, status: .draft).map(\.body), ["Post de prueba"])
        await client.stop()
    }

    func testSidecarCrashFailsRunAndNextRunWorks() async throws {
        let client = try makeClient()
        let stream = await client.updates()
        let crashed = try await client.run(prompt: "crash", brand: nil)
        let failed = await finished(stream, crashed.id)
        XCTAssertEqual(failed?.status, .failed)
        XCTAssertEqual(failed?.resultSummary, "El agente se detuvo inesperadamente.")

        let stream2 = await client.updates()
        let next = try await client.run(prompt: "hola", brand: nil)
        let done = await finished(stream2, next.id)
        XCTAssertEqual(done?.status, .done)
        await client.stop()
    }

    func testCancelMarksRunFailed() async throws {
        let client = try makeClient()
        let stream = await client.updates()
        let run = try await client.run(prompt: "lento", brand: nil)
        await client.cancel(runId: run.id)
        let result = await finished(stream, run.id)
        XCTAssertEqual(result?.status, .failed)
        XCTAssertEqual(result?.resultSummary, "Cancelado")
        await client.stop()
    }
}
