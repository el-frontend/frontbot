import XCTest
@testable import FrontbotCore

final class BrandFilesTests: XCTestCase {
    var root: URL!
    var files: BrandFiles!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        files = BrandFiles(paths: AppPaths(root: root))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testGuideRoundTrip() throws {
        let id = UUID().uuidString
        XCTAssertNil(try files.readGuide(brandId: id))
        try files.writeGuide(brandId: id, markdown: "# Tono\nCercano ☕️")
        XCTAssertEqual(try files.readGuide(brandId: id), "# Tono\nCercano ☕️")
    }

    func testDeleteBrandRemovesItsFolder() throws {
        let id = UUID().uuidString
        try files.writeGuide(brandId: id, markdown: "# Tono")
        try files.deleteBrand(brandId: id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.paths.brandDir(id).path))
        XCTAssertNoThrow(try files.deleteBrand(brandId: id), "borrar una carpeta que no existe no es un error")
        XCTAssertThrowsError(try files.deleteBrand(brandId: ".."))
    }

    func testRejectsPathTraversalIds() {
        XCTAssertThrowsError(try files.writeGuide(brandId: "../../etc", markdown: "x"))
        XCTAssertThrowsError(try files.readGuide(brandId: "../x"))
    }

    func testIdeaReportIsWritten() throws {
        let url = try files.writeIdeaReport(ideaId: UUID().uuidString, markdown: "# Reporte")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "# Reporte")
        XCTAssertTrue(url.path.hasPrefix(root.path))
    }
}
