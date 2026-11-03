import XCTest
@testable import FrontbotCore

final class ImageCreateToolTests: XCTestCase {
    static let png = ImageProviderTests.png1x1

    final class FakeRenderer: HTMLRendering, @unchecked Sendable {
        var sizes: [ImageSize] = []
        var htmls: [String] = []
        var failNext = false
        var hang = false
        func render(html: String, size: ImageSize) async throws -> Data {
            sizes.append(size); htmls.append(html)
            if failNext { failNext = false; throw ValidationError("render roto") }
            if hang { try await Task.sleep(for: .seconds(30)) }
            return ImageCreateToolTests.png
        }
    }

    struct FakeProvider: ImageProvider {
        func generate(prompt: String, size: ImageSize) async throws -> Data { ImageCreateToolTests.png }
    }

    var db: AppDatabase!
    var brand: Brand!
    var root: URL!
    var renderer: FakeRenderer!
    var importer: AssetImporter!

    override func setUpWithError() throws {
        db = try AppDatabase.inMemory()
        let ws = try db.ensureDefaultWorkspace()
        brand = try db.createBrand(workspaceId: ws.id, name: "B", industry: "", networks: [.instagram])
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        renderer = FakeRenderer()
        importer = AssetImporter(db: db, paths: AppPaths(root: root))
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func makeTool(withKey: Bool = true) -> ImageCreateTool {
        ImageCreateTool(importer: importer, renderer: renderer, provider: { withKey ? FakeProvider() : nil })
    }

    func html(_ run: String = "r1", network: String? = nil) -> JSONValue {
        var p: [String: JSONValue] = ["run_id": .string(run), "brand_id": .string(brand.id), "html": "<b>{{logo}}</b>"]
        if let network { p["network"] = .string(network) }
        return .object(p)
    }

    func ai(_ run: String = "r1") -> JSONValue {
        ["run_id": .string(run), "brand_id": .string(brand.id), "prompt": "a cup"]
    }

    func images() throws -> Int { try db.assets(brandId: brand.id, kind: .image).count }

    func testImageRunHonorsPlan() async throws {
        let tool = makeTool()
        await tool.beginRun("r1", plan: ImageRunPlan(brandId: brand.id, kind: .html, count: 2, size: ImageSize(width: 1200, height: 1500)))
        _ = try await tool.handle(method: "tool.images_render_html", params: html(network: "instagram"))
        let second = try await tool.handle(method: "tool.images_render_html", params: html())
        XCTAssertNotNil(second["asset_id"]?.stringValue)
        do { _ = try await tool.handle(method: "tool.images_render_html", params: html()); XCTFail() } catch is ValidationError {}
        XCTAssertEqual(try images(), 2)
        XCTAssertEqual(renderer.sizes, [ImageSize(width: 1200, height: 1500), ImageSize(width: 1200, height: 1500)])
    }

    func testImageRunRejectsOtherKind() async throws {
        let tool = makeTool()
        await tool.beginRun("r1", plan: ImageRunPlan(brandId: brand.id, kind: .html, count: 2, size: .forNetwork(.instagram)))
        do { _ = try await tool.handle(method: "tool.images_generate", params: ai()); XCTFail() } catch is ValidationError {}
        XCTAssertEqual(try images(), 0)
    }

    func testChatRunLimits() async throws {
        let tool = makeTool()
        for _ in 0..<ImageCreateTool.chatMaxHTML { _ = try await tool.handle(method: "tool.images_render_html", params: html(network: "linkedin")) }
        do { _ = try await tool.handle(method: "tool.images_render_html", params: html()); XCTFail() } catch is ValidationError {}
        for _ in 0..<ImageCreateTool.chatMaxAI { _ = try await tool.handle(method: "tool.images_generate", params: ai()) }
        do { _ = try await tool.handle(method: "tool.images_generate", params: ai()); XCTFail() } catch is ValidationError {}
        XCTAssertEqual(renderer.sizes.first, ImageSize(width: 1200, height: 1500))
        _ = try await tool.handle(method: "tool.images_render_html", params: html("r2"))
        XCTAssertEqual(renderer.sizes.last, ImageSize(width: 1080, height: 1350))
    }

    func testGenerateWithoutKeyThrows() async throws {
        do {
            _ = try await makeTool(withKey: false).handle(method: "tool.images_generate", params: ai())
            XCTFail()
        } catch let error as ValidationError {
            XCTAssertTrue(error.message.contains("API key de OpenAI"), error.message)
        }
    }

    func testLogoPlaceholderReplaced() async throws {
        let tool = makeTool()
        _ = try await tool.handle(method: "tool.images_render_html", params: html())
        XCTAssertEqual(renderer.htmls.last, "<b></b>")
        _ = try importer.importImage(data: Self.png, brandId: brand.id, kind: .logo)
        _ = try await tool.handle(method: "tool.images_render_html", params: html())
        let last = try XCTUnwrap(renderer.htmls.last)
        XCTAssertTrue(last.contains("data:image/png;base64,"))
        XCTAssertFalse(last.contains("{{logo}}"))
    }

    func testFailureReleasesQuota() async throws {
        let tool = makeTool()
        await tool.beginRun("r1", plan: ImageRunPlan(brandId: brand.id, kind: .html, count: 1, size: .forNetwork(.instagram)))
        renderer.failNext = true
        do { _ = try await tool.handle(method: "tool.images_render_html", params: html()); XCTFail() } catch is ValidationError {}
        _ = try await tool.handle(method: "tool.images_render_html", params: html())
        XCTAssertEqual(try images(), 1)
    }

    func testCancelledRenderStoresNothing() async throws {
        let tool = makeTool()
        renderer.hang = true
        let params = html()
        let task = Task { try await tool.handle(method: "tool.images_render_html", params: params) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        _ = try? await task.value
        XCTAssertEqual(try images(), 0)
    }
}

extension ImageCreateToolTests {
    /// Guardar la key en Ajustes no reinicia la app: la siguiente foto ya la usa.
    func testProviderCanChangeAtRuntime() async throws {
        let tool = makeTool(withKey: false)
        await tool.setProvider { FakeProvider() }
        _ = try await tool.handle(method: "tool.images_generate", params: ai())
        XCTAssertEqual(try images(), 1)
    }
}
