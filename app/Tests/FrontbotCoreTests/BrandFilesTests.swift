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

    func testWriteKeepsPrevious() throws {
        let id = UUID().uuidString
        try files.writeGuide(brandId: id, markdown: "v1")
        XCTAssertFalse(try files.hasPreviousGuide(brandId: id))
        try files.writeGuide(brandId: id, markdown: "v2")
        XCTAssertEqual(try String(contentsOf: files.paths.previousGuide(id), encoding: .utf8), "v1")
        XCTAssertTrue(try files.hasPreviousGuide(brandId: id))
    }

    func testSameContentDoesNotOverwriteBackup() throws {
        let id = UUID().uuidString
        try files.writeGuide(brandId: id, markdown: "v1")
        try files.writeGuide(brandId: id, markdown: "v2")
        try files.writeGuide(brandId: id, markdown: "v2")
        XCTAssertEqual(try String(contentsOf: files.paths.previousGuide(id), encoding: .utf8), "v1")
    }

    func testRestoreSwapsAndIsReversible() throws {
        let id = UUID().uuidString
        try files.writeGuide(brandId: id, markdown: "v1")
        try files.writeGuide(brandId: id, markdown: "v2")
        try files.restorePreviousGuide(brandId: id)
        XCTAssertEqual(try files.readGuide(brandId: id), "v1")
        try files.restorePreviousGuide(brandId: id)
        XCTAssertEqual(try files.readGuide(brandId: id), "v2")
    }

    func testRestoreWithoutCurrentGuideMovesBackup() throws {
        let id = UUID().uuidString
        try files.writeGuide(brandId: id, markdown: "v1")
        try files.writeGuide(brandId: id, markdown: "v2")
        try FileManager.default.removeItem(at: files.paths.guide(id))
        try files.restorePreviousGuide(brandId: id)
        XCTAssertEqual(try files.readGuide(brandId: id), "v1")
        XCTAssertFalse(try files.hasPreviousGuide(brandId: id))
    }

    func testRestoreWithoutBackupThrows() throws {
        let id = UUID().uuidString
        try files.writeGuide(brandId: id, markdown: "v1")
        XCTAssertThrowsError(try files.restorePreviousGuide(brandId: id)) { XCTAssertTrue($0 is ValidationError) }
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
