import XCTest
@testable import FrontbotCore

final class BrandLinksTests: XCTestCase {
    func testAddsHttpsAndTrims() {
        XCTAssertEqual(BrandLinks.parse("  www.cafesol.com \nHTTPS://instagram.com/cafesol").links,
                       ["https://www.cafesol.com", "https://instagram.com/cafesol"])
    }

    func testCommaAndSpaceSeparated() {
        XCTAssertEqual(BrandLinks.parse("a.com, b.com c.com").links, ["https://a.com", "https://b.com", "https://c.com"])
    }

    func testRejectsOtherSchemesAndHostless() {
        let r = BrandLinks.parse("ftp://a.com\nfile:///etc/passwd\nhttps://\nhola")
        XCTAssertEqual(r.links, [])
        XCTAssertEqual(r.invalid.count, 4)
    }

    func testDeduplicates() {
        XCTAssertEqual(BrandLinks.parse("a.com\nhttps://a.com").links, ["https://a.com"])
    }

    func testMoreThanTenIsInvalid() {
        let text = (1...11).map { "s\($0).com" }.joined(separator: "\n")
        let r = BrandLinks.parse(text)
        XCTAssertEqual(r.links.count, 10)
        XCTAssertEqual(r.invalid, ["s11.com"])
    }

    func testKeepsPathAndQuery() {
        XCTAssertEqual(BrandLinks.parse("linktr.ee/cafesol?utm=1").links, ["https://linktr.ee/cafesol?utm=1"])
    }
}
