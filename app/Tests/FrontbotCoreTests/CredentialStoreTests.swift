import XCTest
@testable import FrontbotCore

final class CredentialStoreTests: XCTestCase {
    func testSetGetDelete() throws {
        let store = CredentialStore(service: "app.frontbot.tests.\(UUID().uuidString)")
        XCTAssertNil(try store.get("k"))
        try store.set("k", value: "sk-ant-123")
        XCTAssertEqual(try store.get("k"), "sk-ant-123")
        try store.set("k", value: "sk-ant-456")
        XCTAssertEqual(try store.get("k"), "sk-ant-456")
        try store.delete("k")
        XCTAssertNil(try store.get("k"))
    }
}
