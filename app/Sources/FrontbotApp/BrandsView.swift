import SwiftUI
import FrontbotCore

/// Barra lateral: secciones, marcas y estado de la cuenta.
struct BrandsView: View {
    @Bindable var model: AppModel
    @State private var showingNew = false
    @State private var showingNewAgent = false
    @State private var brandToDelete: Brand?
    @State private var conversationToDelete: Conversation?
    @State private var hoveredConversationId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.roundedtop").foregroundStyle(Theme.accent)
                Text("Frontbot").font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("⌥ Space").font(Theme.mono()).foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 6)

            Button { model.newConversation() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                    Text("Nueva conversación")
                    Spacer()
                    Text("⌘N").font(Theme.mono()).foregroundStyle(Theme.muted)
                }
                .padding(.horizontal, 10)
                .frame(height: 34)
                .panel(radius: 8, fill: Theme.raised)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("n", modifiers: .command)

            VStack(spacing: 2) {
                navRow("Chat", icon: "bubble.left", section: .chat)
                navRow("Calendario", icon: "calendar", section: .calendar, count: model.today?.draftsToReview, countColor: Theme.draft)
                navRow("Tareas", icon: "checklist", section: .tasks, count: model.today?.tasks.count)
                navRow("Ideas", icon: "lightbulb", section: .ideas)
                navRow("Skills", icon: "puzzlepiece.extension", section: .skills, count: model.skillDraftCount, countColor: Theme.draft)
                navRow("Programadas", icon: "clock.arrow.circlepath", section: .schedules, count: model.taskDraftCount, countColor: Theme.draft)
                if model.hasTradingAgents {
                    navRow("Trades", icon: "chart.line.uptrend.xyaxis", section: .trades, count: model.pendingProposals.count, countColor: Theme.draft)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    SectionLabel("Agentes")
                    Spacer()
                    Button { showingNewAgent = true } label: { Image(systemName: "plus").foregroundStyle(Theme.muted) }
                        .buttonStyle(.plain).help("Nuevo agente").accessibilityLabel("Nuevo agente")
                }
                .padding(.horizontal, 10).padding(.bottom, 4)
                ForEach(model.agents) { agent in
                    let selected = model.section == .agent(agent.id)
                    Button { model.section = .agent(agent.id) } label: {
                        HStack(spacing: 10) {
                            AgentAvatar(agent: agent)
                            Text(agent.name).lineLimit(1)
                            Spacer()
                            if agent.status == .draft { Text("borrador").font(Theme.mono(10)).foregroundStyle(Theme.draft) }
                        }
                        .foregroundStyle(selected ? Theme.text : agent.status == .draft ? Theme.muted : Theme.textSecondary)
                        .padding(.horizontal, 10)
                        .frame(height: 34)
                        .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Theme.selected : .clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    SectionLabel("Marcas")
                    Spacer()
                    Button { showingNew = true } label: { Image(systemName: "plus").foregroundStyle(Theme.muted) }
                        .buttonStyle(.plain).help("Nueva marca").accessibilityLabel("Nueva marca")
                }
                .padding(.horizontal, 10).padding(.bottom, 4)
                ForEach(model.brands) { brand in
                    Button { model.select(brandId: brand.id) } label: {
                        HStack(spacing: 10) {
                            BrandAvatar(brand: brand)
                            Text(brand.name).lineLimit(1)
                            Spacer()
                            Text(brand.networks.map(Theme.networkShort).joined(separator: " · "))
                                .font(Theme.mono(10)).foregroundStyle(Theme.muted)
                        }
                        .foregroundStyle(model.section == .brand(brand.id) ? Theme.text : Theme.textSecondary)
                        .padding(.horizontal, 10)
                        .frame(height: 34)
                        .background(RoundedRectangle(cornerRadius: 7).fill(model.section == .brand(brand.id) ? Theme.selected : .clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Borrar marca…", role: .destructive) { brandToDelete = brand }
                    }
                }
                if model.brands.isEmpty {
                    Text("Crea tu primera marca con +").font(.system(size: 12)).foregroundStyle(Theme.muted).padding(.horizontal, 10)
                }
            }

            recents.frame(maxHeight: .infinity, alignment: .top)

            VStack(alignment: .leading, spacing: 2) {
                Divider().overlay(Theme.border).padding(.bottom, 8)
                HStack(spacing: 8) {
                    StatusDot(color: Theme.approved, size: 7)
                    Text(model.apiKeyPresent ? "API key de Anthropic" : "Claude Code · conectado")
                }
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 10).frame(height: 30)
                SettingsLink {
                    HStack(spacing: 10) { Image(systemName: "gearshape"); Text("Ajustes"); Spacer() }
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 10).frame(height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .font(.system(size: 13))
        .padding(.vertical, 14).padding(.horizontal, 10)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.sidebar)
        .navigationSplitViewColumnWidth(min: 220, ideal: 248, max: 300)
        .sheet(isPresented: $showingNew) { NewBrandSheet(model: model) }
        .sheet(isPresented: $showingNewAgent) { NewAgentSheet(model: model) }
        .sheet(item: $brandToDelete) { brand in DeleteBrandSheet(model: model, brand: brand) }
    }

    private func navRow(_ title: String, icon: String, section: AppModel.Section, count: Int? = nil, countColor: Color = Theme.muted) -> some View {
        let active = model.section == section
        return Button { model.section = section } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).frame(width: 16)
                Text(title)
                Spacer()
                if let count, count > 0 { Text("\(count)").font(Theme.mono()).foregroundStyle(countColor) }
            }
            .foregroundStyle(active ? Theme.text : Theme.textSecondary)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 7).fill(active ? Theme.selected : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var recents: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !model.conversations.isEmpty {
                SectionLabel("Recientes").padding(.horizontal, 10).padding(.bottom, 4)
            }
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(model.conversations) { conversation in
                        let selected = model.section == .chat && model.currentConversationId == conversation.id
                        let hovered = hoveredConversationId == conversation.id
                        Button { model.openConversation(conversation) } label: {
                            HStack(spacing: 8) {
                                if let agent = model.agent(id: conversation.agentId), !agent.isDefault { AgentAvatar(agent: agent, size: 14) }
                                Text(conversation.title).lineLimit(1).truncationMode(.tail)
                                Spacer(minLength: 4)
                                // El hueco de la fecha deja sitio a la papelera al pasar el ratón.
                                Text(Self.age(conversation.updatedAt)).font(Theme.mono(10)).foregroundStyle(Theme.muted)
                                    .opacity(hovered ? 0 : 1)
                            }
                            .font(.system(size: 12.5))
                            .foregroundStyle(selected ? Theme.text : Theme.textSecondary)
                            .padding(.horizontal, 10)
                            .frame(height: 30)
                            .background(RoundedRectangle(cornerRadius: 7).fill(selected || hovered ? Theme.selected : .clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .overlay(alignment: .trailing) {
                            if hovered && canDelete(conversation) {
                                Button { conversationToDelete = conversation } label: {
                                    Image(systemName: "trash").font(.system(size: 11)).foregroundStyle(Theme.muted)
                                        .frame(width: 26, height: 26).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain).padding(.trailing, 4)
                                .help("Borrar conversación").accessibilityLabel("Borrar conversación")
                            }
                        }
                        .onHover { inside in
                            if inside { hoveredConversationId = conversation.id }
                            else if hoveredConversationId == conversation.id { hoveredConversationId = nil }
                        }
                        .contextMenu {
                            Button("Borrar conversación…", role: .destructive) { conversationToDelete = conversation }
                                .disabled(!canDelete(conversation))
                        }
                    }
                }
            }
            .scrollIndicators(.never)
        }
        .confirmationDialog("¿Borrar «\(conversationToDelete?.title ?? "")»?",
                            isPresented: Binding(get: { conversationToDelete != nil }, set: { if !$0 { conversationToDelete = nil } }),
                            presenting: conversationToDelete) { conversation in
            Button("Borrar conversación", role: .destructive) { model.deleteConversation(conversation) }
        } message: { _ in
            Text("Se borran todos sus mensajes. Esto no se puede deshacer.")
        }
    }

    /// La conversación en la que el agente está respondiendo no se puede borrar.
    private func canDelete(_ conversation: Conversation) -> Bool {
        !(model.isRunning && model.currentConversationId == conversation.id)
    }

    /// "ahora", "12m", "3h", "2d", "5sem".
    static func age(_ date: Date, now: Date = Date()) -> String {
        let minutes = Int(now.timeIntervalSince(date) / 60)
        switch minutes {
        case ..<1: return "ahora"
        case ..<60: return "\(minutes)m"
        case ..<(60 * 24): return "\(minutes / 60)h"
        case ..<(60 * 24 * 7): return "\(minutes / (60 * 24))d"
        default: return "\(minutes / (60 * 24 * 7))sem"
        }
    }
}

