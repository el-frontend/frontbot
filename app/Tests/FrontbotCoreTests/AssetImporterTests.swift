import XCTest
import ImageIO
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

    /// Imagen de 2×2 codificada con ImageIO en el formato pedido (p. ej. "org.webmproject.webp", "com.compuserve.gif").
    static func encoded(_ type: String) throws -> Data {
        let ctx = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, type as CFString, 1, nil) else { throw XCTSkip("ImageIO no codifica \(type)") }
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        guard CGImageDestinationFinalize(dest) else { throw XCTSkip("ImageIO no codifica \(type)") }
        return out as Data
    }

    func testImportDataStoresLogoKind() throws {
        let asset = try importer.importImage(data: Data(Self.png + [UInt8](repeating: 0, count: 64)), brandId: brand.id, kind: .logo)
        XCTAssertEqual(asset.kind, "logo")
        XCTAssertTrue(asset.path.hasSuffix(".png"))
        XCTAssertEqual(try db.assets(brandId: brand.id, kind: .logo), [asset])
    }

    func testImportDataConvertsGIFToPNG() throws {
        let asset = try importer.importImage(data: try Self.encoded("com.compuserve.gif"), brandId: brand.id, kind: .image)
        XCTAssertTrue(asset.path.hasSuffix(".png"))
        XCTAssertTrue(try Data(contentsOf: URL(fileURLWithPath: asset.path)).starts(with: Self.png))
    }

    func testImportDataConvertsWebPToPNG() throws {
        // ImageIO lee WebP pero no lo escribe: WebP sin pérdida de 1×1.
        let webp = Data(base64Encoded: "UklGRhoAAABXRUJQVlA4TA0AAAAvAAAAEAcQERGIiP4HAA==")!
        let asset = try importer.importImage(data: webp, brandId: brand.id, kind: .image)
        XCTAssertTrue(asset.path.hasSuffix(".png"))
        XCTAssertTrue(try Data(contentsOf: URL(fileURLWithPath: asset.path)).starts(with: Self.png))
    }

    func testImportDataRejectsHTMLAndSVG() {
        for text in ["<!doctype html><html></html>", "<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>"] {
            XCTAssertThrowsError(try importer.importImage(data: Data(text.utf8), brandId: brand.id, kind: .image)) { error in
                XCTAssertEqual((error as? ValidationError)?.message, "Formato no admitido: solo JPEG, PNG, WebP o GIF.")
            }
        }
        XCTAssertEqual(try db.assets(brandId: brand.id, kind: nil), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: AppPaths(root: root).assetsDir(brand.id).path)
            && !((try? FileManager.default.contentsOfDirectory(atPath: AppPaths(root: root).assetsDir(brand.id).path)) ?? []).isEmpty)
    }

    func testImportDataRejectsGuideSourceKind() {
        XCTAssertThrowsError(try importer.importImage(data: Data(Self.png), brandId: brand.id, kind: .guideSource))
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
