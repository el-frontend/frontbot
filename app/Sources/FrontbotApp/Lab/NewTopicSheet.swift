import SwiftUI
import FrontbotCore

/// Abre un tema de estudio para el agente.
struct NewTopicSheet: View {
    let model: AppModel
    let agent: Agent
    @Environment(\.dismiss) private var dismiss
    @State private var question = ""
    @State private var why = ""
    static let maxQuestion = 300

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Nuevo tema de estudio").font(.system(size: 16, weight: .semibold))
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    SectionLabel("Pregunta")
                    Spacer()
                    Text("\(question.count)/\(Self.maxQuestion)").font(Theme.mono(10))
                        .foregroundStyle(question.count > Self.maxQuestion ? Theme.danger : Theme.muted)
                }
                TextField("¿Qué quieres que estudie \(agent.name)?", text: $question, axis: .vertical)
                    .textFieldStyle(.plain).lineLimit(2...4).padding(10).panel(radius: 8)
            }
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("Por qué")
                TextField("Para qué te sirve la respuesta", text: $why, axis: .vertical)
                    .textFieldStyle(.plain).lineLimit(2...4).padding(10).panel(radius: 8)
            }
            if let error = model.errorMessage { Text(error).font(.system(size: 12)).foregroundStyle(Theme.danger) }
            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }.buttonStyle(OutlineButtonStyle())
                Button("Abrir tema") {
                    model.errorMessage = nil
                    model.lab.openTopic(agentId: agent.id, question: question.trimmingCharacters(in: .whitespacesAndNewlines),
                                        why: why.trimmingCharacters(in: .whitespacesAndNewlines))
                    if model.errorMessage == nil { dismiss() }
                }
                .buttonStyle(AccentButtonStyle()).keyboardShortcut(.defaultAction)
                .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || question.count > Self.maxQuestion)
            }
        }
        .padding(22).frame(width: 560)
        .background(Theme.sidebar)
        .onAppear { model.errorMessage = nil }
        .onDisappear { model.errorMessage = nil }
    }
}
