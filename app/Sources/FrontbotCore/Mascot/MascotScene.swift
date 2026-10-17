import Foundation
import RealityKit
import CoreGraphics
import os

/// La mascota lista para RealityKit: modelo, luces (incluida la ambiental, sin la que el blanco se ve gris) y cámara.
/// `apply` mueve solo el modelo; luces y cámara quedan fijas.
@MainActor
public final class MascotScene {
    public let root = Entity()
    public let camera = PerspectiveCamera()
    private let pivot = Entity()
    private let glowLight = PointLight()

    /// Una carga por URL; cada escena usa un clon.
    private static var templates: [URL: Entity] = [:]
    /// Fallos por URL: un archivo corrupto no se vuelve a leer en cada instancia.
    private static var failures: [URL: Error] = [:]
    private static var environment: EnvironmentResource?
    private static let log = Logger(subsystem: "app.frontbot.Frontbot", category: "mascot")

    public static func load(from url: URL) async throws -> MascotScene {
        if let failure = failures[url] { throw failure }
        let template: Entity
        if let cached = templates[url] { template = cached } else {
            do {
                template = try await Entity(contentsOf: url)
            } catch {
                // Se registra una sola vez, al primer fallo.
                failures[url] = error
                log.error("No se pudo cargar el modelo \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                throw error
            }
            templates[url] = template
        }
        let scene = MascotScene()
        try await scene.build(model: template.clone(recursive: true))
        return scene
    }

    private func build(model: Entity) async throws {
        pivot.addChild(model)
        root.addChild(pivot)

        camera.camera.fieldOfViewInDegrees = 30
        camera.position = [0, 0, 2.8] // margen para el salto y el giro
        root.addChild(camera)

        let ambient = Entity()
        ambient.components.set(ImageBasedLightComponent(source: .single(try await Self.ambientEnvironment()), intensityExponent: 0.8))
        root.addChild(ambient)
        model.components.set(ImageBasedLightReceiverComponent(imageBasedLight: ambient))

        let key = DirectionalLight()
        key.light.intensity = 3000
        key.look(at: .zero, from: [1, 1.5, 2], relativeTo: nil)
        root.addChild(key)

        glowLight.light.color = .init(red: 0.37, green: 0.89, blue: 0.84, alpha: 1)
        glowLight.light.attenuationRadius = 2
        glowLight.position = [0, 0.1, 0.9]
        root.addChild(glowLight)
        apply(.rest)
    }

    public func apply(_ pose: MascotPose) {
        pivot.position = pose.offset
        pivot.orientation = simd_quatf(angle: pose.yaw, axis: [0, 1, 0]) * simd_quatf(angle: pose.pitch, axis: [1, 0, 0]) * simd_quatf(angle: pose.roll, axis: [0, 0, 1])
        pivot.scale = pose.scale
        glowLight.light.intensity = 300 + 2700 * pose.glow
    }

    public static func vertexCount(of entity: Entity) -> Int {
        var count = 0
        if let model = entity.components[ModelComponent.self] {
            for m in model.mesh.contents.models { for part in m.parts { count += part.positions.count } }
        }
        return count + entity.children.reduce(0) { $0 + vertexCount(of: $1) }
    }

    /// Degradado vertical (arriba claro, abajo gris) como entorno equirectangular.
    private static func ambientEnvironment() async throws -> EnvironmentResource {
        if let environment { return environment }
        let w = 256, h = 128
        var px = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            let v = UInt8(max(70, 255 - y * 185 / h))
            for x in 0..<w { let i = (y * w + x) * 4; px[i] = v; px[i + 1] = v; px[i + 2] = v }
        }
        let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                            provider: CGDataProvider(data: Data(px) as CFData)!, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
        let resource = try await EnvironmentResource(equirectangular: image)
        environment = resource
        return resource
    }
}

/// Dónde están los archivos de la mascota: dentro del .app (Contents/Resources/Mascot) o, en desarrollo, en las fuentes.
public enum MascotResources {
    public static func locate(_ name: String, candidates: [URL]) -> URL? {
        candidates.map { $0.appendingPathComponent(name) }.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