struct NewBrandSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var industry = ""
    @State private var instagram = true
    @State private var linkedin = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Nueva marca").font(.system(size: 16, weight: .semibold))
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("Nombre")
                TextField("Café Sol", text: $name).textFieldStyle(.plain).padding(.horizontal, 10).frame(height: 34).panel(radius: 8)
            }
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("Rubro")
                TextField("Cafetería de especialidad", text: $industry).textFieldStyle(.plain).padding(.horizontal, 10).frame(height: 34).panel(radius: 8)
            }
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("Redes")
                Toggle("Instagram", isOn: $instagram).toggleStyle(.checkbox)
                Toggle("LinkedIn", isOn: $linkedin).toggleStyle(.checkbox)
            }
            // La alerta de la ventana no se ve mientras hay una hoja abierta: el error va aquí.
            if let error = model.errorMessage { Text(error).font(.system(size: 12)).foregroundStyle(Theme.danger) }
            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }.buttonStyle(OutlineButtonStyle())
                Button("Crear marca") {
                    model.errorMessage = nil
                    let networks = [instagram ? Network.instagram : nil, linkedin ? Network.linkedin : nil].compactMap { $0 }
                    model.createBrand(name: name, industry: industry, networks: networks)
                    if model.errorMessage == nil { dismiss() }
                }
                .buttonStyle(AccentButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!instagram && !linkedin)
            }
        }
        .padding(22)
        .frame(width: 380)
        .background(Theme.sidebar)
        .onAppear { model.errorMessage = nil }
        .onDisappear { model.errorMessage = nil }
    }
}

