import XCTest
@testable import FrontbotCore

final class PostMetadataTests: XCTestCase {
    var root: URL!
    var store: PostMetadataStore!
    var paths: AppPaths!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        paths = AppPaths(root: root)
        store = PostMetadataStore(paths: paths)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    func reading(_ c: MetricsCheckpoint, likes: Int?) -> MetricsReading {
        MetricsReading(checkpoint: c, readAt: Date(timeIntervalSince1970: 1_800_000_000), reach: nil, views: 100, likes: likes,
                       reposts: 2, sourceUrl: "https://www.linkedin.com/feed/update/x", note: nil)
    }

    func writeRaw(_ text: String) throws {
        let url = paths.postMetadata("p1")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func testMissingFileIsEmpty() {
        XCTAssertEqual(store.read(postId: "p1"), PostMetadata(publishedAt: nil, metrics: [], skipped: []))
    }

    func testRoundTrip() throws {
        let published = Date(timeIntervalSince1970: 1_799_900_000)
        try store.setPublishedAt(postId: "p1", published)
        try store.record(postId: "p1", reading(.h24, likes: 3))
        try store.record(postId: "p1", reading(.manual, likes: 5))
        try store.skip(postId: "p1", [.h48])
        let meta = store.read(postId: "p1")
        XCTAssertEqual(meta.publishedAt, published)
        XCTAssertEqual(meta.metrics, [reading(.h24, likes: 3), reading(.manual, likes: 5)])
        XCTAssertEqual(meta.skipped, [.h48])
    }

    func testFileIsSnakeCaseJSON() throws {
        try store.setPublishedAt(postId: "p1", Date(timeIntervalSince1970: 1_799_900_000))
        try store.record(postId: "p1", reading(.h24, likes: 3))
        try store.skip(postId: "p1", [.h48])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: paths.postMetadata("p1"))) as? [String: Any])
        XCTAssertNotNil(json["published_at"] as? String)
        XCTAssertEqual(json["skipped"] as? [String], ["48h"])
        let first = try XCTUnwrap((json["metrics"] as? [[String: Any]])?.first)
        XCTAssertEqual(first["checkpoint"] as? String, "24h")
        XCTAssertNotNil(first["read_at"] as? String)
        XCTAssertEqual(first["source_url"] as? String, "https://www.linkedin.com/feed/update/x")
        XCTAssertTrue(first["reach"] is NSNull)
        XCTAssertTrue(first["note"] is NSNull)
    }

    func testUnknownKeysPreserved() throws {
        try writeRaw(#"{"foo":{"bar":1},"metrics":[]}"#)
        try store.record(postId: "p1", reading(.h24, likes: 3))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: paths.postMetadata("p1"))) as? [String: Any])
        XCTAssertEqual((json["foo"] as? [String: Any])?["bar"] as? Int, 1)
        XCTAssertEqual(store.read(postId: "p1").metrics.count, 1)
    }

    func testCorruptFileReadsEmptyAndIsNotOverwritten() throws {
        try writeRaw("{no json")
        XCTAssertEqual(store.read(postId: "p1").metrics, [])
        XCTAssertThrowsError(try store.record(postId: "p1", reading(.h24, likes: 1))) { XCTAssertTrue($0 is ValidationError) }
        XCTAssertEqual(try String(contentsOf: paths.postMetadata("p1"), encoding: .utf8), "{no json")
    }
}
