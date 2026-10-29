import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FrontbotCore

/// Biblioteca común de skills: lista a la izquierda, detalle a la derecha.
struct SkillsView: View {
    @Bindable var model: AppModel
    @State private var selectedId: String?
    @State private var importing = false
    @State private var creating = false

    private var selected: Skill? { model.skills.first { $0.id == selectedId } ?? model.skills.first }

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(alignment: .top, spacing: 0) {
                list.frame(width: 320)
                Theme.border.frame(width: 1)
                if let skill = selected {
                    SkillDetail(model: model, skill: skill).id(skill.id)
                } else {
                    emptyState
                }
            }
        }
        .background(Theme.background)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.folder, .zip]) { result in
            guard case .success(let url) = result else { return }
            let ok = url.startAccessingSecurityScopedResource()
            defer { if ok { url.stopAccessingSecurityScopedResource() } }
            if let skill = model.importSkill(from: url) { selectedId = skill.id }
        }
        .sheet(isPresented: $creating) { NewSkillSheet(model: model) { selectedId = $0.id } }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Skills").font(.system(size: 17, weight: .semibold))
            Text("\(model.skills.count) · estándar de Anthropic (SKILL.md)").font(Theme.mono()).foregroundStyle(Theme.muted)
            Spacer()
            Button("Importar…") { importing = true }.buttonStyle(OutlineButtonStyle()).help("Carpeta con SKILL.md o .zip")
            Button("Nuevo skill") { creating = true }.buttonStyle(OutlineButtonStyle(prominent: true))
        }
        .padding(.horizontal, 20).frame(height: 56)
        .overlay(alignment: .bottom) { Theme.border.frame(height: 1) }
    }

    private var list: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(model.skills) { skill in
                    let isSelected = selected?.id == skill.id
                    Button { selectedId = skill.id } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(skill.name).font(Theme.mono(12)).foregroundStyle(Theme.text).lineLimit(1)
                                Spacer()
                                if skill.hasScripts { Text("⚙ scripts").font(Theme.mono(10)).foregroundStyle(Theme.muted) }
                                SkillStatusPill(status: skill.status)
                            }
                            Text(skill.description).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(2)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(isSelected ? Theme.selected : .clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Aún no hay skills").font(.system(size: 18, weight: .semibold))
            Text("Importa una carpeta con SKILL.md (o un .zip), escribe uno nuevo, o pídele a un agente que convierta su investigación en un skill: quedará aquí como borrador para que lo revises.")
                .foregroundStyle(Theme.muted).lineSpacing(3)
        }
        .padding(28).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct SkillStatusPill: View {
    let status: SkillStatus
    var body: some View {
        let color = status == .draft ? Theme.draft : Theme.approved
        (status == .draft ? Text("Borrador") : Text("Activo")).font(.system(size: 10)).foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
    }
}

private struct SkillDetail: View {
    @Bindable var model: AppModel
    let skill: Skill
    @State private var editing = false
    @State private var text = ""
    @State private var confirmingDelete = false

    private var source: String {
        switch skill.source {
        case .imported: String(localized: "importado")
        case .user: String(localized: "escrito por ti")
        case .agent: String(localized: "creado por \(model.agent(id: skill.createdByAgentId)?.name ?? String(localized: "un agente"))")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text(skill.name).font(Theme.mono(15))
                SkillStatusPill(status: skill.status)
                Text(source).font(.system(size: 12)).foregroundStyle(Theme.muted)
                Spacer()
                Button { NSWorkspace.shared.activateFileViewerSelecting([model.skillDirectory(skill)]) } label: { Image(systemName: "folder") }
                    .buttonStyle(OutlineButtonStyle()).help("Mostrar en Finder")
                Button { confirmingDelete = true } label: { Image(systemName: "trash") }
                    .buttonStyle(OutlineButtonStyle()).help(skill.status == .draft ? Text("Descartar") : Text("Borrar"))
                if editing {
                    Button("Cancelar") { editing = false }.buttonStyle(OutlineButtonStyle())
                    Button("Guardar") { if model.saveSkillManifest(skill, text: text) { editing = false } }
                        .buttonStyle(AccentButtonStyle()).keyboardShortcut(.defaultAction)
                } else {
                    Button("Editar") { text = model.skillManifest(skill); editing = true }.buttonStyle(OutlineButtonStyle(prominent: true))
                    if skill.status == .draft {
                        Button("Activar") { model.activateSkill(skill) }.buttonStyle(AccentButtonStyle())
                    }
                }
            }
            .padding(.horizontal, 22).padding(.vertical, 14)
            .overlay(alignment: .bottom) { Theme.border.frame(height: 1) }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if skill.status == .draft {
                        Text("Borrador: no se carga en ningún agente hasta que lo actives. Revisa que el contenido sea correcto.")
                            .font(.system(size: 12)).foregroundStyle(Theme.draft)
                            .padding(12).frame(maxWidth: .infinity, alignment: .leading).panel(radius: 10, fill: Theme.draft.opacity(0.06))
                    }
                    if skill.hasScripts {
                        Text("⚙ Trae scripts: los agentes solo pueden ejecutarlos en una sandbox sin red y con tu permiso cada vez.")
                            .font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }
                    if editing {
                        TextEditor(text: $text)
                            .font(.system(size: 12, design: .monospaced)).scrollContentBackground(.hidden)
                            .padding(10).frame(minHeight: 420).panel(radius: 10)
                    } else {
                        GuideText(markdown: model.skillManifest(skill))
                            .padding(18).frame(maxWidth: .infinity, alignment: .leading).panel(radius: 10, fill: Theme.sidebar)
                    }
                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            SectionLabel("Archivos")
                            ForEach(model.skillFiles(skill), id: \.self) { Text($0).font(Theme.mono(11)).foregroundStyle(Theme.textSecondary) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        VStack(alignment: .leading, spacing: 6) {
                            SectionLabel("Agentes")
                            ForEach(model.agents) { agent in
                                Toggle(isOn: Binding(get: { model.agentsUsing(skill).contains { $0.id == agent.id } },
                                                     set: { model.setSkill(skill, assigned: $0, to: agent.id) })) {
                                    HStack(spacing: 6) { AgentAvatar(agent: agent, size: 14); Text(agent.name).font(.system(size: 12)) }
                                }
                                .toggleStyle(.checkbox)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(14).panel(radius: 10)
                    SkillHistory(model: model, skill: skill)
                    if let error = model.errorMessage { Text(error).font(.system(size: 12)).foregroundStyle(Theme.danger) }
                }
                .padding(22)
            }
        }
        .confirmationDialog("¿Borrar \(skill.name)?", isPresented: $confirmingDelete) {
            Button("Borrar skill", role: .destructive) { model.deleteSkill(skill) }
        } message: {
            Text("Se borra su carpeta y se quita de todos los agentes.")
        }
    }
}

