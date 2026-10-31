import XCTest
@testable import FrontbotCore

final class ImageImportToolTests: XCTestCase {
    final class FakeDownloader: DatasetDownloader, @unchecked Sendable {
        var body = (try? AssetImporterTests.encoded("public.png")) ?? Data()
        var fail = false
        func download(_ url: URL, to file: URL, maxBytes: Int) async throws {
            if fail { throw ValidationError("Solo se descargan datos públicos: x es una dirección local.") }
            try body.write(to: file)
        }
    }

    var db: AppDatabase!
    var brand: Brand!
    var root: URL!
    var downloader: FakeDownloader!
    var tool: ImageImportTool!

    override func setUpWithError() throws {
        db = try AppDatabase.inMemory()
        let ws = try db.ensureDefaultWorkspace()
        brand = try db.createBrand(workspaceId: ws.id, name: "B", industry: "", networks: [.instagram])
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        downloader = FakeDownloader()
        tool = ImageImportTool(importer: AssetImporter(db: db, paths: AppPaths(root: root)), fetcher: RemoteImageFetcher(downloader: downloader))
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func params(_ kind: String, run: String = "r1", brandId: String? = nil) -> JSONValue {
        ["run_id": .string(run), "brand_id": .string(brandId ?? brand.id), "url": "https://cdn.example.com/a.png", "kind": .string(kind)]
    }

    func testStoresAsset() async throws {
        let result = try await tool.handle(params("image"))
        XCTAssertNotNil(result["asset_id"]?.stringValue)
        XCTAssertEqual(result["kind"], "image")
        XCTAssertEqual(try db.assets(brandId: brand.id, kind: .image).count, 1)
    }

    func testLimitsPerRun() async throws {
        _ = try await tool.handle(params("logo"))
        do { _ = try await tool.handle(params("logo")); XCTFail("2º logo") } catch let e as ValidationError { XCTAssertTrue(e.message.contains("1 logo"), e.message) }
        for _ in 0..<8 { _ = try await tool.handle(params("image")) }
        do { _ = try await tool.handle(params("image")); XCTFail("9ª imagen") } catch let e as ValidationError { XCTAssertTrue(e.message.contains("8 imágenes"), e.message) }
        _ = try await tool.handle(params("logo", run: "r2"))
        await tool.endRun("r1")
        _ = try await tool.handle(params("logo"))
    }

    func testFailedDownloadDoesNotUseTheSlot() async throws {
        downloader.fail = true
        do { _ = try await tool.handle(params("logo")); XCTFail() } catch is ValidationError {}
        downloader.fail = false
        _ = try await tool.handle(params("logo"))
    }

    /// Si el run se para durante la descarga, no se guarda nada.
    func testCancelledImportStoresNothing() async throws {
        let slow = SlowDownloader()
        let tool = ImageImportTool(importer: AssetImporter(db: db, paths: AppPaths(root: root)), fetcher: RemoteImageFetcher(downloader: slow))
        let p = params("image")
        let task = Task { try await tool.handle(p) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        _ = try? await task.value
        XCTAssertEqual(try db.assets(brandId: brand.id, kind: nil), [])
    }

    /// Ignora la cancelación (como una descarga que ya terminó) y tarda un poco.
    final class SlowDownloader: DatasetDownloader, @unchecked Sendable {
        func download(_ url: URL, to file: URL, maxBytes: Int) async throws {
            let start = Date()
            while Date().timeIntervalSince(start) < 0.3 { usleep(10_000) }
            try Data(try AssetImporterTests.encoded("public.png")).write(to: file)
        }
    }

    func testUnknownBrandAndBadKind() async {
        do { _ = try await tool.handle(params("image", brandId: UUID().uuidString)); XCTFail() } catch is ValidationError {} catch { XCTFail("\(error)") }
        do { _ = try await tool.handle(params("guide_source")); XCTFail() } catch is ValidationError {} catch { XCTFail("\(error)") }
        XCTAssertEqual(try db.assets(brandId: brand.id, kind: nil), [])
    }
}
