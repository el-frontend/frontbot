import XCTest
@testable import FrontbotCore

final class ToolHandlerTests: XCTestCase {
    var db: AppDatabase!
    var handler: ToolHandler!
    var brand: Brand!
    var root: URL!

    override func setUpWithError() throws {
        db = try AppDatabase.inMemory()
        let ws = try db.ensureDefaultWorkspace()
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        handler = ToolHandler(db: db, files: BrandFiles(paths: AppPaths(root: root)), workspaceId: ws.id)
        brand = try db.createBrand(workspaceId: ws.id, name: "Café Sol", industry: "Cafetería", networks: [.instagram])
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testBrandsList() throws {
        let result = try handler.handle(method: "tool.brands_list", params: [:])
        XCTAssertEqual(result["brands"]?.arrayValue?.first?["name"]?.stringValue, "Café Sol")
        XCTAssertEqual(result["brands"]?.arrayValue?.first?["networks"], ["instagram"])
    }

    func testBrandsListIncludesLinks() throws {
        try db.setBrandLinks(brandId: brand.id, links: ["https://a.com"])
        let result = try handler.handle(method: "tool.brands_list", params: [:])
        XCTAssertEqual(result["brands"]?.arrayValue?.first?["links"], ["https://a.com"])
    }

    func testGuideWriteAndRead() throws {
        XCTAssertEqual(try handler.handle(method: "tool.brands_get_guide", params: ["brand_id": .string(brand.id)])["guide"], .null)
        _ = try handler.handle(method: "tool.brands_write_guide", params: ["brand_id": .string(brand.id), "markdown": "# Tono"])
        XCTAssertEqual(try handler.handle(method: "tool.brands_get_guide", params: ["brand_id": .string(brand.id)])["guide"], "# Tono")
    }

    func testCreateDraftThenList() throws {
        let created = try handler.handle(method: "tool.posts_create_draft", params: [
            "brand_id": .string(brand.id), "network": "instagram", "body": "Lunes de café ☕️", "scheduled_for": "2026-10-20T09:00:00Z",
        ])
        XCTAssertNotNil(created["post_id"]?.stringValue)
        let list = try handler.handle(method: "tool.posts_list", params: ["brand_id": .string(brand.id)])
        let post = list["posts"]?.arrayValue?.first
        XCTAssertEqual(post?["status"], "draft")
        XCTAssertEqual(post?["scheduled_for"], "2026-10-20T09:00:00Z")
    }

    func testUpdateDraftOnApprovedPostFailsAndKeepsBody() throws {
        let created = try handler.handle(method: "tool.posts_create_draft", params: ["brand_id": .string(brand.id), "network": "instagram", "body": "v1"])
        let id = created["post_id"]!.stringValue!
        _ = try db.transitionPost(id: id, to: .approved, actor: .user)
        XCTAssertThrowsError(try handler.handle(method: "tool.posts_update_draft", params: ["post_id": .string(id), "body": "v2"])) { error in
            XCTAssertEqual((error as? ValidationError)?.message, "Solo se pueden editar posts en borrador; este está en approved.")
        }
        XCTAssertEqual(try db.posts(brandId: brand.id, status: nil).first?.body, "v1")
    }

    func testInvalidNetworkAndMissingParams() {
        XCTAssertThrowsError(try handler.handle(method: "tool.posts_create_draft", params: ["brand_id": .string(brand.id), "network": "tiktok", "body": "x"])) { error in
            XCTAssertEqual((error as? ValidationError)?.message, "Red no soportada: tiktok. Usa instagram o linkedin.")
        }
        XCTAssertThrowsError(try handler.handle(method: "tool.posts_create_draft", params: ["brand_id": .string(brand.id), "network": "instagram"])) { error in
            XCTAssertEqual((error as? ValidationError)?.message, "Falta el parámetro body.")
        }
    }

    func testTasksCreateWithDateOnlyAndList() throws {
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"; fmt.locale = Locale(identifier: "en_US_POSIX")
        let today = fmt.string(from: Date())
        let created = try handler.handle(method: "tool.tasks_create", params: ["title": "Grabar reel", "due_date": .string(today)])
        let list = try handler.handle(method: "tool.tasks_list", params: ["date": .string(today)])
        XCTAssertEqual(list["tasks"]?.arrayValue?.first?["title"], "Grabar reel")
        _ = try handler.handle(method: "tool.tasks_complete", params: ["task_id": created["task_id"]!])
        XCTAssertEqual(try handler.handle(method: "tool.tasks_list", params: ["date": .string(today)])["tasks"]?.arrayValue?.first?["done"], true)
    }

    func testIdeasCreateWritesReport() throws {
        let result = try handler.handle(method: "tool.ideas_create", params: [
            "title": "Café de especialidad a domicilio", "summary": "Suscripción mensual", "sources": ["https://ejemplo.com"],
            "score": 4, "report_markdown": "# Reporte\nDetalle",
        ])
        let id = result["idea_id"]!.stringValue!
        let report = AppPaths(root: root).ideaReport(id)
        XCTAssertEqual(try String(contentsOf: report, encoding: .utf8), "# Reporte\nDetalle")
    }

    func testUnknownToolAndNoPublishTool() {
        for method in ["tool.posts_publish", "tool.posts_approve", "tool.nope"] {
            XCTAssertThrowsError(try handler.handle(method: method, params: [:])) { error in
                XCTAssertEqual((error as? ValidationError)?.message, "Herramienta desconocida: \(method).")
            }
        }
    }
}

extension ToolHandlerTests {
    func testPostsListIncludesLastMetrics() throws {
        let read = try db.createDraft(brandId: brand.id, network: .instagram, body: "a", media: [], scheduledFor: nil)
        let unread = try db.createDraft(brandId: brand.id, network: .instagram, body: "b", media: [], scheduledFor: nil)
        let store = PostMetadataStore(paths: AppPaths(root: root))
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        try store.record(postId: read.id, MetricsReading(checkpoint: .h24, readAt: at, reach: nil, views: 50, likes: 3, reposts: 0, sourceUrl: nil, note: nil))
        try store.record(postId: read.id, MetricsReading(checkpoint: .h48, readAt: at, reach: nil, views: 90, likes: 9, reposts: 1, sourceUrl: nil, note: nil))
        let posts = try handler.handle(method: "tool.posts_list", params: [:])["posts"]?.arrayValue ?? []
        let first = try XCTUnwrap(posts.first { $0["id"]?.stringValue == read.id })
        XCTAssertEqual(first["metrics"]?["checkpoint"], "48h")
        XCTAssertEqual(first["metrics"]?["likes"]?.intValue, 9)
        XCTAssertEqual(first["metrics"]?["reach"], .null)
        let second = try XCTUnwrap(posts.first { $0["id"]?.stringValue == unread.id })
        XCTAssertEqual(second["metrics"], .null)
    }
}
