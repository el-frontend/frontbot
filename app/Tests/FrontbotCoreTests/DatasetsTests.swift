import XCTest
@testable import FrontbotCore

final class DatasetsTests: XCTestCase {
    final class Budgets: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Int] = []
        func add(_ v: Int) { lock.lock(); values.append(v); lock.unlock() }
        var all: [Int] { lock.lock(); defer { lock.unlock() }; return values }
    }

    struct FakeDownloader: DatasetDownloader {
        var sizes: [String: Int] = [:]
        var failing: Set<String> = []
        var budgets = Budgets()
        func download(_ url: URL, to file: URL, maxBytes: Int) async throws {
            budgets.add(maxBytes)
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

    func testDownloaderReceivesRemainingBudget() async throws {
        let fake = FakeDownloader(sizes: ["https://x.com/a.csv": 30, "https://x.com/b.csv": 20, "https://x.com/c.csv": 10])
        let ds = make(fake, dataset: 100, total: 150)
        _ = try await ds.fetch(name: "one", urls: ["https://x.com/a.csv", "https://x.com/b.csv"], description: "", agentId: "a")
        // used = 0 -> min(100-0, 150-0), min(100-30, 150-30)
        XCTAssertEqual(fake.budgets.all, [100, 70])
        let fake2 = FakeDownloader(sizes: ["https://x.com/c.csv": 10], budgets: Budgets())
        _ = try await make(fake2, dataset: 100, total: 150).fetch(name: "two", urls: ["https://x.com/c.csv"], description: "", agentId: "a")
        // used = 50 -> min(100, 150-50)
        XCTAssertEqual(fake2.budgets.all, [100])
    }

    func testRejectsWhenExistingDatasetsFillTotal() async throws {
        let fake = FakeDownloader(sizes: ["https://x.com/a.csv": 50])
        _ = try await make(fake, dataset: 100, total: 50).fetch(name: "one", urls: ["https://x.com/a.csv"], description: "", agentId: "a")
        let fake2 = FakeDownloader()
        do {
            _ = try await make(fake2, dataset: 100, total: 50).fetch(name: "two", urls: ["https://x.com/b.csv"], description: "", agentId: "a")
            XCTFail("expected error")
        } catch let e as ValidationError {
            XCTAssertTrue(e.message.contains("ya ocupan el máximo"))
        }
        XCTAssertTrue(fake2.budgets.all.isEmpty)
    }

    func testRejectsLocalHosts() async throws {
        let hosts = ["localhost", "foo.local", "127.0.0.1", "10.1.2.3", "172.16.0.1", "172.31.255.255", "192.168.1.1",
                     "169.254.169.254", "0.0.0.0", "[::1]", "[fc00::1]", "[fd12::1]", "[fe80::1]", "[::ffff:10.0.0.1]"]
        for host in hosts {
            let fake = FakeDownloader()
            do {
                _ = try await make(fake).fetch(name: "one", urls: ["https://\(host)/a.csv"], description: "", agentId: "a")
                XCTFail("expected error for \(host)")
            } catch let e as ValidationError {
                XCTAssertTrue(e.message.hasPrefix("Solo se descargan datos públicos"), host)
            }
            XCTAssertTrue(fake.budgets.all.isEmpty)
        }
        XCTAssertFalse(PublicHost.isLocalLiteral("8.8.8.8"))
        XCTAssertFalse(PublicHost.isLocalLiteral("172.32.0.1"))
        XCTAssertFalse(PublicHost.isLocalLiteral("example.com"))
    }

    // MARK: - Real downloader with a stubbed URLProtocol (no network)

    final class StubProtocol: URLProtocol {
        nonisolated(unsafe) static var handler: ((URLRequest) -> (HTTPURLResponse, [Data]))?
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            guard let (response, chunks) = Self.handler?(request) else { return }
            if (300..<400).contains(response.statusCode), let loc = response.value(forHTTPHeaderField: "Location"), let url = URL(string: loc) {
                client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: url), redirectResponse: response)
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for c in chunks { client?.urlProtocol(self, didLoad: c) }
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    func realDownloader() -> URLSessionDatasetDownloader {
        URLSessionDatasetDownloader(protocolClasses: [StubProtocol.self], resolver: { _ in ["93.184.216.34"] })
    }

    func response(_ url: URL, _ status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    }

    func testRealDownloaderWritesChunks() async throws {
        StubProtocol.handler = { req in (self.response(req.url!, 200), [Data(repeating: 1, count: 6), Data(repeating: 2, count: 4)]) }
        let file = root.appendingPathComponent("out.bin")
        try await realDownloader().download(URL(string: "https://example.com/a.bin")!, to: file, maxBytes: 100)
        XCTAssertEqual(try Data(contentsOf: file).count, 10)
    }

    func testRealDownloaderRequiresStatus200() async throws {
        StubProtocol.handler = { req in (self.response(req.url!, 404), []) }
        do {
            try await realDownloader().download(URL(string: "https://example.com/a.bin")!, to: root.appendingPathComponent("o"), maxBytes: 100)
            XCTFail("expected error")
        } catch let e as ValidationError { XCTAssertTrue(e.message.contains("200")) }
    }

    func testRealDownloaderAbortsPastMaxBytes() async throws {
        StubProtocol.handler = { req in (self.response(req.url!, 200), [Data(repeating: 1, count: 8), Data(repeating: 1, count: 8)]) }
        do {
            try await realDownloader().download(URL(string: "https://example.com/a.bin")!, to: root.appendingPathComponent("o"), maxBytes: 10)
            XCTFail("expected error")
        } catch let e as ValidationError { XCTAssertTrue(e.message.contains("límite")) }
    }

    func testRealDownloaderRejectsContentLengthOverLimit() async throws {
        StubProtocol.handler = { req in (self.response(req.url!, 200, headers: ["Content-Length": "500"]), [Data(count: 5)]) }
        do {
            try await realDownloader().download(URL(string: "https://example.com/a.bin")!, to: root.appendingPathComponent("o"), maxBytes: 10)
            XCTFail("expected error")
        } catch is ValidationError {}
    }

    func testRealDownloaderRejectsHttpAndLocalRedirects() async throws {
        for target in ["http://example.com/b.bin", "https://192.168.0.5/b.bin"] {
            StubProtocol.handler = { req in
                if req.url!.path == "/a.bin" { return (self.response(req.url!, 302, headers: ["Location": target]), []) }
                return (self.response(req.url!, 200), [Data(count: 5)])
            }
            do {
                try await realDownloader().download(URL(string: "https://example.com/a.bin")!, to: root.appendingPathComponent("o"), maxBytes: 100)
                XCTFail("expected error for \(target)")
            } catch {}
        }
    }

    func testRealDownloaderRejectsHostResolvingToPrivateAddress() async throws {
        StubProtocol.handler = { req in (self.response(req.url!, 200), [Data(count: 5)]) }
        let d = URLSessionDatasetDownloader(protocolClasses: [StubProtocol.self], resolver: { _ in ["10.0.0.7"] })
        do {
            try await d.download(URL(string: "https://sneaky.example.com/a.bin")!, to: root.appendingPathComponent("o"), maxBytes: 100)
            XCTFail("expected error")
        } catch let e as ValidationError { XCTAssertTrue(e.message.hasPrefix("Solo se descargan datos públicos")) }
    }
}
