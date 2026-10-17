import XCTest
@testable import FrontbotCore

final class LineDiffTests: XCTestCase {
    func testDiffMarksAddedRemovedSame() {
        XCTAssertEqual(LineDiff.diff(old: "a\nb\nc", new: "a\nx\nc"),
                       [.same("a"), .removed("b"), .added("x"), .same("c")])
    }

    func testEmptyOld() {
        XCTAssertEqual(LineDiff.diff(old: "", new: "a\nb"), [.added("a"), .added("b")])
        XCTAssertEqual(LineDiff.diff(old: "a", new: ""), [.removed("a")])
        XCTAssertEqual(LineDiff.diff(old: "", new: ""), [])
    }
}
