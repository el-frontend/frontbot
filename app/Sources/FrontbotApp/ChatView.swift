import SwiftUI
import FrontbotCore

struct ChatView: View {
    @Bindable var model: AppModel
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            if !model.apiKeyPresent && ProcessInfo.processInfo.environment["FRONTBOT_FAKE_AGENT"] != "1" {
                Text("Configura tu API key de Anthropic en Ajustes (⌘,).")
                    .frame(maxWidth: .infinity).padding(8).background(.yellow.opacity(0.2))
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(model.messages) { message in
                        Text(message.text)
                            .textSelection(.enabled)
                            .foregroundStyle(color(for: message.role))
                            .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
                    }
                    if model.isRunning { ProgressView().controlSize(.small) }
                }
                .padding()
            }
            Divider()
            HStack {
                TextField(model.selectedBrand.map { "Pídele algo para \($0.name)…" } ?? "Pídele algo a Frontbot…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .onSubmit(submit)
                if model.isRunning {
                    Button("Detener") { model.cancel() }
                } else {
                    Button("Enviar", action: submit).keyboardShortcut(.return, modifiers: .command)
                }
            }
            .padding()
        }
    }

    private func submit() {
        model.send(prompt: draft)
        draft = ""
    }

    private func color(for role: ChatMessage.Role) -> Color {
        switch role {
        case .user: .primary
        case .agent: .primary
        case .tool: .secondary
        case .error: .red
        }
    }
}
