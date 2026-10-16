import XCTest
@testable import FrontbotCore

final class FakeHandoff: PublicationHandoff, @unchecked Sendable {
    var calls: [(URL, String, [String])] = []
    var error: Error?

    func handOff(url: URL, body: String, mediaPaths: [String]) throws {
        if let error { throw error }
        calls.append((url, body, mediaPaths))
    }
}

final class PublishingLinksTests: XCTestCase {
    func testLinkedInComposerCarriesTheEncodedText() throws {
        let url = PublishingLinks.composeURL(network: .linkedin, body: "Hola & adiós #marca\nlínea 2")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(url.host(), "www.linkedin.com")
        XCTAssertEqual(items?.first { $0.name == "shareActive" }?.value, "true")
        XCTAssertEqual(items?.first { $0.name == "text" }?.value, "Hola & adiós #marca\nlínea 2")
        XCTAssertFalse(url.absoluteString.contains("#"), "un # sin codificar cortaría la URL")
    }

    func testInstagramOpensTheHome() {
        XCTAssertEqual(PublishingLinks.composeURL(network: .instagram, body: "x").absoluteString, "https://www.instagram.com/")
        XCTAssertEqual(PublishingLinks.homeURL(.linkedin).absoluteString, "https://www.linkedin.com/feed/")
    }
}

final class PublishingServiceTests: XCTestCase {
    var db: AppDatabase!
    var brand: Brand!
    var image: BrandAsset!
    var root: URL!
    var handoff: FakeHandoff!
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
        handoff = FakeHandoff()
        service = PublishingService(db: db, handoff: handoff)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func approved(_ network: Network, media: [String]) throws -> Post {
        let p = try db.createDraft(brandId: brand.id, network: network, body: "hola", media: media, scheduledFor: nil)
        return try db.transitionPost(id: p.id, to: .approved, actor: .user)
    }

    func testPrepareHandsOffToTheBrowserAndMovesToPreparing() throws {
        let post = try approved(.instagram, media: [image.id])
        let (updated, result) = try service.prepare(postId: post.id)
        XCTAssertEqual(updated.status, .preparing)
        XCTAssertEqual(handoff.calls.first?.0.absoluteString, "https://www.instagram.com/")
        XCTAssertEqual(handoff.calls.first?.1, "hola")
        XCTAssertEqual(handoff.calls.first?.2, [image.path])
        XCTAssertTrue(result.message.contains("portapapeles"))
    }

    func testRejectsDraftAndInstagramWithoutImages() throws {
        let draft = try db.createDraft(brandId: brand.id, network: .linkedin, body: "hola", media: [], scheduledFor: nil)
        do { _ = try service.prepare(postId: draft.id); XCTFail() } catch let e as ValidationError {
            XCTAssertEqual(e.message, "Solo se pueden preparar posts aprobados.")
        }
        let ig = try approved(.instagram, media: [])
        do { _ = try service.prepare(postId: ig.id); XCTFail() } catch let e as ValidationError {
            XCTAssertEqual(e.message, "Instagram necesita al menos una imagen.")
        }
        XCTAssertTrue(handoff.calls.isEmpty)
    }

    func testHandoffFailureKeepsThePostApproved() throws {
        handoff.error = ValidationError("No se pudo abrir el navegador")
        let post = try approved(.linkedin, media: [])
        XCTAssertThrowsError(try service.prepare(postId: post.id))
        XCTAssertEqual(try db.posts(brandId: brand.id, status: nil).first { $0.id == post.id }?.status, .approved)
    }

    func testConfirmPublishedWithUrlAndValidation() throws {
        let post = try approved(.linkedin, media: [])
        _ = try service.prepare(postId: post.id)
        XCTAssertThrowsError(try service.confirmPublished(postId: post.id, url: "linkedin.com/x")) { error in
            XCTAssertEqual((error as? ValidationError)?.message, "La URL debe empezar con https://.")
        }
        let done = try service.confirmPublished(postId: post.id, url: " https://www.linkedin.com/feed/update/1 ")
        XCTAssertEqual(done.status, .published)
        XCTAssertEqual(done.publishedUrl, "https://www.linkedin.com/feed/update/1")
    }

    func testScheduledThenPublishedWithoutUrl() throws {
        let post = try approved(.linkedin, media: [])
        _ = try service.prepare(postId: post.id)
        XCTAssertEqual(try service.confirmScheduled(postId: post.id).status, .scheduled)
        let done = try service.confirmPublished(postId: post.id, url: "")
        XCTAssertEqual(done.status, .published)
        XCTAssertNil(done.publishedUrl)
    }

    func testCancelPreparationReturnsToApproved() throws {
        let post = try approved(.linkedin, media: [])
        _ = try service.prepare(postId: post.id)
        XCTAssertEqual(try service.cancelPreparation(postId: post.id).status, .approved)
    }
}
