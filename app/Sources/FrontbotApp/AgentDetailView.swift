import SwiftUI
import FrontbotCore

/// Página de un agente: instrucciones y configuración (modelo, navegador).
struct AgentDetailView: View {
    @Bindable var model: AppModel
    let agent: Agent
    @State private var editing = false
    @State private var draft: AgentDraft
    @State private var confirmingDelete = false

    init(model: AppModel, agent: Agent) {
        self.model = model
        self.agent = agent
        _draft = State(initialValue: AgentDraft(agent: agent))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if agent.status == .draft { draftBanner }
                    instructions
                    settings
                    skillsSection
                    memory
                }
                .frame(maxWidth: 820, alignment: .leading)
                .padding(.horizontal, 28).padding(.vertical, 22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Theme.background)
        .confirmationDialog("¿Borrar \(agent.name)?", isPresented: $confirmingDelete) {
            Button("Borrar agente y sus conversaciones", role: .destructive) { model.deleteAgent(agent.id) }
        } message: {
            Text("Se borran también sus conversaciones. Esto no se puede deshacer.")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            AgentAvatar(agent: agent, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(agent.name).font(.system(size: 22, weight: .semibold))
                    if agent.status == .draft {
                        Text("Borrador").font(.system(size: 11)).foregroundStyle(Theme.draft)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(Theme.draft.opacity(0.12)))
                    }
                }
                if !agent.description.isEmpty { Text(agent.description).foregroundStyle(Theme.muted) }
            }
            Spacer()
            if !agent.isDefault {
                Button { confirmingDelete = true } label: { Image(systemName: "trash") }
                    .buttonStyle(OutlineButtonStyle()).help("Borrar agente").accessibilityLabel("Borrar agente")
            }
            Button("Hablar con \(agent.name)") { model.newConversation(agentId: agent.id) }
                .buttonStyle(OutlineButtonStyle(prominent: true))
                .disabled(agent.status != .active || model.isRunning)
        }
        .padding(.horizontal, 28).padding(.top, 22).padding(.bottom, 18)
        .overlay(alignment: .bottom) { Theme.border.frame(height: 1) }
    }

    private var draftBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles").foregroundStyle(Theme.draft)
            VStack(alignment: .leading, spacing: 2) {
                Text("Frontbot propuso este agente").font(.system(size: 13, weight: .medium))
                Text("Revisa sus instrucciones y actívalo para poder hablar con él.").font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            Spacer()
            Button("Descartar") { model.deleteAgent(agent.id) }.buttonStyle(OutlineButtonStyle())
            Button("Activar") { model.activateAgent(agent.id) }.buttonStyle(AccentButtonStyle())
        }
        .padding(14).panel(radius: 10, fill: Theme.draft.opacity(0.06))
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Instrucciones").font(.system(size: 14, weight: .semibold))
                Spacer()
                if editing {
                    Button("Cancelar") { draft = AgentDraft(agent: agent); editing = false }.buttonStyle(OutlineButtonStyle())
                    Button("Guardar") { if model.updateAgent(agent.id, draft: draft) { editing = false } }
                        .buttonStyle(AccentButtonStyle()).keyboardShortcut(.defaultAction)
                } else {
                    Button("Editar") { draft = AgentDraft(agent: agent); editing = true }.buttonStyle(OutlineButtonStyle(prominent: true))
                }
            }
            if editing {
                AgentFields(draft: $draft)
            } else {
                GuideText(markdown: agent.instructions)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 22).padding(.vertical, 18)
                    .panel(radius: 12, fill: Theme.sidebar)
            }
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Configuración").font(.system(size: 14, weight: .semibold))
            HStack(spacing: 12) {
                SectionLabel("Modelo")
                Picker("Modelo", selection: Binding(get: { agent.model }, set: { value in save { $0.model = value } })) {
                    ForEach(AgentModel.all, id: \.id) { Text($0.label).tag($0.id) }
                }
                .labelsHidden().fixedSize()
                Spacer()
            }
            Toggle(isOn: Binding(get: { agent.browser }, set: { value in save { $0.browser = value } })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Usar mi Chrome").font(.system(size: 13, weight: .medium))
                    Text("Navega con tus sesiones (extensión Claude in Chrome). Puede hacer clic y rellenar formularios; en redes sociales solo lee y nunca publica.")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch).controlSize(.small)
            if agent.trading {
                HStack(spacing: 8) {
                    Image(systemName: "chart.line.uptrend.xyaxis").foregroundStyle(Theme.muted)
                    Text("Trading en Hyperliquid: se configura cuando llegue la conexión con el exchange.")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading).panel(radius: 12)
    }

    private var skillsSection: some View {
        let assigned = model.skillsAssigned(to: agent.id)
        let available = model.skills.filter { s in !assigned.contains { $0.id == s.id } }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Skills").font(.system(size: 14, weight: .semibold))
                Text("\(assigned.filter { $0.status == .active }.count) activos").font(Theme.mono()).foregroundStyle(Theme.muted)
                Spacer()
                Menu("Asignar") {
                    if available.isEmpty { Text("No hay más skills en la biblioteca") }
                    ForEach(available) { skill in Button(skill.name) { model.setSkill(skill, assigned: true, to: agent.id) } }
                }
                .menuStyle(.button).buttonStyle(OutlineButtonStyle()).fixedSize()
                Button("Biblioteca") { model.section = .skills }.buttonStyle(OutlineButtonStyle())
            }
            if assigned.isEmpty {
                Text("Sin skills. Asigna alguno de la biblioteca o pídele a \(agent.name) que cree uno a partir de su investigación.")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            ForEach(assigned) { skill in
                HStack(spacing: 10) {
                    Text(skill.name).font(Theme.mono(12))
                    SkillStatusPill(status: skill.status)
                    if skill.hasScripts { Text("⚙").font(.system(size: 11)).foregroundStyle(Theme.muted).help("Trae scripts") }
                    Text(skill.description).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
                    Spacer()
                    if skill.status == .draft { Button("Activar") { model.activateSkill(skill) }.buttonStyle(OutlineButtonStyle(prominent: true)) }
                    Button { model.setSkill(skill, assigned: false, to: agent.id) } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).foregroundStyle(Theme.muted).help("Quitar de este agente")
                }
                .padding(.vertical, 4)
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading).panel(radius: 12)
    }

    private var memory: some View {
        let notes = model.memories(agentId: agent.id)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Memoria").font(.system(size: 14, weight: .semibold))
                Text("\(notes.count) / \(AppDatabase.memoryLimit)").font(Theme.mono()).foregroundStyle(Theme.muted)
                Spacer()
                if !notes.isEmpty {
                    Button("Vaciar") { model.clearMemory(agentId: agent.id) }.buttonStyle(OutlineButtonStyle()).foregroundStyle(Theme.danger)
                }
            }
            if notes.isEmpty {
                Text("\(agent.name) aún no recuerda nada. Guarda notas cuando aprende algo y resume cada conversación al cerrarla.")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            ForEach(notes) { note in
                HStack(alignment: .top, spacing: 10) {
                    Text(note.createdAt.formatted(.dateTime.day().month(.abbreviated))).font(Theme.mono(10)).foregroundStyle(Theme.muted)
                        .frame(width: 52, alignment: .leading)
                    Text(note.text).font(.system(size: 13)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    Button { if let id = note.id { model.forgetMemory(agentId: agent.id, memoryId: id) } } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).foregroundStyle(Theme.muted).help("Olvidar").accessibilityLabel("Olvidar nota")
                }
                .padding(.vertical, 6)
                .overlay(alignment: .bottom) { Theme.border.frame(height: 1) }
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading).panel(radius: 12)
    }

    /// Guarda un cambio puntual sobre la versión actual del agente.
    private func save(_ change: (inout AgentDraft) -> Void) {
        var d = AgentDraft(agent: agent)
        change(&d)
        model.updateAgent(agent.id, draft: d)
    }
}

