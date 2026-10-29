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

    func testOpenAIKeyIsScopedToWorkspaceAndNormalizesWhitespace() throws {
        let store = CredentialStore(service: "app.frontbot.tests.\(UUID().uuidString)")
        let firstWorkspace = UUID().uuidString
        let secondWorkspace = UUID().uuidString

        XCTAssertNil(try store.openAIKey(workspaceId: firstWorkspace))
        XCTAssertFalse(try store.hasOpenAIKey(workspaceId: firstWorkspace))
        try store.setOpenAIKey("  sk-openai-secret\n", workspaceId: firstWorkspace)

        XCTAssertEqual(try store.openAIKey(workspaceId: firstWorkspace), "sk-openai-secret")
        XCTAssertTrue(try store.hasOpenAIKey(workspaceId: firstWorkspace))
        XCTAssertNil(try store.openAIKey(workspaceId: secondWorkspace))
        XCTAssertFalse(try store.hasOpenAIKey(workspaceId: secondWorkspace))
        try store.deleteOpenAIKey(workspaceId: firstWorkspace)
        XCTAssertNil(try store.openAIKey(workspaceId: firstWorkspace))
        XCTAssertFalse(try store.hasOpenAIKey(workspaceId: firstWorkspace))
    }

    func testOpenAIKeyRejectsWhitespaceOnlyValue() throws {
        let store = CredentialStore(service: "app.frontbot.tests.\(UUID().uuidString)")

        XCTAssertThrowsError(try store.setOpenAIKey(" \n\t ", workspaceId: UUID().uuidString))
    }
}
