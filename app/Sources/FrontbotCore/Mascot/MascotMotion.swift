import Foundation
import simd

/// Pose del modelo respecto a su posición de reposo (lado mayor = 1, ángulos en radianes).
public struct MascotPose: Equatable, Sendable {
    public var offset: SIMD3<Float>
    public var yaw: Float
    public var pitch: Float
    public var roll: Float
    public var scale: SIMD3<Float>
    /// Intensidad de la luz cian, 0…1.
    public var glow: Float

    public init(offset: SIMD3<Float> = .zero, yaw: Float = 0, pitch: Float = 0, roll: Float = 0, scale: SIMD3<Float> = [1, 1, 1], glow: Float = 0.3) {
        self.offset = offset; self.yaw = yaw; self.pitch = pitch; self.roll = roll; self.scale = scale; self.glow = glow
    }

    public static let rest = MascotPose()
}

/// Movimiento de la mascota por estado: funciones puras del tiempo transcurrido en el estado.
public enum MascotMotion {
    public static let blendDuration: TimeInterval = 0.25

    public static func period(_ state: MascotState) -> TimeInterval? {
        switch state {
        case .idle: 4
        case .listening: 3
        case .thinking: 1.6
        case .talking: 0.5
        case .happy, .sad: nil
        }
    }

    /// En reposo con "Reducir movimiento" no cambia nada: la vista puede dejar de pedir fotogramas.
    public static func needsFrames(_ state: MascotState, reduceMotion: Bool) -> Bool {
        !(reduceMotion && (state == .idle || state == .listening))
    }

    public static func pose(_ state: MascotState, t: TimeInterval, reduceMotion: Bool) -> MascotPose {
        let p = motion(state, t: Float(t))
        return reduceMotion ? MascotPose(glow: p.glow) : p
    }

    public static func blend(_ a: MascotPose, _ b: MascotPose, progress: Float) -> MascotPose {
        let k = smooth(min(max(progress, 0), 1))
        let mix = { (x: Float, y: Float) in x + (y - x) * k }
        // El giro va por el camino corto (p. ej. de 2π a 0 no da otra vuelta).
        let yaw = a.yaw + remainder(b.yaw - a.yaw, 2 * .pi) * k
        return MascotPose(offset: a.offset + (b.offset - a.offset) * k, yaw: yaw, pitch: mix(a.pitch, b.pitch), roll: mix(a.roll, b.roll),
                          scale: a.scale + (b.scale - a.scale) * k, glow: mix(a.glow, b.glow))
    }

    // MARK: Estados

    private static func motion(_ state: MascotState, t: Float) -> MascotPose {
        let tau = 2 * Float.pi
        switch state {
        case .idle: // flota despacio y se mece
            let w = tau * t / 4
            return MascotPose(offset: [0, 0.03 * sin(w), 0], roll: 0.03 * sin(w + .pi / 2), glow: 0.3)
        case .listening: // te mira con la cabeza ladeada
            let w = tau * t / 3
            return MascotPose(offset: [0, 0.015 * sin(w), 0], pitch: -0.12, roll: 0.15 + 0.03 * sin(w), glow: 0.6)
        case .thinking: // mira a un lado y a otro; la luz pulsa
            let w = tau * t / 1.6
            return MascotPose(offset: [0, 0.02 * sin(2 * w), 0], yaw: 0.35 * sin(w), roll: 0.05 * sin(w), glow: 0.5 + 0.5 * sin(2 * w) * 0.8)
        case .talking: // rebotes cortos al ritmo de las respuestas
            let b = abs(sin(.pi * t / 0.5))
            return MascotPose(offset: [0, 0.04 * b, 0], scale: [1 - 0.02 * b, 1 + 0.03 * b, 1 - 0.02 * b], glow: 0.6 + 0.3 * b)
        case .happy: // se agacha, salta girando una vuelta entera y aterriza
            let crouch = t < 0.15 ? sin(.pi * t / 0.15) : 0
            let jump = (0.15..<0.75).contains(t) ? sin(.pi * (t - 0.15) / 0.6) : 0
            let spin = tau * smooth(min(max((t - 0.2) / 1.0, 0), 1))
            return MascotPose(offset: [0, 0.15 * jump - 0.03 * crouch, 0], yaw: spin == tau ? 0 : spin,
                              scale: [1 + 0.06 * crouch - 0.03 * jump, 1 - 0.1 * crouch + 0.06 * jump, 1 + 0.06 * crouch - 0.03 * jump], glow: 1)
        case .sad: // se encoge y baja la mirada
            let k = smooth(min(t / 0.3, 1))
            return MascotPose(offset: [0, -0.04 * k, 0], pitch: 0.25 * k, scale: [1 - 0.08 * k, 1 - 0.08 * k, 1 - 0.08 * k], glow: 0.3 - 0.2 * k)
        }
    }

    private static func smooth(_ x: Float) -> Float { x * x * (3 - 2 * x) }
}
