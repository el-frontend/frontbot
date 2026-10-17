import SwiftUI
import FrontbotCore

/// Un tema abierto: pregunta, estado, avance y menú de acciones.
struct LabTopicRow: View {
    let model: AppModel
    let topic: LabTopic
    let openNotebook: () -> Void
    @State private var confirmingAbandon = false

    private var running: Bool { model.lab.runningSession?.topic.id == topic.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Text(topic.question).font(.system(size: 13, weight: .medium)).frame(maxWidth: .infinity, alignment: .leading)
                if running {
                    LabPill(text: "estudiando ahora", color: Theme.inFlight)
                    Button("Detener") { model.lab.cancelRunning() }.buttonStyle(OutlineButtonStyle())
                } else {
                    LabPill(text: topic.status == .paused ? "pausado" : "estudiando",
                            color: topic.status == .paused ? Theme.muted : Theme.inFlight)
                }
                Menu {
                    Button("Estudiar ahora") { model.lab.studyNow(topic) }.disabled(running || topic.status == .paused)
                    if topic.status == .paused {
                        Button("Reanudar") { model.lab.resume(topic) }
                    } else {
                        Button("Pausar") { model.lab.pause(topic) }
                    }
                    Button("Abandonar", role: .destructive) { confirmingAbandon = true }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel("Acciones del tema")
            }
            if topic.status == .paused, let reason = topic.pausedReason {
                Text(reason).font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            Text("sesión \(topic.sessions) · \(LabFormat.tokens(topic.tokensUsed)) tokens")
                .font(Theme.mono(11)).foregroundStyle(Theme.muted)
            if let latest = latestText {
                Text(latest).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).lineLimit(3)
            }
            Button("Ver cuaderno", action: openNotebook).buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.accent)
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Theme.border.frame(height: 1) }
        .confirmationDialog("¿Abandonar este tema?", isPresented: $confirmingAbandon) {
            Button("Abandonar", role: .destructive) { model.lab.abandon(topic) }
        } message: {
            Text("Deja de estudiarlo. Su cuaderno se conserva.")
        }
    }

    /// La última conclusión del tema o, si no hay, el último resultado del cuaderno.
    private var latestText: String? {
        if let c = topic.conclusion, !c.isEmpty { return c }
        return model.lab.entries(topicId: topic.id).last { $0.kind == .conclusion || $0.kind == .result }?.text
    }
}
