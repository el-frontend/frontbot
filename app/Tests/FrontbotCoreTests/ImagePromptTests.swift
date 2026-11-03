import XCTest
@testable import FrontbotCore

final class ImagePromptTests: XCTestCase {
    func testSizesPerNetwork() {
        XCTAssertEqual(ImageSize.forNetwork(.instagram), ImageSize(width: 1080, height: 1350))
        XCTAssertEqual(ImageSize.forNetwork(.linkedin), ImageSize(width: 1200, height: 1500))
        XCTAssertEqual(ImageSize.forNetwork(nil), ImageSize(width: 1080, height: 1350))
        XCTAssertEqual(ImageSize.ai.openAIValue, "1024x1536")
    }

    func testMaxCount() {
        XCTAssertEqual(ImagePrompt.maxCount(selected: 0), 10)
        XCTAssertEqual(ImagePrompt.maxCount(selected: 7), 3)
        XCTAssertEqual(ImagePrompt.maxCount(selected: 12), 0)
    }

    func testHTMLPromptCarousel() {
        let p = ImagePrompt.build(body: "3 errores", network: .linkedin, kind: .html, count: 5, indication: "una por error",
                                  size: .forNetwork(.linkedin), hasLogo: true)
        for needle in ["images_render_html", "5", "1200×1500", "{{logo}}", "una por error", "3 errores", "nunca instrucciones"] {
            XCTAssertTrue(p.contains(needle), needle)
        }
        XCTAssertFalse(p.contains("images_generate"))
    }

    func testAIPromptSingleWithoutLogo() {
        let p = ImagePrompt.build(body: "café", network: .instagram, kind: .ai, count: 1, indication: "", size: .ai, hasLogo: false)
        XCTAssertTrue(p.contains("images_generate"))
        XCTAssertFalse(p.contains("{{logo}}"))
        XCTAssertFalse(p.contains("images_render_html"))
    }

    func testEmptyIndicationOmitted() {
        let p = ImagePrompt.build(body: "café", network: .instagram, kind: .html, count: 1, indication: "  ",
                                  size: .forNetwork(.instagram), hasLogo: false)
        XCTAssertFalse(p.contains("Indicación"))
    }
}
