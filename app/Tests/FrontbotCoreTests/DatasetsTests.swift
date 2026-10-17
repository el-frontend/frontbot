import XCTest
@testable import FrontbotCore

final class DatasetsTests: XCTestCase {
    struct FakeDownloader: DatasetDownloader {
        var sizes: [String: Int] = [:]
        var failing: Set<String> = []
        func download(_ url: URL, to file: URL, maxBytes: Int) async throws {
            if failing.contains(url.absoluteString) { throw ValidationError("boom") }
            try Data(repeating: 65, count: sizes[url.absoluteString] ?? 10).write(to: file)
        }
    }

    var root: URL!
    var paths: AppPaths!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ds-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        paths = AppPaths(root: root)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func make(_ d: FakeDownloader = FakeDownloader(), dataset: Int = 500_000_000, total: Int = 2_000_000_000) -> Datasets {
        Datasets(paths: paths, downloader: d, maxDatasetBytes: dataset, maxTotalBytes: total)
    }

    func testFetchWritesFilesAndMeta() async throws {
        let ds = make()
        let meta = try await ds.fetch(name: "btc-prices", urls: ["https://x.com/a/prices.csv", "https://y.com/b/prices.csv"],
                                      description: "d", agentId: "ag1")
        XCTAssertEqual(meta.files, ["prices.csv", "prices-2.csv"])
        XCTAssertEqual(meta.bytes, 20)
        XCTAssertEqual(meta.fetchedByAgentId, "ag1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.datasetDir("btc-prices").appendingPathComponent("prices-2.csv").path))
        XCTAssertEqual(try ds.list().map(\.name), ["btc-prices"])
        let contents = try FileManager.default.contentsOfDirectory(atPath: paths.datasetsDir.path)
        XCTAssertEqual(contents, ["btc-prices"])
    }

    func testRejectsExistingName() async throws {
        let ds = make()
        _ = try await ds.fetch(name: "one", urls: ["https://x.com/a.csv"], description: "", agentId: "a")
        do {
            _ = try await ds.fetch(name: "one", urls: ["https://x.com/a.csv"], description: "", agentId: "a")
            XCTFail("expected error")
        } catch let e as ValidationError {
            XCTAssertEqual(e.message, "Ya existe el dataset one: los datasets no se reescriben, usa otro nombre.")
        }
    }

    func testRejectsHttpUrl() async throws {
        do {
            _ = try await make().fetch(name: "one", urls: ["http://x.com/a.csv"], description: "", agentId: "a")
            XCTFail("expected error")
        } catch is ValidationError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.datasetDir("one").path))
    }

    func testRejectsBadNameAndUrlCount() async throws {
        let ds = make()
        do { _ = try await ds.fetch(name: "Bad Name", urls: ["https://x.com/a"], description: "", agentId: "a"); XCTFail() } catch is ValidationError {}
        do { _ = try await ds.fetch(name: "ok", urls: [], description: "", agentId: "a"); XCTFail() } catch is ValidationError {}
    }

    func testFailedDownloadLeavesNothing() async throws {
        let ds = make(FakeDownloader(failing: ["https://x.com/b.csv"]))
        do {
            _ = try await ds.fetch(name: "one", urls: ["https://x.com/a.csv", "https://x.com/b.csv"], description: "", agentId: "a")
            XCTFail("expected error")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.datasetDir("one").path))
        let left = (try? FileManager.default.contentsOfDirectory(atPath: paths.datasetsDir.path)) ?? []
        XCTAssertTrue(left.filter { $0.hasPrefix(".tmp-") }.isEmpty)
    }

    func testDatasetSizeLimit() async throws {
        let ds = make(FakeDownloader(sizes: ["https://x.com/a.csv": 60, "https://x.com/b.csv": 60]), dataset: 100)
        do {
            _ = try await ds.fetch(name: "one", urls: ["https://x.com/a.csv", "https://x.com/b.csv"], description: "", agentId: "a")
            XCTFail("expected error")
        } catch is ValidationError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.datasetDir("one").path))
    }

    func testTotalSizeLimit() async throws {
        let ds = make(FakeDownloader(sizes: ["https://x.com/a.csv": 80, "https://x.com/b.csv": 80]), dataset: 100, total: 120)
        _ = try await ds.fetch(name: "one", urls: ["https://x.com/a.csv"], description: "", agentId: "a")
        do {
            _ = try await ds.fetch(name: "two", urls: ["https://x.com/b.csv"], description: "", agentId: "a")
            XCTFail("expected error")
        } catch is ValidationError {}
        XCTAssertEqual(try ds.list().map(\.name), ["one"])
        let left = try FileManager.default.contentsOfDirectory(atPath: paths.datasetsDir.path)
        XCTAssertEqual(left, ["one"])
    }

    func testImportFolderCopiesAndDeletes() throws {
        let src = root.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try Data("hola".utf8).write(to: src.appendingPathComponent("a.txt"))
        let ds = make()
        let meta = try ds.importFolder(src, name: "mine", description: "d")
        XCTAssertEqual(meta.files, ["a.txt"])
        XCTAssertEqual(meta.bytes, 4)
        try ds.delete(name: "mine")
        XCTAssertTrue(try ds.list().isEmpty)
    }

    func testImportFolderRejectsSymlinks() throws {
        let src = root.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: src.appendingPathComponent("a.txt"))
        try FileManager.default.createSymbolicLink(at: src.appendingPathComponent("link"), withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        XCTAssertThrowsError(try make().importFolder(src, name: "mine", description: ""))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.datasetDir("mine").path))
    }
}
