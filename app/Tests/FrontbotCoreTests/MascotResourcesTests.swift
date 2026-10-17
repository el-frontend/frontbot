import XCTest
@testable import FrontbotCore

final class MascotResourcesTests: XCTestCase {
    func testPrefersTheAppBundleThenTheSourceTree() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bundled = base.appendingPathComponent("Bundle/Mascot"), source = base.appendingPathComponent("Source/Mascot")
        try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try Data("s".utf8).write(to: source.appendingPathComponent("logo.png"))
        XCTAssertEqual(MascotResources.locate("logo.png", candidates: [bundled, source])?.path, source.appendingPathComponent("logo.png").path)
        try Data("b".utf8).write(to: bundled.appendingPathComponent("logo.png"))
        XCTAssertEqual(MascotResources.locate("logo.png", candidates: [bundled, source])?.path, bundled.appendingPathComponent("logo.png").path)
        XCTAssertNil(MascotResources.locate("frontbot.usdz", candidates: [bundled, source]), "sin el archivo, nil (la app usa el símbolo)")
    }
}
