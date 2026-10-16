import XCTest
@testable import FrontbotCore

final class NotchGeometryTests: XCTestCase {
    func testMeasuresNotchFromAuxiliaryAreas() {
        let g = NotchGeometry(screenWidth: 1512, safeAreaTop: 38, auxiliaryLeftWidth: 664, auxiliaryRightWidth: 664, menuBarHeight: 38)
        XCTAssertTrue(g.hasNotch)
        XCTAssertEqual(g.width, 184)
        XCTAssertEqual(g.height, 38)
    }

    func testNoNotchFallback() {
        let g = NotchGeometry(screenWidth: 2560, safeAreaTop: 0, auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil, menuBarHeight: 25)
        XCTAssertFalse(g.hasNotch)
        XCTAssertEqual(g.width, 80)
        XCTAssertEqual(g.height, 24)
    }

    func testBogusAuxiliaryWidthsFallBack() {
        let g = NotchGeometry(screenWidth: 1512, safeAreaTop: 38, auxiliaryLeftWidth: 900, auxiliaryRightWidth: 900, menuBarHeight: 38)
        XCTAssertEqual(g.width, NotchGeometry.fallbackNotchWidth)
    }

    func testPanelFramesAreTopCenteredOnTheGivenScreen() {
        let g = NotchGeometry(screenWidth: 1512, safeAreaTop: 38, auxiliaryLeftWidth: 664, auxiliaryRightWidth: 664, menuBarHeight: 38)
        // Pantalla secundaria a la derecha de la principal.
        let screen = CGRect(x: 1512, y: 0, width: 1512, height: 982)
        XCTAssertEqual(g.panelFrame(in: screen, expanded: false), CGRect(x: 1512 + 756 - 152, y: 982 - 38, width: 304, height: 38))
        XCTAssertEqual(g.panelFrame(in: screen, expanded: true), CGRect(x: 1512 + 756 - 260, y: 982 - 400, width: 520, height: 400))
    }

    func testExpandedPanelNeverWiderThanScreen() {
        let g = NotchGeometry(screenWidth: 400, safeAreaTop: 0, auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil, menuBarHeight: 24)
        let f = g.panelFrame(in: CGRect(x: 0, y: 0, width: 400, height: 300), expanded: true)
        XCTAssertEqual(f.width, 400)
        XCTAssertEqual(f.minX, 0)
        XCTAssertEqual(f.height, 300)
    }
}
