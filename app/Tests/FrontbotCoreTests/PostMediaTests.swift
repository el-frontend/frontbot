import XCTest
@testable import FrontbotCore

final class PostMediaTests: XCTestCase {
    var db: AppDatabase!
    var a: Brand!
    var b: Brand!
    var imgA: BrandAsset!
    var imgB: BrandAsset!
    var root: URL!
    var handler: ToolHandler!

    override func setUpWithError() throws {
        db = try AppDatabase.inMemory()
        let ws = try db.ensureDefaultWorkspace()
        a = try db.createBrand(workspaceId: ws.id, name: "A", industry: "", networks: [.instagram])
        b = try db.createBrand(workspaceId: ws.id, name: "B", industry: "", networks: [.instagram])
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let importer = AssetImporter(db: db, paths: AppPaths(root: root))
        let png = root.appendingPathComponent("x.png")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).write(to: png)
        imgA = try importer.importImage(from: png, brandId: a.id)
        imgB = try importer.importImage(from: png, brandId: b.id)
        handler = ToolHandler(db: db, files: BrandFiles(paths: AppPaths(root: root)), workspaceId: ws.id)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testDraftAcceptsOwnBrandImage() throws {
        let post = try db.createDraft(brandId: a.id, network: .instagram, body: "hola", media: [imgA.id], scheduledFor: nil)
        XCTAssertEqual(post.media, [imgA.id])
    }

    func testDraftRejectsOtherBrandOrUnknownImage() throws {
        XCTAssertThrowsError(try db.createDraft(brandId: a.id, network: .instagram, body: "hola", media: [imgB.id], scheduledFor: nil)) { error in
            XCTAssertEqual((error as? ValidationError)?.message, "La imagen \(self.imgB.id) no pertenece a esta marca.")
        }
        let post = try db.createDraft(brandId: a.id, network: .instagram, body: "hola", media: [], scheduledFor: nil)
        XCTAssertThrowsError(try db.updateDraft(id: post.id, body: nil, media: ["inventado"], scheduledFor: nil))
        XCTAssertEqual(try db.posts(brandId: a.id, status: nil).first?.media, [])
    }

    func testAtMostTenImages() throws {
        XCTAssertThrowsError(try db.createDraft(brandId: a.id, network: .instagram, body: "hola", media: Array(repeating: imgA.id, count: 11), scheduledFor: nil)) { error in
            XCTAssertEqual((error as? ValidationError)?.message, "Un post admite máximo 10 imágenes.")
        }
    }

    func testUserCanEditApprovedPostAndClearDate() throws {
        let post = try db.createDraft(brandId: a.id, network: .instagram, body: "v1", media: [], scheduledFor: Date())
        _ = try db.transitionPost(id: post.id, to: .approved, actor: .user)
        let edited = try db.updatePostByUser(id: post.id, body: "v2", media: [imgA.id], scheduledFor: .some(nil))
        XCTAssertEqual(edited.body, "v2")
        XCTAssertEqual(edited.media, [imgA.id])
        XCTAssertNil(edited.scheduledFor)
        XCTAssertEqual(edited.status, .approved)
    }

    func testUserCannotEditPublishedPost() throws {
        let post = try db.createDraft(brandId: a.id, network: .instagram, body: "v1", media: [], scheduledFor: nil)
        _ = try db.transitionPost(id: post.id, to: .archived, actor: .user)
        XCTAssertThrowsError(try db.updatePostByUser(id: post.id, body: "v2", media: nil, scheduledFor: nil)) { error in
            XCTAssertEqual((error as? ValidationError)?.message, "Este post ya no se puede editar (archived).")
        }
    }

    func testToolListsAssetsWithoutPaths() throws {
        let result = try handler.handle(method: "tool.brands_list_assets", params: ["brand_id": .string(a.id)])
        let first = result["assets"]?.arrayValue?.first
        XCTAssertEqual(first?["id"]?.stringValue, imgA.id)
        XCTAssertEqual(first?["file_name"]?.stringValue, "\(imgA.id).png")
        XCTAssertFalse(String(describing: result).contains(root.path))
    }

    func testToolCreateDraftWithMedia() throws {
        let created = try handler.handle(method: "tool.posts_create_draft", params: [
            "brand_id": .string(a.id), "network": "instagram", "body": "hola", "media": [.string(imgA.id)],
        ])
        XCTAssertEqual(try db.posts(brandId: a.id, status: nil).first { $0.id == created["post_id"]?.stringValue }?.media, [imgA.id])
    }
}
