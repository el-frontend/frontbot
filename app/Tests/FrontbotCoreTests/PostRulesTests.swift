import XCTest
@testable import FrontbotCore

final class PostRulesTests: XCTestCase {
    func testInstagramAcceptsExactly2200Characters() throws {
        try PostRules.validate(body: String(repeating: "a", count: 2200), network: .instagram)
    }

    func testInstagramRejects2201Characters() {
        XCTAssertThrowsError(try PostRules.validate(body: String(repeating: "a", count: 2201), network: .instagram)) { error in
            XCTAssertEqual((error as? ValidationError)?.message, "El texto de instagram tiene 2201 caracteres; el máximo es 2200.")
        }
    }

    func testEmojisCountAsVisibleCharacters() throws {
        // 2200 emojis con modificador de tono: muchos más bytes/UTF-16, pero 2200 caracteres visibles.
        try PostRules.validate(body: String(repeating: "👍🏽", count: 2200), network: .instagram)
    }

    func testInstagramRejects31Hashtags() {
        let body = (1...31).map { "#tag\($0)" }.joined(separator: " ")
        XCTAssertThrowsError(try PostRules.validate(body: body, network: .instagram)) { error in
            XCTAssertEqual((error as? ValidationError)?.message, "Instagram admite máximo 30 hashtags; el texto tiene 31.")
        }
    }

    func testInstagramAccepts30HashtagsWithAccents() throws {
        let body = (1...30).map { "#canción\($0)" }.joined(separator: " ")
        try PostRules.validate(body: body, network: .instagram)
    }

    func testLinkedInLimitIs3000() throws {
        try PostRules.validate(body: String(repeating: "é", count: 3000), network: .linkedin)
        XCTAssertThrowsError(try PostRules.validate(body: String(repeating: "é", count: 3001), network: .linkedin))
    }

    func testEmptyBodyIsRejected() {
        XCTAssertThrowsError(try PostRules.validate(body: "   \n", network: .linkedin)) { error in
            XCTAssertEqual((error as? ValidationError)?.message, "El texto del post está vacío.")
        }
    }
}
