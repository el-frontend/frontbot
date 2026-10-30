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
        XCTAssertTrue(try files.hasPreviousGuide(brandId: id))
    }

    func testSameContentDoesNotAddHistory() throws {
        let id = UUID().uuidString
        try files.writeGuide(brandId: id, markdown: "v1")
        try files.writeGuide(brandId: id, markdown: "v2")
        try files.writeGuide(brandId: id, markdown: "v2")
        try files.restorePreviousGuide(brandId: id)
        XCTAssertEqual(try files.readGuide(brandId: id), "v1")
        XCTAssertFalse(try files.hasPreviousGuide(brandId: id))
    }

    /// Dos escrituras seguidas del agente no pueden borrar la guía que escribió el usuario.
    func testRestoreWalksBackThroughSeveralWrites() throws {
        let id = UUID().uuidString
        for v in ["usuario", "agente 1", "agente 2"] { try files.writeGuide(brandId: id, markdown: v) }
        try files.restorePreviousGuide(brandId: id)
        XCTAssertEqual(try files.readGuide(brandId: id), "agente 1")
        try files.restorePreviousGuide(brandId: id)
        XCTAssertEqual(try files.readGuide(brandId: id), "usuario")
        XCTAssertFalse(try files.hasPreviousGuide(brandId: id))
    }

    func testHistoryKeepsLastTen() throws {
        let id = UUID().uuidString
        for v in 0...12 { try files.writeGuide(brandId: id, markdown: "v\(v)") }
        var restored: [String] = []
        while try files.hasPreviousGuide(brandId: id) {
            try files.restorePreviousGuide(brandId: id)
            restored.append(try files.readGuide(brandId: id) ?? "")
        }
        XCTAssertEqual(restored, (2...11).reversed().map { "v\($0)" })
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
