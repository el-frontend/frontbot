import XCTest
@testable import FrontbotCore

final class AgentClientImageTests: XCTestCase {
    var db: AppDatabase!
    var agent: Agent!
    var brand: Brand!
    var root: URL!

    /// Bloquea a partir de la imagen `blockFrom` (1-based) hasta que la cancelen.
    final class GateRenderer: HTMLRendering, @unchecked Sendable {
        let blockFrom: Int
        private let lock = NSLock()
        private var calls = 0
        init(blockFrom: Int = .max) { self.blockFrom = blockFrom }
        func render(html: String, size: ImageSize) async throws -> Data {
            let n = lock.withLock { calls += 1; return calls }
            if n >= blockFrom { try await Task.sleep(for: .seconds(60)) }
            return ImageProviderTests.png1x1
        }
    }

    func makeClient(renderer: HTMLRendering = GateRenderer()) throws -> AgentClient {
        db = try AppDatabase.inMemory()
        let ws = try db.ensureDefaultWorkspace()
        agent = try db.createAgent(workspaceId: ws.id, draft: AgentDraft(name: "A", instructions: "x"), status: .active)
        brand = try db.createBrand(workspaceId: ws.id, name: "B", industry: "", networks: [.instagram])
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let node = ProcessInfo.processInfo.environment["FRONTBOT_NODE"] ?? "/opt/homebrew/bin/node"
        let script = AgentClientTests.repoRoot.appendingPathComponent("agent/dist/main.js").path
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: node), "No hay node en \(node)")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: script), "Compila el sidecar: cd agent && npm run build")
        let config = AgentConfig(nodePath: node, scriptPath: script, apiKey: nil, model: AgentConfig.defaultModel, fakeAgent: true)
        let paths = AppPaths(root: root)
        let tool = ImageCreateTool(importer: AssetImporter(db: db, paths: paths), renderer: renderer, provider: { nil })
        return AgentClient(config: config, db: db, files: BrandFiles(paths: paths), workspaceId: ws.id, cancelGrace: .seconds(1), imageTool: tool)
    }

    override func tearDownWithError() throws { if let root { try? FileManager.default.removeItem(at: root) } }

    func plan(_ count: Int) -> ImageRunPlan {
        ImageRunPlan(brandId: brand.id, kind: .html, count: count, size: .forNetwork(.instagram))
    }

    /// Junta las imágenes creadas de un run hasta que termina.
    func collect(_ stream: AsyncStream<AgentUpdate>, _ runId: String) async -> (created: [String], run: AgentRun?) {
        var created: [String] = []
        for await update in stream {
            if case .imageCreated(let r, let asset) = update, r == runId { created.append(asset) }
            if case .finished(let run) = update, run.id == runId { return (created, run) }
        }
        return (created, nil)
    }

    func testImageRunCreatesAssetsInOrder() async throws {
        let client = try makeClient()
        let stream = await client.updates()
        let run = try await client.run(prompt: "p", agent: agent, brand: brand, image: plan(3))
        let result = await collect(stream, run.id)
        XCTAssertEqual(result.run?.status, .done)
        XCTAssertEqual(result.created.count, 3)
        XCTAssertEqual(Set(result.created).count, 3)
        let stored = try db.assets(brandId: brand.id, kind: .image).map(\.id)
        XCTAssertEqual(Set(stored), Set(result.created))
    }

    func testImageRunSkipsMemory() async throws {
        let client = try makeClient()
        _ = try db.remember(agentId: agent.id, text: "le gusta el rosa")
        let stream = await client.updates()
        let run = try await client.run(prompt: "p", agent: agent, brand: brand, image: plan(1))
        let result = await collect(stream, run.id)
        XCTAssertEqual(result.run?.resultSummary, "1 mem:0")
        XCTAssertEqual(result.run?.prompt, "p")
    }

    func testImageToolOutsideRunFails() async throws {
        let client = try makeClient()
        // FakeRunner pide una imagen a nombre de una corrida que no existe y devuelve la respuesta de la app.
        let stream = await client.updates()
        let run = try await client.run(prompt: "otra corrida", agent: agent, brand: brand, image: plan(1))
        let result = await collect(stream, run.id)
        XCTAssertEqual(result.run?.resultSummary, "Esta corrida ya terminó.")
        XCTAssertEqual(try db.assets(brandId: brand.id, kind: .image).count, 0)
    }

    func testCancelKeepsCreatedImages() async throws {
        let client = try makeClient(renderer: GateRenderer(blockFrom: 2))
        let stream = await client.updates()
        let run = try await client.run(prompt: "p", agent: agent, brand: brand, image: plan(3))
        var created: [String] = []
        for await update in stream {
            if case .imageCreated(let r, let asset) = update, r == run.id {
                created.append(asset)
                await client.cancel(runId: run.id)
            }
            if case .finished(let done) = update, done.id == run.id { break }
        }
        XCTAssertEqual(created.count, 1)
        XCTAssertEqual(try db.assets(brandId: brand.id, kind: .image).count, 1)
    }
}