/// Borrar una marca pide escribir su nombre: se lleva sus posts, imágenes y guía.
struct DeleteBrandSheet: View {
    let model: AppModel
    let brand: Brand
    @Environment(\.dismiss) private var dismiss
    @State private var typed = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("¿Borrar \(brand.name)?").font(.system(size: 16, weight: .semibold))
            Text("Se borran sus posts, sus imágenes y su guía de marca. Las tareas y conversaciones se quedan, sin marca. Esto no se puede deshacer.")
                .font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Text("Escribe **\(brand.name)** para confirmar").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                TextField(brand.name, text: $typed).textFieldStyle(.plain).padding(.horizontal, 10).frame(height: 34).panel(radius: 8)
                    .onSubmit(delete)
            }
            // La alerta de la ventana no se ve mientras hay una hoja abierta: el error va aquí.
            if let error = model.errorMessage { Text(error).font(.system(size: 12)).foregroundStyle(Theme.danger) }
            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }.buttonStyle(OutlineButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Borrar marca", action: delete)
                    .buttonStyle(AccentButtonStyle(destructive: true))
                    .disabled(!brand.deletionConfirmed(by: typed))
            }
        }
        .padding(22)
        .frame(width: 400)
        .background(Theme.sidebar)
        .onAppear { model.errorMessage = nil }
        .onDisappear { model.errorMessage = nil }
    }

    private func delete() {
        guard brand.deletionConfirmed(by: typed) else { return }
        if model.deleteBrand(brand) { dismiss() }
    }
}
