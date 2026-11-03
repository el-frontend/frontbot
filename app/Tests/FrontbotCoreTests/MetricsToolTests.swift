import XCTest
@testable import FrontbotCore

final class MetricsToolTests: XCTestCase {
    var db: AppDatabase!
    var root: URL!
    var store: PostMetadataStore!
    var tool: MetricsTool!
    var post: Post!

    override func setUpWithError() throws {
        db = try AppDatabase.inMemory()
        let ws = try db.ensureDefaultWorkspace()
        let brand = try db.createBrand(workspaceId: ws.id, name: "B", industry: "", networks: [.linkedin])
        try db.setBrandLinks(brandId: brand.id, links: ["https://www.linkedin.com/company/b"])
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = PostMetadataStore(paths: AppPaths(root: root))
        tool = MetricsTool(db: db, store: store)
        let draft = try db.createDraft(brandId: brand.id, network: .linkedin, body: "hola mundo", media: [], scheduledFor: nil)
        _ = try db.transitionPost(id: draft.id, to: .approved, actor: .user)
        _ = try db.transitionPost(id: draft.id, to: .preparing, actor: .user)
        post = try db.markPublished(id: draft.id, url: "https://www.linkedin.com/feed/update/1")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func record(_ extra: [String: JSONValue] = [:], postId: String? = nil) -> JSONValue {
        var p: [String: JSONValue] = ["run_id": "r1", "post_id": .string(postId ?? post.id)]
        for (k, v) in extra { p[k] = v }
        return .object(p)
    }

    func testMetricsPostReturnsRunPost() async throws {
        do { _ = try await tool.handle(method: "tool.metrics_post", params: ["run_id": "r1"]); XCTFail() } catch is ValidationError {}
        await tool.beginRun("r1", plan: MetricsRunPlan(postId: post.id, checkpoint: .h24))
        let (result, outcome) = try await tool.handle(method: "tool.metrics_post", params: ["run_id": "r1"])
        XCTAssertNil(outcome)
        XCTAssertEqual(result["post_id"]?.stringValue, post.id)
        XCTAssertEqual(result["body"], "hola mundo")
        XCTAssertEqual(result["network"], "linkedin")
        XCTAssertEqual(result["published_url"], "https://www.linkedin.com/feed/update/1")
        XCTAssertEqual(result["brand"]?["links"], ["https://www.linkedin.com/company/b"])
    }

    func testRecordWritesPlannedCheckpoint() async throws {
        await tool.beginRun("r1", plan: MetricsRunPlan(postId: post.id, checkpoint: .h48))
        let (_, outcome) = try await tool.handle(method: "tool.posts_record_metrics", params: record(["likes": 12, "reach": .null, "views": 300]))
        XCTAssertEqual(outcome, .recorded)
        let readings = store.read(postId: post.id).metrics
        XCTAssertEqual(readings.count, 1)
        XCTAssertEqual(readings.first?.checkpoint, .h48)
        XCTAssertEqual(readings.first?.likes, 12)
        XCTAssertEqual(readings.first?.views, 300)
        XCTAssertNil(readings.first?.reach)
    }

    func testRejectsOtherPost() async throws {
        await tool.beginRun("r1", plan: MetricsRunPlan(postId: post.id, checkpoint: .h24))
        do { _ = try await tool.handle(method: "tool.posts_record_metrics", params: record(["likes": 1], postId: "otro")); XCTFail() } catch is ValidationError {}
        XCTAssertEqual(store.read(postId: post.id).metrics.count, 0)
    }

    func testOneReadingPerRun() async throws {
        await tool.beginRun("r1", plan: MetricsRunPlan(postId: post.id, checkpoint: .h24))
        _ = try await tool.handle(method: "tool.posts_record_metrics", params: record(["likes": 1]))
        do { _ = try await tool.handle(method: "tool.posts_record_metrics", params: record(["likes": 2])); XCTFail() } catch is ValidationError {}
        XCTAssertEqual(store.read(postId: post.id).metrics.count, 1)
    }

    func testUnavailableWritesNothing() async throws {
        await tool.beginRun("r1", plan: MetricsRunPlan(postId: post.id, checkpoint: .h24))
        let (_, outcome) = try await tool.handle(method: "tool.posts_record_metrics", params: record(["unavailable": true]))
        XCTAssertEqual(outcome, .unavailable)
        XCTAssertEqual(store.read(postId: post.id).metrics.count, 0)
    }

    func testNegativeNumbersRejected() async throws {
        await tool.beginRun("r1", plan: MetricsRunPlan(postId: post.id, checkpoint: .h24))
        do { _ = try await tool.handle(method: "tool.posts_record_metrics", params: record(["likes": -1])); XCTFail() } catch is ValidationError {}
        XCTAssertEqual(store.read(postId: post.id).metrics.count, 0)
    }
}