/// Campos editables de un agente (formulario de creación y edición).
struct AgentFields: View {
    @Binding var draft: AgentDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                field("Nombre") { TextField("Analista de mercado", text: $draft.name) }
                field("Icono (SF Symbol)") { TextField("person.crop.circle", text: $draft.icon) }.frame(width: 200)
            }
            field("Descripción") { TextField("Para qué sirve este agente", text: $draft.description) }
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("Instrucciones")
                TextEditor(text: $draft.instructions)
                    .font(.system(size: 13)).scrollContentBackground(.hidden)
                    .padding(10).frame(minHeight: 220).panel(radius: 10)
            }
        }
    }

    private func field(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(label)
            content().textFieldStyle(.plain).padding(.horizontal, 10).frame(height: 32).panel(radius: 8)
        }
    }
}

/// Crear un agente: en blanco o desde una plantilla.
struct NewAgentSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var templateId: String?
    @State private var draft = AgentDraft(name: "", instructions: "")

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Nuevo agente").font(.system(size: 16, weight: .semibold))
            HStack(spacing: 8) {
                templateButton(nil, title: "En blanco", icon: "plus", summary: "Defines tú su rol y sus reglas.")
                ForEach(AgentTemplate.all) { t in
                    templateButton(t.id, title: t.draft.name, icon: t.draft.icon, summary: t.summary)
                }
            }
            AgentFields(draft: $draft)
            HStack(spacing: 12) {
                SectionLabel("Modelo")
                Picker("Modelo", selection: $draft.model) {
                    ForEach(AgentModel.all, id: \.id) { Text($0.label).tag($0.id) }
                }
                .labelsHidden().fixedSize()
                Toggle("Usar mi Chrome", isOn: $draft.browser).toggleStyle(.checkbox)
                Spacer()
            }
            if let error = model.errorMessage { Text(error).font(.system(size: 12)).foregroundStyle(Theme.danger) }
            HStack {
                Text("También puedes pedirle a Frontbot que te proponga uno.").font(.system(size: 12)).foregroundStyle(Theme.muted)
                Spacer()
                Button("Cancelar") { dismiss() }.buttonStyle(OutlineButtonStyle())
                Button("Crear agente") {
                    model.errorMessage = nil
                    if model.createAgent(draft) != nil { dismiss() }
                }
                .buttonStyle(AccentButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 640)
        .background(Theme.sidebar)
        .onAppear { model.errorMessage = nil }
        .onDisappear { model.errorMessage = nil }
    }

    private func templateButton(_ id: String?, title: String, icon: String, summary: String) -> some View {
        Button {
            templateId = id
            draft = AgentTemplate.all.first { $0.id == id }?.draft ?? AgentDraft(name: "", instructions: "")
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) { Image(systemName: icon); Text(title).font(.system(size: 13, weight: .medium)) }
                Text(summary).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(3).multilineTextAlignment(.leading)
            }
            .padding(12).frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 10).fill(templateId == id ? Theme.selected : Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(templateId == id ? Theme.accent : Theme.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
