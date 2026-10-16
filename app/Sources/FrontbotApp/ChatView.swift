import SwiftUI
import FrontbotCore

struct ChatView: View {
    @Bindable var model: AppModel
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(model.messages.first(where: { $0.role == .user })?.text ?? "Nueva conversación")
                    .font(.system(size: 13, weight: .medium)).lineLimit(1)
                if let brand = model.selectedBrand {
                    Text(brand.name).font(Theme.mono()).foregroundStyle(Theme.muted)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.borderStrong))
                }
                Spacer()
            }
            .padding(.horizontal, 20).frame(height: 48)
            .overlay(alignment: .bottom) { Theme.border.frame(height: 1) }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if model.messages.isEmpty { emptyState }
                        ForEach(model.messages) { message in
                            row(message).id(message.id)
                        }
                        if model.isRunning {
                            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("pensando…").font(Theme.mono(12)).foregroundStyle(Theme.muted) }
                        }
                    }
                    .frame(maxWidth: 760, alignment: .leading)
                    .padding(.horizontal, 24).padding(.vertical, 28)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: model.messages.count) { _, _ in
                    if let last = model.messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }

            composer.padding(.horizontal, 24).padding(.bottom, 22)
        }
        .background(Theme.background)
        .onAppear { focused = true }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("¿Qué hacemos hoy?").font(.system(size: 22, weight: .semibold))
            Text("Pídele posts para una marca, que investigue un tema, que te recuerde algo o que busque oportunidades de negocio.")
                .foregroundStyle(Theme.muted).lineSpacing(3)
        }
        .padding(.top, 80)
    }

    @ViewBuilder
    private func row(_ message: ChatMessage) -> some View {
        switch message.role {
        case .user:
            Text(message.text)
                .textSelection(.enabled).lineSpacing(3)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .panel(radius: 12, fill: Theme.raised)
                .frame(maxWidth: 520, alignment: .trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .agent:
            Text(message.text).textSelection(.enabled).lineSpacing(4).foregroundStyle(Color(hex: 0xDCDCE0))
        case .tool:
            HStack(spacing: 8) {
                Text("✓").foregroundStyle(Theme.approved)
                Text(message.text.replacingOccurrences(of: "→ ", with: ""))
            }
            .font(Theme.mono(12)).foregroundStyle(Theme.muted)
        case .error:
            Text(message.text).foregroundStyle(Theme.danger)
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(model.selectedBrand.map { "Pídele algo para \($0.name)…" } ?? "Pídele algo a Frontbot…",
                      text: $draft, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 14)).lineLimit(1...6)
                .focused($focused)
                .onSubmit(submit)
            HStack(spacing: 8) {
                Menu {
                    Button("Sin marca") { model.selectedBrandId = nil }
                    ForEach(model.brands) { brand in Button(brand.name) { model.selectedBrandId = brand.id } }
                } label: {
                    HStack(spacing: 6) {
                        if let brand = model.selectedBrand { BrandAvatar(brand: brand, size: 14) }
                        Text(model.selectedBrand?.name ?? "Sin marca").lineLimit(1)
                    }
                }
                .menuStyle(.borderlessButton)
                .frame(minWidth: 300, maxWidth: 300, alignment: .leading)
                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 10).frame(height: 28)
                .panel(radius: 7, fill: Theme.raised)

                Text(model.modelName).font(Theme.mono()).foregroundStyle(Theme.muted)
                    .padding(.horizontal, 10).frame(height: 28)
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.borderStrong))

                Spacer()
                if model.isRunning {
                    Button { model.cancel() } label: { Image(systemName: "stop.fill").font(.system(size: 12)) }
                        .buttonStyle(.plain).foregroundStyle(Theme.text)
                        .frame(width: 32, height: 32).panel(radius: 8, fill: Theme.raised)
                        .accessibilityLabel("Detener")
                } else {
                    Button(action: submit) { Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold)) }
                        .buttonStyle(.plain).foregroundStyle(Theme.onAccent)
                        .frame(width: 32, height: 32)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accent))
                        .opacity(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.4 : 1)
                        .keyboardShortcut(.return, modifiers: .command)
                        .accessibilityLabel("Enviar")
                }
            }
        }
        .padding(.leading, 16).padding(.trailing, 12).padding(.vertical, 12)
        .frame(maxWidth: 760)
        .panel(radius: 14)
        .frame(maxWidth: .infinity)
    }

    private func submit() {
        guard !model.isRunning else { return }
        model.send(prompt: draft)
        draft = ""
    }
}
