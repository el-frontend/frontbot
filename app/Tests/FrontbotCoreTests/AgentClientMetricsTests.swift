import XCTest
@testable import FrontbotCore

final class AgentClientMetricsTests: XCTestCase {
    var db: AppDatabase!
    var agent: Agent!
    var brand: Brand!
    var post: Post!
    var root: URL!
    var store: PostMetadataStore!

    func makeClient(imageTool: ImageCreateTool? = nil) throws -> AgentClient {
        db = try AppDatabase.inMemory()
        let ws = try db.ensureDefaultWorkspace()
        agent = try db.createAgent(workspaceId: ws.id, draft: AgentDraft(name: "A", instructions: "x"), status: .active)
        brand = try db.createBrand(workspaceId: ws.id, name: "B", industry: "", networks: [.linkedin])
        let draft = try db.createDraft(brandId: brand.id, network: .linkedin, body: "hola", media: [], scheduledFor: nil)
        _ = try db.transitionPost(id: draft.id, to: .approved, actor: .user)
        _ = try db.transitionPost(id: draft.id, to: .preparing, actor: .user)
        post = try db.markPublished(id: draft.id, url: "https://www.linkedin.com/feed/update/1")
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = PostMetadataStore(paths: AppPaths(root: root))
        let node = ProcessInfo.processInfo.environment["FRONTBOT_NODE"] ?? "/opt/homebrew/bin/node"
        let script = AgentClientTests.repoRoot.appendingPathComponent("agent/dist/main.js").path
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: node), "No hay node en \(node)")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: script), "Compila el sidecar: cd agent && npm run build")
        let config = AgentConfig(nodePath: node, scriptPath: script, apiKey: nil, model: AgentConfig.defaultModel, fakeAgent: true)
        return AgentClient(config: config, db: db, files: BrandFiles(paths: AppPaths(root: root)), workspaceId: ws.id, cancelGrace: .seconds(1),
                           imageTool: imageTool ?? ImageCreateTool(importer: AssetImporter(db: db, paths: AppPaths(root: root)),
                                                                   renderer: AgentClientImageTests.GateRenderer(blockFrom: 1), provider: { nil }))
    }

    override func tearDownWithError() throws { if let root { try? FileManager.default.removeItem(at: root) } }

    func updates(_ stream: AsyncStream<AgentUpdate>, _ runId: String) async -> [AgentUpdate] {
        var seen: [AgentUpdate] = []
        for await update in stream {
            switch update {
            case .metricsRecorded(let r, _) where r == runId, .metricsUnavailable(let r) where r == runId: seen.append(update)
            case .finished(let run) where run.id == runId: seen.append(update); return seen
            default: break
            }
        }
        return seen
    }

    func testMetricsRunRecordsReading() async throws {
        let client = try makeClient()
        let stream = await client.updates()
        let run = try await client.run(prompt: "p", agent: agent, brand: brand, metrics: MetricsRunPlan(postId: post.id, checkpoint: .h24))
        let seen = await updates(stream, run.id)
        XCTAssertEqual(seen.first, .metricsRecorded(runId: run.id, postId: post.id))
        guard case .finished(let done)? = seen.last else { return XCTFail() }
        XCTAssertEqual(done.status, .done)
        let reading = try XCTUnwrap(store.read(postId: post.id).metrics.first)
        XCTAssertEqual(reading.checkpoint, .h24)
        XCTAssertEqual(reading.likes, 7)
        XCTAssertEqual(reading.views, 120)
        XCTAssertNil(reading.reach)
    }

    func testMetricsRunUnavailableWritesNothing() async throws {
        let client = try makeClient()
        let stream = await client.updates()
        let run = try await client.run(prompt: "sin chrome", agent: agent, brand: brand, metrics: MetricsRunPlan(postId: post.id, checkpoint: .h24))
        let seen = await updates(stream, run.id)
        XCTAssertEqual(seen.first, .metricsUnavailable(runId: run.id))
        XCTAssertEqual(store.read(postId: post.id).metrics.count, 0)
    }

    /// Comprobar "no hay otro run" y arrancar es atómico: si ya hay uno, la lectura automática no arranca.
    func testOnlyIfIdleRefusesWhenBusy() async throws {
        let client = try makeClient()
        // Un run de imagen que se queda renderizando ocupa el cliente.
        _ = try await client.run(prompt: "p", agent: agent, brand: brand,
                                 image: ImageRunPlan(brandId: brand.id, kind: .html, count: 1, size: .forNetwork(.linkedin)))
        do {
            _ = try await client.run(prompt: "p", agent: agent, brand: brand,
                                     metrics: MetricsRunPlan(postId: post.id, checkpoint: .h24), onlyIfIdle: true)
            XCTFail("debería negarse")
        } catch is AgentBusyError {}
        XCTAssertEqual(store.read(postId: post.id).metrics.count, 0)
    }
}
