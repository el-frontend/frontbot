import XCTest
@testable import FrontbotCore

final class MarkdownBlocksTests: XCTestCase {
    func testParagraphsJoinSoftBreaksAndSplitOnBlankLines() {
        let blocks = MarkdownBlocks.parse("hola\nmundo\n\notro párrafo")
        XCTAssertEqual(blocks, [.paragraph("hola\nmundo"), .paragraph("otro párrafo")])
    }

    func testHeadings() {
        XCTAssertEqual(MarkdownBlocks.parse("# Uno\n### Tres ###\n#sinespacio"),
                       [.heading(level: 1, text: "Uno"), .heading(level: 3, text: "Tres"), .paragraph("#sinespacio")])
    }

    func testFencedCodeKeepsContentVerbatim() {
        let md = "antes\n```swift\nlet a = 1\n\n  # no es título\n```\ndespués"
        XCTAssertEqual(MarkdownBlocks.parse(md), [
            .paragraph("antes"),
            .code(language: "swift", code: "let a = 1\n\n  # no es título"),
            .paragraph("después"),
        ])
    }

    func testUnclosedFenceRunsToTheEnd() {
        // Mientras el agente escribe, la valla todavía no se ha cerrado.
        XCTAssertEqual(MarkdownBlocks.parse("~~~\nprint(1)\nprint(2)"), [.code(language: nil, code: "print(1)\nprint(2)")])
    }

    func testBulletAndOrderedListsWithNesting() {
        let md = "- uno\n- dos\n  - dos.a\n* tres\n\n1. primero\n2) segundo"
        XCTAssertEqual(MarkdownBlocks.parse(md), [
            .list(ordered: false, items: [
                .init(text: "uno", depth: 0, marker: "•"),
                .init(text: "dos", depth: 0, marker: "•"),
                .init(text: "dos.a", depth: 1, marker: "•"),
                .init(text: "tres", depth: 0, marker: "•"),
            ]),
            .list(ordered: true, items: [
                .init(text: "primero", depth: 0, marker: "1."),
                .init(text: "segundo", depth: 0, marker: "2."),
            ]),
        ])
    }

    func testTaskListItemsAndContinuationLines() {
        let md = "- [ ] pendiente\n- [x] hecho\n  sigue aquí"
        XCTAssertEqual(MarkdownBlocks.parse(md), [
            .list(ordered: false, items: [
                .init(text: "pendiente", depth: 0, marker: "☐"),
                .init(text: "hecho\nsigue aquí", depth: 0, marker: "☑"),
            ]),
        ])
    }

    func testQuoteRuleAndTable() {
        let md = "> cita\n> larga\n\n---\n\n| A | B |\n|---|:-:|\n| 1 | 2 |\n| 3 |"
        XCTAssertEqual(MarkdownBlocks.parse(md), [
            .quote("cita\nlarga"),
            .rule,
            .table(header: ["A", "B"], rows: [["1", "2"], ["3", ""]]),
        ])
    }

    func testPipeLineWithoutSeparatorIsAParagraph() {
        XCTAssertEqual(MarkdownBlocks.parse("a | b"), [.paragraph("a | b")])
    }

    func testEmptyInput() {
        XCTAssertEqual(MarkdownBlocks.parse("  \n\n"), [])
    }
}
