import SwiftUI
import FrontbotCore

/// Cuaderno de un tema: entradas agrupadas por sesión y los archivos que dejó.
struct NotebookView: View {
    let model: AppModel
    let agent: Agent
    let topic: LabTopic
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let sessions = model.lab.sessions(topicId: topic.id).sorted { $0.startedAt < $1.startedAt }
        let entries = model.lab.entries(topicId: topic.id)
        return VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(topic.question).font(.system(size: 16, weight: .semibold))
                    if !topic.why.isEmpty { Text(topic.why).font(.system(size: 12)).foregroundStyle(Theme.muted) }
                }
                Spacer()
                Button("Cerrar") { dismiss() }.buttonStyle(OutlineButtonStyle()).keyboardShortcut(.cancelAction)
            }
            .padding(22)
            .overlay(alignment: .bottom) { Theme.border.frame(height: 1) }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if entries.isEmpty && sessions.isEmpty {
                        Text("El cuaderno está vacío: el agente aún no ha estudiado este tema.")
                            .font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }
                    ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                        sessionBlock(number: index + 1, session: session, entries: entries.filter { $0.sessionId == session.id })
                    }
                    let loose = entries.filter { e in e.sessionId == nil || !sessions.contains { $0.id == e.sessionId } }
                    if !loose.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Sin sesión").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.muted)
                            ForEach(loose) { EntryRow(entry: $0) }
                        }
                    }
                    NotebookFiles(model: model, agent: agent, topic: topic)
                }
                .padding(22).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 760, height: 640)
        .background(Theme.sidebar)
    }

    private func sessionBlock(number: Int, session: LabSession, entries: [LabEntry]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(sessionHeader(number, session)).font(Theme.mono(11)).foregroundStyle(Theme.muted)
            ForEach(entries) { EntryRow(entry: $0) }
            if entries.isEmpty { Text("Sin entradas.").font(.system(size: 12)).foregroundStyle(Theme.muted) }
        }
    }

    private func sessionHeader(_ number: Int, _ s: LabSession) -> String {
        var parts = [String(localized: "Sesión \(number)"), s.startedAt.formatted(.dateTime.day().month(.abbreviated).hour().minute())]
        if !s.models.isEmpty {
            let list = s.models.map { "\(LabFormat.modelName($0.model)) \(LabFormat.tokens($0.tokens))" }.joined(separator: ", ")
            parts.append(String(localized: "modelos (\(list))"))
        }
        parts.append(LabFormat.sessionStatus(s.status))
        return parts.joined(separator: " · ")
    }
}

private struct EntryRow: View {
    let entry: LabEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                LabPill(text: kindLabel, color: Theme.inFlight)
                if let evidence = entry.evidence { LabPill(text: evidenceLabel(evidence), color: evidenceColor(evidence)) }
                Spacer()
            }
            MarkdownView(text: entry.text)
            ForEach(entry.sources, id: \.self) { source in
                if let url = URL(string: source), ["http", "https"].contains(url.scheme?.lowercased()) {
                    Link(source, destination: url).font(.system(size: 11)).lineLimit(1)
                } else {
                    Text(source).font(Theme.mono(11)).foregroundStyle(Theme.muted).textSelection(.enabled)
                }
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading).panel(radius: 10)
    }

    private var kindLabel: String {
        switch entry.kind {
        case .hypothesis: String(localized: "hipótesis")
        case .test: String(localized: "prueba")
        case .result: String(localized: "resultado")
        case .conclusion: String(localized: "conclusión")
        case .model_note: String(localized: "nota del modelo")
        case .feedback: String(localized: "tu comentario")
        case .note: String(localized: "nota")
        }
    }

    private func evidenceLabel(_ e: Evidence) -> String {
        switch e { case .weak: String(localized: "evidencia débil"); case .medium: String(localized: "evidencia media"); case .strong: String(localized: "evidencia fuerte") }
    }

    private func evidenceColor(_ e: Evidence) -> Color {
        switch e { case .weak: Theme.muted; case .medium: Theme.draft; case .strong: Theme.approved }
    }
}
