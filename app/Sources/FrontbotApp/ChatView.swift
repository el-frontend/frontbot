import SwiftUI
import FrontbotCore

struct ChatView: View {
    @Bindable var model: AppModel
    @State private var draft = ""
    @StateObject private var dictation = Dictation()
    /// Texto que había antes de dictar y lo último que escribió el dictado en el campo.
    @State private var dictationBase = ""
    @State private var dictated = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if let agent = model.selectedAgent { AgentAvatar(agent: agent, size: 20) }
                Text(model.conversations.first { $0.id == model.currentConversationId }?.title ?? "Nueva conversación")
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
                        ForEach(model.pendingProposals.filter { $0.agentId == model.selectedAgentId }) { p in
                            ProposalCard(model: model, proposal: p)
                        }
                        if model.isRunningHere {
                            HStack(spacing: 8) {
                                if model.selectedAgent?.isDefault == true {
                                    TimelineView(.periodic(from: .now, by: 0.25)) { context in
                                        MascotView(state: model.mascot.state(at: context.date, listening: false), size: 28)
                                    }
                                } else {
                                    ProgressView().controlSize(.small)
                                }
                                Text("pensando…").font(Theme.mono(12)).foregroundStyle(Theme.muted)
                            }
                        }
                    }
                    .frame(maxWidth: 760, alignment: .leading)
                    .padding(.horizontal, 24).padding(.vertical, 28)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: model.messages.count) { _, _ in
                    if let last = model.messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
                // Al abrir un chat (aunque tenga los mismos mensajes que el anterior) se va al final.
                .onChange(of: model.currentConversationId) { _, _ in scrollToEnd(proxy) }
                .onAppear { scrollToEnd(proxy) }
            }

            composer.padding(.horizontal, 24).padding(.bottom, 22)
        }
        .background(Theme.background)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let agent = model.selectedAgent, !agent.isDefault {
                AgentAvatar(agent: agent, size: 36)
                Text("Hablas con \(agent.name)").font(.system(size: 22, weight: .semibold))
                Text(agent.description.isEmpty ? "Un agente especializado de Frontbot." : agent.description)
                    .foregroundStyle(Theme.muted).lineSpacing(3)
            } else {
                TimelineView(.periodic(from: .now, by: 0.25)) { context in
                    MascotView(state: model.mascot.state(at: context.date, listening: !draft.isEmpty), size: 140)
                }
                .padding(.bottom, 4)
                Text("¿Qué hacemos hoy?").font(.system(size: 22, weight: .semibold))
                Text("Pídele posts para una marca, que investigue un tema, que te recuerde algo o que busque oportunidades de negocio.")
                    .foregroundStyle(Theme.muted).lineSpacing(3)
            }
        }
        .padding(.top, 40)
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
            MarkdownView(text: message.text)
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
            // Return envía; ⌘/⇧/⌥ + Return saltan de línea.
            HStack(alignment: .top, spacing: 8) {
                ComposerTextView(text: $draft,
                                 placeholder: dictation.state == .listening ? "Te escucho…"
                                     : model.selectedBrand.map { "Pídele algo para \($0.name)…" } ?? "Pídele algo a \(model.selectedAgent?.name ?? "Frontbot")…",
                                 focusToken: AnyHashable(model.currentConversationId),
                                 onSubmit: submit,
                                 onEscape: { guard dictation.isActive else { return false }; dictation.stop(); return true })
                MicButton(dictation: dictation, action: toggleDictation)
            }
            if let problem = dictation.problem {
                Text(problem).font(.system(size: 11)).foregroundStyle(Theme.danger)
            }
            HStack(spacing: 8) {
                agentMenu
                Menu {
                    Button("Sin marca") { model.selectedBrandId = nil }
                    ForEach(model.brands) { brand in Button(brand.name) { model.selectedBrandId = brand.id } }
                } label: {
                    // Etiqueta propia: el estilo borderlessButton de macOS reduce un HStack a su primer elemento.
                    HStack(spacing: 6) {
                        if let brand = model.selectedBrand { BrandAvatar(brand: brand, size: 14) }
                        Text(model.selectedBrand?.name ?? "Sin marca").lineLimit(1).truncationMode(.tail)
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(Theme.muted)
                    }
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 10).frame(height: 28)
                    .frame(maxWidth: 180)
                    .panel(radius: 7, fill: Theme.raised)
                    .contentShape(Rectangle())
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                .fixedSize()

                Menu {
                    ForEach(AgentModel.all, id: \.id) { option in
                        Button { model.selectedModel = option.id } label: {
                            if option.id == model.selectedModel { Label(option.label, systemImage: "checkmark") } else { Text(option.label) }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(model.modelName)
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                    }
                    .font(Theme.mono()).foregroundStyle(Theme.muted)
                    .padding(.horizontal, 10).frame(height: 28)
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.borderStrong))
                    .contentShape(Rectangle())
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                .fixedSize()
                .help("Modelo del agente")
                if model.selectedAgent?.browser == true {
                    Label("Chrome", systemImage: "globe").font(Theme.mono()).foregroundStyle(Theme.muted)
                        .padding(.horizontal, 10).frame(height: 28)
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.borderStrong))
                        .help("Este agente puede usar tu Chrome con tus sesiones (se cambia en su página)")
                }

                Spacer()
                if model.isRunningHere {
                    Button { model.cancel() } label: { Image(systemName: "stop.fill").font(.system(size: 12)) }
                        .buttonStyle(.plain).foregroundStyle(Theme.text)
                        .frame(width: 32, height: 32).panel(radius: 8, fill: Theme.raised)
                        .accessibilityLabel("Detener")
                } else {
                    Button(action: submit) { Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold)) }
                        .buttonStyle(.plain).foregroundStyle(Theme.onAccent)
                        .frame(width: 32, height: 32)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accent))
                        .opacity(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isRunning ? 0.4 : 1)
                        .help(model.isRunning ? "El agente está respondiendo en otro chat: espera a que termine." : "Enviar")
                        .accessibilityLabel("Enviar")
                }
            }
        }
        .padding(.leading, 16).padding(.trailing, 12).padding(.vertical, 12)
        .frame(maxWidth: 760)
        .panel(radius: 14)
        .frame(maxWidth: .infinity)
    }

    /// Cambiar de agente empieza una conversación nueva con él.
    private var agentMenu: some View {
        Menu {
            ForEach(model.agents.filter { $0.status == .active }) { agent in
                Button { model.newConversation(agentId: agent.id) } label: {
                    if agent.id == model.selectedAgentId { Label(agent.name, systemImage: "checkmark") } else { Text(agent.name) }
                }
            }
        } label: {
            HStack(spacing: 6) {
                if let agent = model.selectedAgent { AgentAvatar(agent: agent, size: 14) }
                Text(model.selectedAgent?.name ?? "Agente").lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(Theme.muted)
            }
            .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 10).frame(height: 28)
            .frame(maxWidth: 180)
            .panel(radius: 7, fill: Theme.raised)
            .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .fixedSize()
        .disabled(model.isRunning)
        .help("Agente")
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        guard let last = model.messages.last else { return }
        // Tras el layout del nuevo contenido; si no, el scroll se queda corto.
        DispatchQueue.main.async { proxy.scrollTo(last.id, anchor: .bottom) }
    }

    private func submit() {
        guard !model.isRunning, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        dictation.cancel()
        model.send(prompt: draft)
        draft = ""
    }

    /// El dictado se añade detrás de lo ya escrito y se va reescribiendo mientras hablas.
    private func toggleDictation() {
        if !dictation.isActive {
            dictationBase = draft.isEmpty || draft.last?.isWhitespace == true ? draft : draft + " "
            dictated = draft
        }
        dictation.toggle { text in
            // Si editaste el campo mientras dictaba, lo tuyo manda: el dictado se para.
            guard draft == dictated else { dictation.cancel(); return }
            draft = dictationBase + text
            dictated = draft
        }
    }
}
