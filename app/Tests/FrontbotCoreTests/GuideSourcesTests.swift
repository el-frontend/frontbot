import XCTest
import AppKit
@testable import FrontbotCore

final class GuideSourcesTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    /// PDF de una página con texto real, dibujado con AppKit.
    func makePDF(text: String?) throws -> URL {
        let url = tmp.appendingPathComponent("\(UUID().uuidString).pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
        ctx.beginPDFPage(nil)
        if let text {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            (text as NSString).draw(at: CGPoint(x: 72, y: 700), withAttributes: [.font: NSFont.systemFont(ofSize: 14)])
            NSGraphicsContext.restoreGraphicsState()
        }
        ctx.endPDFPage()
        ctx.closePDF()
        return url
    }

    func testExtractsTextFromPDF() throws {
        let url = try makePDF(text: "Tono cercano y cálido")
        XCTAssertTrue(try GuideSources.text(fromPDF: url).contains("Tono cercano y cálido"))
    }

    func testPDFWithoutTextFails() throws {
        let url = try makePDF(text: nil)
        XCTAssertThrowsError(try GuideSources.text(fromPDF: url)) { error in
            XCTAssertEqual((error as? ValidationError)?.message, "Este PDF no tiene texto seleccionable.")
        }
    }

    func testNonPDFFails() throws {
        let url = tmp.appendingPathComponent("x.pdf")
        try Data("hola".utf8).write(to: url)
        XCTAssertThrowsError(try GuideSources.text(fromPDF: url)) { error in
            XCTAssertEqual((error as? ValidationError)?.message, "No se pudo abrir el PDF.")
        }
    }

    func testPromptsMentionToolAndSections() {
        for p in [GuideSources.interviewPrompt(brandName: "Café Sol"), GuideSources.pdfPrompt(brandName: "Café Sol", pdfText: "x")] {
            XCTAssertTrue(p.contains("Café Sol"))
            XCTAssertTrue(p.contains("brands_write_guide"))
            for section in ["Tono de voz", "Público", "Pilares de contenido", "Palabras sí / palabras no", "Ejemplos"] {
                XCTAssertTrue(p.contains(section), section)
            }
        }
        XCTAssertTrue(GuideSources.interviewPrompt(brandName: "X").contains("una pregunta a la vez"))
    }

    func testPdfPromptTruncatesLongText() {
        let long = String(repeating: "a", count: GuideSources.maxPDFCharacters + 10)
        let p = GuideSources.pdfPrompt(brandName: "X", pdfText: long)
        XCTAssertTrue(p.contains("[texto recortado]"))
        XCTAssertFalse(p.contains(long))
    }
}
