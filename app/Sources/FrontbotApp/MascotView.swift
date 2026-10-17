import SwiftUI
import RealityKit
import FrontbotCore

/// La mascota en 3D. Pide fotogramas solo mientras se ve y su estado se mueve; si el modelo no carga, muestra el logo.
struct MascotView: View {
    let state: MascotState
    let size: CGFloat
    var animated = true

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var scene: MascotScene?
    @State private var failed = false
    @State private var visible = false
    /// Verdadero durante la mezcla tras un cambio de estado: aunque no haya movimiento, el brillo aún se está transicionando.
    @State private var blending = false
    @State private var tracker = PoseTracker()

    /// Última pose aplicada: al cambiar de estado se mezcla desde ella (sin saltos).
    /// También guarda el estado visto y el instante del cambio, para detectarlo al dibujar (antes de que `update` sobrescriba `last`).
    @MainActor final class PoseTracker {
        var last = MascotPose.rest
        var from = MascotPose.rest
        var since = Date()
        var lastState: MascotState?
    }

    private var reduceMotion: Bool { systemReduceMotion || !animated }

    var body: some View {
        Group {
            if failed || MascotAssets.model == nil {
                FrontbotLogo(size: size * 0.8)
            } else {
                TimelineView(.animation(minimumInterval: 1 / 30, paused: !visible || !(blending || MascotMotion.needsFrames(state, reduceMotion: reduceMotion)))) { context in
                    reality(pose: pose(at: context.date))
                        // Mientras la escena carga, el logo ocupa el hueco (el RealityView sigue montado para que `make` corra).
                        .overlay { if scene == nil { FrontbotLogo(size: size * 0.8) } }
                }
            }
        }
        .frame(width: size, height: size)
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .task(id: state) {
            blending = true
            // El margen asegura que el último fotograma llegue con progreso >= 1.
            try? await Task.sleep(for: .seconds(MascotMotion.blendDuration + 0.1))
            if !Task.isCancelled { blending = false }
        }
        .accessibilityHidden(true)
    }

    private func pose(at date: Date) -> MascotPose {
        if state != tracker.lastState {
            // Primer dibujo: sin mezcla; después, se mezcla desde la pose en pantalla.
            tracker.from = tracker.lastState == nil ? MascotMotion.pose(state, t: 0, reduceMotion: reduceMotion) : tracker.last
            tracker.since = date
            tracker.lastState = state
        }
        let t = max(0, date.timeIntervalSince(tracker.since))
        let target = MascotMotion.pose(state, t: t, reduceMotion: reduceMotion)
        return MascotMotion.blend(tracker.from, target, progress: Float(t / MascotMotion.blendDuration))
    }

    private func reality(pose: MascotPose) -> some View {
        RealityView { content in
            guard let url = MascotAssets.model, let loaded = try? await MascotScene.load(from: url) else {
                failed = true
                return
            }
            content.add(loaded.root)
            scene = loaded
        } update: { _ in
            scene?.apply(pose)
            tracker.last = pose
        }
        .realityViewCameraControls(.none)
    }
}
