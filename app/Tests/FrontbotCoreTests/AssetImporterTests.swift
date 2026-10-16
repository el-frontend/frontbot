import XCTest
@testable import FrontbotCore

final class AssetImporterTests: XCTestCase {
    var db: AppDatabase!
    var brand: Brand!
    var root: URL!
    var importer: AssetImporter!
    var tmp: URL!

    override func setUpWithError() throws {
        db = try AppDatabase.inMemory()
        let ws = try db.ensureDefaultWorkspace()
        brand = try db.createBrand(workspaceId: ws.id, name: "B", industry: "", networks: [.instagram])
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        importer = AssetImporter(db: db, paths: AppPaths(root: root))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: tmp)
    }

    func write(_ bytes: [UInt8], padTo size: Int = 0, name: String) throws -> URL {
        var data = Data(bytes)
        if size > data.count { data.append(Data(count: size - data.count)) }
        let url = tmp.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    static let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    static let jpeg: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0]

    func testImportsPngAndCopiesItIntoBrandAssets() throws {
        let source = try write(Self.png, padTo: 1024, name: "foto.png")
        let asset = try importer.importImage(from: source, brandId: brand.id)
        XCTAssertEqual(asset.kind, AssetKind.image.rawValue)
        XCTAssertTrue(asset.path.hasPrefix(AppPaths(root: root).assetsDir(brand.id).path))
        XCTAssertTrue(asset.path.hasSuffix(".png"))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: asset.path)).count, 1024)
        XCTAssertEqual(try db.assets(brandId: brand.id, kind: .image), [asset])
    }

    func testJpegWithWrongExtensionIsStoredAsJpg() throws {
        let source = try write(Self.jpeg, padTo: 100, name: "foto.png")
        XCTAssertTrue(try importer.importImage(from: source, brandId: brand.id).path.hasSuffix(".jpg"))
    }

    func testRejectsFakeImageByContent() throws {
        let pdfNamedPng = try write(Array("%PDF-1.4".utf8), name: "falso.png")
        XCTAssertThrowsError(try importer.importImage(from: pdfNamedPng, brandId: brand.id)) { error in
            XCTAssertEqual((error as? ValidationError)?.message, "Formato no admitido: solo JPEG o PNG.")
        }
        let empty = try write([], name: "vacio.jpg")
        XCTAssertThrowsError(try importer.importImage(from: empty, brandId: brand.id))
        XCTAssertEqual(try db.assets(brandId: brand.id, kind: nil), [])
    }

    func testRejectsImagesOver8MB() throws {
        let big = try write(Self.png, padTo: 8 * 1024 * 1024 + 1, name: "grande.png")
        XCTAssertThrowsError(try importer.importImage(from: big, brandId: brand.id)) { error in
            XCTAssertEqual((error as? ValidationError)?.message, "La imagen pesa 8.0 MB; el máximo es 8 MB.")
        }
    }

    func testImportsGuidePdfAndRejectsNonPdf() throws {
        let pdf = try write(Array("%PDF-1.4\n".utf8), padTo: 200, name: "guia.pdf")
        let asset = try importer.importGuidePDF(from: pdf, brandId: brand.id)
        XCTAssertEqual(asset.kind, "guide_source")
        let notPdf = try write(Self.png, name: "guia.pdf")
        XCTAssertThrowsError(try importer.importGuidePDF(from: notPdf, brandId: brand.id)) { error in
            XCTAssertEqual((error as? ValidationError)?.message, "El archivo no es un PDF.")
        }
    }

    func testUnknownBrand() throws {
        let source = try write(Self.png, name: "a.png")
        XCTAssertThrowsError(try importer.importImage(from: source, brandId: UUID().uuidString))
    }
}
