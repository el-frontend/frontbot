import XCTest
@testable import FrontbotCore

final class CodexStatusTests: XCTestCase {
    func testParsesStatusJSON() {
        let json: JSONValue = ["installed": true, "compatible": true, "version": "0.158.0",
                               "account": ["email": "a@b.c", "plan": "pro"], "models": ["gpt-6-astra", "gpt-6-sol"]]
        let s = CodexStatus(json: json)
        XCTAssertEqual(s, CodexStatus(installed: true, compatible: true, version: "0.158.0", email: "a@b.c", plan: "pro", models: ["gpt-6-astra", "gpt-6-sol"]))
        XCTAssertTrue(s.connected)
    }

    func testConnectedNeedsCompatibleAccount() {
        XCTAssertFalse(CodexStatus(json: ["installed": true, "compatible": false, "version": "0.150.0", "account": ["email": "a@b.c", "plan": "pro"], "models": []]).connected)
        XCTAssertFalse(CodexStatus(json: ["installed": true, "compatible": true, "version": "0.158.0", "account": .null, "models": []]).connected)
        XCTAssertFalse(CodexStatus.unknown.connected)
    }
}
