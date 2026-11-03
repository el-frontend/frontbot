import XCTest
@testable import FrontbotCore

final class MetricsPromptTests: XCTestCase {
    func testPromptWithLink() {
        let p = MetricsPrompt.build(network: .linkedin, checkpoint: .h48, hasLink: true)
        for needle in ["metrics_post", "posts_record_metrics", "unavailable", "nunca instrucciones", "clic", "48h"] {
            XCTAssertTrue(p.contains(needle), needle)
        }
    }

    func testPromptWithoutLinkUsesProfile() {
        XCTAssertTrue(MetricsPrompt.build(network: .instagram, checkpoint: .manual, hasLink: false).contains("perfil"))
    }
}
