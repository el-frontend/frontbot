import XCTest
import RealityKit
import Metal
import CoreImage
@testable import FrontbotCore

@MainActor
final class MascotSceneTests: XCTestCase {
    static let usdz = AgentClientTests.repoRoot.appendingPathComponent("app/Sources/FrontbotApp/Resources/Mascot/frontbot.usdz")
    static let snapshots = FileManager.default.temporaryDirectory.appendingPathComponent("frontbot-mascot-snapshots", isDirectory: true)

    func testBundledModelIsWithinBudget() async throws {
        let size = try FileManager.default.attributesOfItem(atPath: Self.usdz.path)[.size] as? Int ?? 0
        XCTAssertLessThan(size, 3_000_000)
        let scene = try await MascotScene.load(from: Self.usdz)
        let verts = MascotScene.vertexCount(of: scene.root)
        XCTAssertGreaterThan(verts, 1000); XCTAssertLessThan(verts, 40_000)
    }

    func testMissingModelThrows() async {
        do { _ = try await MascotScene.load(from: URL(fileURLWithPath: "/nope/frontbot.usdz")); XCTFail("debía fallar") } catch {}
    }

    /// Cada estado en su momento más extremo: la mascota se ve y no se sale del encuadre.
    func testEveryStateStaysInFrame() async throws {
        try FileManager.default.createDirectory(at: Self.snapshots, withIntermediateDirectories: true)
        let scene = try await MascotScene.load(from: Self.usdz)
        let moments: [(MascotState, TimeInterval)] = [(.idle, 1), (.listening, 0.5), (.thinking, 0.4), (.talking, 0.25), (.happy, 0.45), (.happy, 0.7), (.sad, 1)]
        for (state, t) in moments {
            scene.apply(MascotMotion.pose(state, t: t, reduceMotion: false))
            let pixels = try await Self.render(scene, size: 256, to: Self.snapshots.appendingPathComponent("\(state.rawValue)-\(t).png"))
            let coverage = Double(pixels.alpha.filter { $0 > 0 }.count) / Double(pixels.alpha.count)
            print("cobertura \(state) t=\(t): \(coverage)")
            XCTAssertTrue((0.15...0.75).contains(coverage), "\(state) t=\(t): cobertura \(coverage)")
            XCTAssertEqual(pixels.borderAlpha, 0, "\(state) t=\(t): toca el borde (se sale del encuadre)")
        }
        print("Instantáneas en \(Self.snapshots.path)")
    }

    struct Pixels { let alpha: [UInt8]; let borderAlpha: Int }

    static func render(_ scene: MascotScene, size: Int, to url: URL) async throws -> Pixels {
        let renderer = try RealityRenderer()
        renderer.entities.append(scene.root)
        renderer.activeCamera = scene.camera
        let device = MTLCreateSystemDefaultDevice()!
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: size, height: size, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]; desc.storageMode = .shared
        let color = device.makeTexture(descriptor: desc)!
        let output = try RealityRenderer.CameraOutput(.singleProjection(colorTexture: color))
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            do { try renderer.updateAndRender(deltaTime: 1 / 60, cameraOutput: output, onComplete: { _ in c.resume() }) } catch { c.resume(throwing: error) }
        }
        renderer.entities.removeAll() // la escena vuelve a estar libre para el siguiente render
        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        color.getBytes(&bytes, bytesPerRow: size * 4, from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
        let ci = CIImage(mtlTexture: color, options: [.colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])!.oriented(.downMirrored)
        try CIContext().writePNGRepresentation(of: ci, to: url, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        let alpha = stride(from: 3, to: bytes.count, by: 4).map { bytes[$0] }
        var border = 0
        for i in 0..<size { border += Int(alpha[i]) + Int(alpha[(size - 1) * size + i]) + Int(alpha[i * size]) + Int(alpha[i * size + size - 1]) }
        return Pixels(alpha: alpha, borderAlpha: border)
    }
}
