import XCTest
@testable import FrontbotCore

final class FakePreparer: PublicationPreparer, @unchecked Sendable {
    var calls: [(Network, String, [String])] = []
    var result = PreparationResult(mode: .composer, message: "ok", url: "https://www.instagram.com/")
    var error: Error?

    func preparePublication(network: Network, body: String, mediaPaths: [String]) async throws -> PreparationResult {
        calls.append((network, body, mediaPaths))
        if let error { throw error }
        return result
    }

    func openLogin(network: Network) async throws {}
}

final class PublishingServiceTests: XCTestCase {
    var db: AppDatabase!
    var brand: Brand!
    var image: BrandAsset!
    var root: URL!
    var preparer: FakePreparer!
    var service: PublishingService!

    override func setUpWithError() throws {
        db = try AppDatabase.inMemory()
        let ws = try db.ensureDefaultWorkspace()
        brand = try db.createBrand(workspaceId: ws.id, name: "B", industry: "", networks: [.instagram, .linkedin])
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let png = root.appendingPathComponent("x.png")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).write(to: png)
        image = try AssetImporter(db: db, paths: AppPaths(root: root)).importImage(from: png, brandId: brand.id)
        preparer = FakePreparer()
        service = PublishingService(db: db, preparer: preparer)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func approved(_ network: Network, media: [String]) throws -> Post {
        let p = try db.createDraft(brandId: brand.id, network: network, body: "hola", media: media, scheduledFor: nil)
        return try db.transitionPost(id: p.id, to: .approved, actor: .user)
    }

    func testPrepareMovesToPreparingAndPassesAbsolutePaths() async throws {
        let post = try approved(.instagram, media: [image.id])
        let (updated, result) = try await service.prepare(postId: post.id)
        XCTAssertEqual(updated.status, .preparing)
        XCTAssertEqual(result.mode, .composer)
        XCTAssertEqual(preparer.calls.first?.2, [image.path])
        XCTAssertEqual(preparer.calls.first?.1, "hola")
    }

    func testRejectsDraftAndInstagramWithoutImages() async throws {
        let draft = try db.createDraft(brandId: brand.id, network: .linkedin, body: "hola", media: [], scheduledFor: nil)
        do { _ = try await service.prepare(postId: draft.id); XCTFail() } catch let e as ValidationError {
            XCTAssertEqual(e.message, "Solo se pueden preparar posts aprobados.")
        }
        let ig = try approved(.instagram, media: [])
        do { _ = try await service.prepare(postId: ig.id); XCTFail() } catch let e as ValidationError {
            XCTAssertEqual(e.message, "Instagram necesita al menos una imagen.")
        }
        XCTAssertTrue(preparer.calls.isEmpty)
    }

    func testPreparerFailureRevertsToApproved() async throws {
        preparer.error = ValidationError("Chrome no está disponible")
        let post = try approved(.linkedin, media: [])
        do { _ = try await service.prepare(postId: post.id); XCTFail() } catch {}
        XCTAssertEqual(try db.posts(brandId: brand.id, status: nil).first { $0.id == post.id }?.status, .approved)
    }

    func testConfirmPublishedWithUrlAndValidation() async throws {
        let post = try approved(.linkedin, media: [])
        _ = try await service.prepare(postId: post.id)
        XCTAssertThrowsError(try service.confirmPublished(postId: post.id, url: "linkedin.com/x")) { error in
            XCTAssertEqual((error as? ValidationError)?.message, "La URL debe empezar con https://.")
        }
        let done = try service.confirmPublished(postId: post.id, url: " https://www.linkedin.com/feed/update/1 ")
        XCTAssertEqual(done.status, .published)
        XCTAssertEqual(done.publishedUrl, "https://www.linkedin.com/feed/update/1")
    }

    func testScheduledThenPublishedWithoutUrl() async throws {
        let post = try approved(.linkedin, media: [])
        _ = try await service.prepare(postId: post.id)
        XCTAssertEqual(try service.confirmScheduled(postId: post.id).status, .scheduled)
        let done = try service.confirmPublished(postId: post.id, url: "")
        XCTAssertEqual(done.status, .published)
        XCTAssertNil(done.publishedUrl)
    }

    func testCancelPreparationReturnsToApproved() async throws {
        let post = try approved(.linkedin, media: [])
        _ = try await service.prepare(postId: post.id)
        XCTAssertEqual(try service.cancelPreparation(postId: post.id).status, .approved)
    }
}