/// Versiones anteriores del skill; volver a una guarda antes la actual como una versión más.
private struct SkillHistory: View {
    let model: AppModel
    let skill: Skill
    @State private var target: SkillVersion?

    var body: some View {
        let past = model.lab.skillVersions(skillId: skill.id).sorted { $0.number > $1.number }
        if !past.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Historial")
                Text("v\(skill.version) · actual").font(Theme.mono(11)).foregroundStyle(Theme.textSecondary)
                ForEach(past) { v in
                    HStack(spacing: 8) {
                        Text(label(v)).font(Theme.mono(11)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                        Spacer()
                        Button("Volver a esta versión") { target = v }.buttonStyle(OutlineButtonStyle())
                    }
                }
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading).panel(radius: 10)
            .confirmationDialog("¿Volver a la v\(target?.number ?? 0)?", isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } }),
                                presenting: target) { v in
                Button("Volver a la v\(v.number)", role: .destructive) { model.lab.revertSkill(skill.id, to: v.number) }
            } message: { _ in
                Text("La versión actual queda guardada en el historial.")
            }
        }
    }

    private func label(_ v: SkillVersion) -> String {
        let date = v.createdAt.formatted(.dateTime.day().month(.abbreviated).locale(Locale(identifier: Bundle.main.preferredLocalizations.first ?? "es")))
        let origin = v.proposalId == nil ? String(localized: "antes de un cambio tuyo")
            : String(localized: "antes de la propuesta de \(model.lab.proposalAgentName(v.proposalId) ?? String(localized: "un agente"))")
        return "v\(v.number) · \(date) · \(origin)"
    }
}

struct NewSkillSheet: View {
    let model: AppModel
    var onCreate: (Skill) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var description = ""
    @State private var body_ = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Nuevo skill").font(.system(size: 16, weight: .semibold))
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("Nombre (kebab-case)")
                TextField("estrategia-ruptura", text: $name).font(Theme.mono(13)).textFieldStyle(.plain)
                    .padding(.horizontal, 10).frame(height: 32).panel(radius: 8)
            }
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("Descripción: qué hace y cuándo usarlo")
                TextField("Opera rupturas de rango con retesteo. Úsalo cuando…", text: $description).textFieldStyle(.plain)
                    .padding(.horizontal, 10).frame(height: 32).panel(radius: 8)
            }
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("Contenido (markdown)")
                TextEditor(text: $body_).font(.system(size: 13)).scrollContentBackground(.hidden)
                    .padding(10).frame(minHeight: 240).panel(radius: 10)
            }
            if let error = model.errorMessage { Text(error).font(.system(size: 12)).foregroundStyle(Theme.danger) }
            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }.buttonStyle(OutlineButtonStyle())
                Button("Crear skill") {
                    model.errorMessage = nil
                    if let skill = model.createSkill(name: name, description: description, body: body_) { onCreate(skill); dismiss() }
                }
                .buttonStyle(AccentButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22).frame(width: 600).background(Theme.sidebar)
        .onAppear { model.errorMessage = nil }
        .onDisappear { model.errorMessage = nil }
    }
}

/// Un agente pide ejecutar un script de un skill: el usuario decide.
struct ScriptApprovalSheet: View {
    let model: AppModel
    let request: ScriptRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "terminal").foregroundStyle(Theme.accent)
                Text("\(request.agentName) quiere ejecutar un script").font(.system(size: 15, weight: .semibold))
            }
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("Skill")
                Text(request.skillName).font(Theme.mono(12))
                SectionLabel("Comando").padding(.top, 6)
                Text(request.command).font(Theme.mono(12)).textSelection(.enabled)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading).panel(radius: 8, fill: Theme.raised)
            }
            Text("Se ejecuta en una sandbox: sin red, sin acceso a tu carpeta personal y escribiendo solo en la carpeta del skill. Máximo 60 segundos.")
                .font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Denegar") { model.answerScript(false) }.buttonStyle(OutlineButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Permitir") { model.answerScript(true) }.buttonStyle(AccentButtonStyle())
            }
        }
        .padding(22).frame(width: 460).background(Theme.sidebar)
        .interactiveDismissDisabled()
    }
}
