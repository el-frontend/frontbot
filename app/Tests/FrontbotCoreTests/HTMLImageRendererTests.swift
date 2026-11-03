import XCTest
import ImageIO
import AppKit
@testable import FrontbotCore

final class HTMLImageRendererTests: XCTestCase {
    let renderer = WebKitHTMLRenderer()

    /// Color (r, g, b) del píxel central del PNG, más su tamaño.
    func inspect(_ png: Data) throws -> (width: Int, height: Int, center: (Int, Int, Int)) {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        // Se lee el píxel en sRGB con un contexto propio (colorAt de NSBitmapImageRep convierte de más).
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = try XCTUnwrap(CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(image, in: CGRect(x: -CGFloat(image.width / 2), y: -CGFloat(image.height / 2),
                                   width: CGFloat(image.width), height: CGFloat(image.height)))
        return (image.width, image.height, (Int(px[0]), Int(px[1]), Int(px[2])))
    }

    func assertColor(_ c: (Int, Int, Int), _ e: (Int, Int, Int), file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThanOrEqual(abs(c.0 - e.0), 3, "\(c)", file: file, line: line)
        XCTAssertLessThanOrEqual(abs(c.1 - e.1), 3, "\(c)", file: file, line: line)
        XCTAssertLessThanOrEqual(abs(c.2 - e.2), 3, "\(c)", file: file, line: line)
    }

    func testRendersExactPixelSize() async throws {
        let png = try await renderer.render(html: #"<html><body style="margin:0;background:#F2A3C9"></body></html>"#,
                                            size: ImageSize(width: 1080, height: 1350))
        let info = try inspect(png)
        XCTAssertEqual(info.width, 1080)
        XCTAssertEqual(info.height, 1350)
        assertColor(info.center, (242, 163, 201))
    }

    func testJavaScriptDisabled() async throws {
        let html = #"<html><body style="margin:0;background:#fff"><script>document.body.style.background='#000'</script></body></html>"#
        let info = try inspect(try await renderer.render(html: html, size: ImageSize(width: 200, height: 200)))
        assertColor(info.center, (255, 255, 255))
    }

    func testFileURLsBlocked() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let red = NSImage(size: NSSize(width: 10, height: 10))
        red.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 10, height: 10).fill(); red.unlockFocus()
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(red.tiffRepresentation)))
        let file = dir.appendingPathComponent("red.png")
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: file)
        let html = #"<html><body style="margin:0;background:#fff"><img src="\#(file.absoluteString)" style="width:100%;height:100%"></body></html>"#
        let info = try inspect(try await renderer.render(html: html, size: ImageSize(width: 200, height: 200)))
        assertColor(info.center, (255, 255, 255))
    }

    func testRejectsOversizedHTML() async throws {
        let html = String(repeating: "a", count: WebKitHTMLRenderer.maxHTMLBytes + 1)
        do {
            _ = try await renderer.render(html: html, size: ImageSize(width: 100, height: 100))
            XCTFail("debería rechazarlo")
        } catch is ValidationError {}
    }
}
