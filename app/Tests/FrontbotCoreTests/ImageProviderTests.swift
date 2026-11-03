import XCTest
@testable import FrontbotCore

final class ImageProviderTests: XCTestCase {
    static let png1x1 = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!

    actor Box { var request: URLRequest?; func set(_ r: URLRequest) { request = r } }

    func provider(status: Int, body: String, box: Box = Box()) -> OpenAIImageProvider {
        OpenAIImageProvider(apiKey: "sk-test") { request in
            await box.set(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        }
    }

    func testRequestShape() async throws {
        let box = Box()
        let ok = #"{"data":[{"b64_json":"\#(Self.png1x1.base64EncodedString())"}]}"#
        _ = try await provider(status: 200, body: ok, box: box).generate(prompt: "a cup", size: .ai)
        let captured = await box.request
        let request = try XCTUnwrap(captured)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/images/generations")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        XCTAssertGreaterThanOrEqual(request.timeoutInterval, 120)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "gpt-image-1")
        XCTAssertEqual(json["prompt"] as? String, "a cup")
        XCTAssertEqual(json["size"] as? String, "1024x1536")
        XCTAssertEqual(json["n"] as? Int, 1)
    }

    func testDecodesBase64() async throws {
        let ok = #"{"data":[{"b64_json":"\#(Self.png1x1.base64EncodedString())"}]}"#
        let data = try await provider(status: 200, body: ok).generate(prompt: "x", size: .ai)
        XCTAssertEqual(data, Self.png1x1)
    }

    func testSurfacesOpenAIError() async throws {
        do {
            _ = try await provider(status: 401, body: #"{"error":{"message":"Incorrect API key"}}"#).generate(prompt: "x", size: .ai)
            XCTFail("debería fallar")
        } catch let error as ValidationError {
            XCTAssertTrue(error.message.contains("Incorrect API key"), error.message)
        }
    }

    func testMissingImageThrows() async throws {
        do {
            _ = try await provider(status: 200, body: #"{"data":[]}"#).generate(prompt: "x", size: .ai)
            XCTFail("debería fallar")
        } catch is ValidationError {}
    }
}
