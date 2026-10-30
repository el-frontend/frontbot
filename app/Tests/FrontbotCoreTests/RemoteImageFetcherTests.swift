import XCTest
@testable import FrontbotCore

final class RemoteImageFetcherTests: XCTestCase {
    /// Descargador falso: escribe `body` y recuerda qué URL le pidieron.
    final class FakeDownloader: DatasetDownloader, @unchecked Sendable {
        var body = Data()
        var requested: [URL] = []
        var maxBytes: Int?
        func download(_ url: URL, to file: URL, maxBytes: Int) async throws {
            requested.append(url)
            self.maxBytes = maxBytes
            try body.write(to: file)
        }
    }

    final class StubProtocol: URLProtocol {
        nonisolated(unsafe) static var chunks: [Data] = []
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for c in Self.chunks { client?.urlProtocol(self, didLoad: c) }
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    func realFetcher() -> RemoteImageFetcher {
        RemoteImageFetcher(downloader: URLSessionDatasetDownloader(protocolClasses: [StubProtocol.self], resolver: { _ in ["93.184.216.34"] }))
    }

    func testFetchReturnsBodyAndCapsAt8MB() async throws {
        let fake = FakeDownloader()
        fake.body = Data([1, 2, 3])
        let data = try await RemoteImageFetcher(downloader: fake).fetch("https://cdn.example.com/a.png")
        XCTAssertEqual(data, Data([1, 2, 3]))
        XCTAssertEqual(fake.maxBytes, AssetImporter.maxImageBytes)
    }

    func testUpgradesHttpToHttps() async throws {
        let fake = FakeDownloader()
        _ = try await RemoteImageFetcher(downloader: fake).fetch("http://cdn.example.com/a.png")
        XCTAssertEqual(fake.requested.first?.absoluteString, "https://cdn.example.com/a.png")
    }

    func testRejectsOtherSchemes() async {
        for u in ["ftp://a.com/x.png", "file:///etc/passwd", "no es url"] {
            do { _ = try await RemoteImageFetcher(downloader: FakeDownloader()).fetch(u); XCTFail(u) } catch is ValidationError {} catch { XCTFail("\(error)") }
        }
    }

    func testRejectsLocalHosts() async {
        for u in ["https://localhost/x.png", "https://printer.local/x.png", "https://10.0.0.1/x.png", "https://[::1]/x.png"] {
            do { _ = try await realFetcher().fetch(u); XCTFail(u) } catch is ValidationError {} catch { XCTFail("\(error)") }
        }
    }

    func testCutsOffOver8MBWithoutContentLength() async {
        StubProtocol.chunks = [Data(count: AssetImporter.maxImageBytes), Data(count: 1)]
        do { _ = try await realFetcher().fetch("https://cdn.example.com/big.png"); XCTFail("expected error") } catch is ValidationError {} catch { XCTFail("\(error)") }
    }

    func testRealDownloadReturnsBytes() async throws {
        StubProtocol.chunks = [Data([0x89, 0x50]), Data([0x4E, 0x47])]
        let data = try await realFetcher().fetch("https://cdn.example.com/a.png")
        XCTAssertEqual(data, Data([0x89, 0x50, 0x4E, 0x47]))
    }
}
