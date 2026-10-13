import XCTest
@testable import FrontbotCore

/// Hallazgos de la revisión final: escrituras a un sidecar muerto, salida de procesos viejos,
/// keys con espacios, runs colgados y runs que quedan "running".
final class AgentClientRobustnessTests: XCTestCase {
    var db: AppDatabase!
    var ws: Workspace!
    var root: URL!

    func makeClient(apiKey: String? = nil, fake: Bool = true, cancelGrace: Duration = .seconds(10)) throws -> AgentClient {
        db = try AppDatabase.inMemory()
        ws = try db.ensureDefaultWorkspace()
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let node = ProcessInfo.processInfo.environment["FRONTBOT_NODE"] ?? "/opt/homebrew/bin/node"
        let script = AgentClientTests.repoRoot.appendingPathComponent("agent/dist/main.js").path
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: node), "No hay node en \(node); usa FRONTBOT_NODE=$(which node)")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: script), "Compila el sidecar: cd agent && npm run build")
        let config = AgentConfig(nodePath: node, scriptPath: script, apiKey: apiKey, model: AgentConfig.defaultModel, fakeAgent: fake)
        return AgentClient(config: config, db: db, files: BrandFiles(paths: AppPaths(root: root)), workspaceId: ws.id, cancelGrace: cancelGrace)
    }

    func finished(_ stream: AsyncStream<AgentUpdate>, _ runId: String) async -> AgentRun? {
        for await update in stream { if case .finished(let r) = update, r.id == runId { return r } }
        return nil
    }

    // 1. SIGPIPE
    func testWritingToClosedPipeThrowsInsteadOfKillingProcess() throws {
        let pipe = Pipe()
        pipe.disableSigpipe()
        try pipe.fileHandleForReading.close()
        XCTAssertThrowsError(try pipe.fileHandleForWriting.write(contentsOf: Data("x\n".utf8)))
    }

    // 2. Salida de un proceso ya reemplazado
    func testOutputFromStaleProcessGenerationIsIgnored() async throws {
        let client = try makeClient()
        let stream = await client.updates()
        let run = try await client.run(prompt: "lento", brand: nil)
        let stale = try RPCMessage.notification(method: "agent.done", params: [
            "run_id": .string(run.id), "ok": true, "summary": "viejo", "input_tokens": 0, "output_tokens": 0, "cost_usd": 0,
        ]).encodedLine()
        await client.receive(stale, generation: -1)
        XCTAssertEqual(try db.runs(workspaceId: ws.id).first?.status, .running)
        await client.cancel(runId: run.id)
        let result = await finished(stream, run.id)
        XCTAssertEqual(result?.resultSummary, "Cancelado")
        await client.stop()
    }

    // 3. Keys con espacios / saltos de línea
    func testApiKeyNormalization() {
        XCTAssertEqual(CredentialStore.normalizedApiKey("  sk-ant-1 \n"), "sk-ant-1")
        XCTAssertNil(CredentialStore.normalizedApiKey("\n \t"))
        XCTAssertNil(CredentialStore.normalizedApiKey(nil))
    }

    func testNewlineOnlyKeyCountsAsMissing() async throws {
        let client = try makeClient(apiKey: "\n", fake: false)
        do {
            _ = try await client.run(prompt: "hola", brand: nil)
            XCTFail("debió fallar")
        } catch let error as AgentClientError {
            XCTAssertEqual(error, .missingApiKey)
        }
    }

    // 4. Un run que nunca termina se puede detener
    func testCancelOnHungRunFailsItAfterGracePeriod() async throws {
        let client = try makeClient(cancelGrace: .milliseconds(500))
        let stream = await client.updates()
        let run = try await client.run(prompt: "colgado", brand: nil)
        await client.cancel(runId: run.id)
        let result = await finished(stream, run.id)
        XCTAssertEqual(result?.status, .failed)
        XCTAssertEqual(result?.resultSummary, "Cancelado")
        await client.stop()
    }

    // 5a. run() lanza después de crear el registro
    func testRunThatThrowsAfterStartIsMarkedFailed() async throws {
        let client = try makeClient()
        let brand = try db.createBrand(workspaceId: ws.id, name: "B", industry: "", networks: [.instagram])
        // guide.md como carpeta: readGuide lanza.
        try FileManager.default.createDirectory(at: AppPaths(root: root).guide(brand.id), withIntermediateDirectories: true)
        do {
            _ = try await client.run(prompt: "hola", brand: brand)
            XCTFail("debió fallar")
        } catch {}
        XCTAssertEqual(try db.runs(workspaceId: ws.id).map(\.status), [.failed])
        await client.stop()
    }

    // 5b. Relanzar antes de procesar la salida del proceso anterior
    func testRunsOfCrashedProcessFailEvenIfRelaunchedImmediately() async throws {
        let client = try makeClient()
        let stream = await client.updates()
        let crashed = try await client.run(prompt: "crash", brand: nil)
        try await Task.sleep(for: .milliseconds(300)) // el proceso ya murió, quizá sin drenar su EOF
        let next = try await client.run(prompt: "hola", brand: nil)
        var seen: [String: RunStatus] = [:]
        for await update in stream {
            if case .finished(let r) = update { seen[r.id] = r.status }
            if seen[crashed.id] != nil, seen[next.id] != nil { break }
        }
        XCTAssertEqual(seen[crashed.id], .failed)
        XCTAssertEqual(seen[next.id], .done)
        await client.stop()
    }
}
