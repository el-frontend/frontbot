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
    @State private var since = Date()
    /// Verdadero durante la mezcla tras un cambio de estado: aunque no haya movimiento, el brillo aún se está transicionando.
    @State private var blending = false
    @State private var tracker = PoseTracker()

    /// Última pose aplicada: al cambiar de estado se mezcla desde ella (sin saltos).
    @MainActor final class PoseTracker { var last = MascotPose.rest; var from = MascotPose.rest }

    private var reduceMotion: Bool { systemReduceMotion || !animated }

    var body: some View {
        Group {
            if failed || MascotAssets.model == nil {
                FrontbotLogo(size: size * 0.8)
            } else {
                TimelineView(.animation(minimumInterval: 1 / 30, paused: !visible || !(blending || MascotMotion.needsFrames(state, reduceMotion: reduceMotion)))) { context in
                    reality(pose: pose(at: context.date))
                }
            }
        }
        .frame(width: size, height: size)
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .onChange(of: state) { _, _ in
            tracker.from = tracker.last
            since = Date()
            blending = true
        }
        .task(id: state) {
            guard blending else { return }
            try? await Task.sleep(for: .seconds(MascotMotion.blendDuration))
            if !Task.isCancelled { blending = false }
        }
        .accessibilityHidden(true)
    }

    private func pose(at date: Date) -> MascotPose {
        let t = date.timeIntervalSince(since)
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
