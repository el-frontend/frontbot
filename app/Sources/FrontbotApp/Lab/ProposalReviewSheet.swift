import SwiftUI
import FrontbotCore

/// Revisión de una propuesta de skill: evidencia, diff por archivo, comentario opcional y decisión.
struct ProposalReviewSheet: View {
    let model: AppModel
    let proposal: SkillProposal
    @Environment(\.dismiss) private var dismiss
    @State private var comment = ""
    @State private var stale = false
    @State private var notebook: LabTopic?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Graduar «\(proposal.skillName)»").font(.system(size: 16, weight: .semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    MarkdownView(text: proposal.evidenceSummary)
                    if let topic = model.lab.topic(id: proposal.topicId), model.agent(id: proposal.agentId) != nil {
                        Button("Ver cuaderno") { notebook = topic }
                            .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.accent)
                    }
                    SectionLabel("Archivos")
                    ForEach(model.lab.proposalFiles(proposal), id: \.path) { file in
                        ProposalFileDiff(kind: proposal.kind, path: file.path, old: file.old, new: file.new)
                    }
                }
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 200, maxHeight: 420).panel(radius: 10)
            if stale {
                Text(model.errorMessage ?? "El skill cambió desde que se propuso.")
                    .font(.system(size: 12)).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("Comentario (opcional)")
                TextField("Por qué lo rechazas o qué cambiarías", text: $comment)
                    .textFieldStyle(.plain).padding(.horizontal, 10).frame(height: 32).panel(radius: 8)
            }
            if !stale, let error = model.errorMessage { Text(error).font(.system(size: 12)).foregroundStyle(Theme.danger) }
            HStack {
                Button("Cerrar") { dismiss() }.buttonStyle(OutlineButtonStyle())
                Spacer()
                Button("Rechazar") { decide { model.lab.reject(proposal, comment: trimmedComment) } }
                    .buttonStyle(OutlineButtonStyle()).foregroundStyle(Theme.danger)
                if !stale {
                    Button("Aprobar") { decide { model.lab.approve(proposal) } }
                        .buttonStyle(AccentButtonStyle()).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(22).frame(width: 640)
        .background(Theme.sidebar)
        .onAppear { model.errorMessage = nil }
        .onDisappear { model.errorMessage = nil }
        .sheet(item: $notebook) { topic in
            if let agent = model.agent(id: proposal.agentId) { NotebookView(model: model, agent: agent, topic: topic) }
        }
    }

    private var trimmedComment: String? {
        let t = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// Los errores quedan en `model.errorMessage`: si no hay, la propuesta se resolvió y la hoja se cierra.
    /// Si el skill cambió, la propuesta ya no se puede aprobar: solo queda rechazarla.
    private func decide(_ action: () -> Void) {
        model.errorMessage = nil
        action()
        if let error = model.errorMessage {
            if error.contains("cambió") { stale = true }
        } else {
            dismiss()
        }
    }
}

/// Un archivo de la propuesta: diff contra el actual (`update`) o contenido completo (`new`).
private struct ProposalFileDiff: View {
    let kind: SkillProposalKind
    let path: String
    let old: String?
    let new: String
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in row(line) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 8) {
                Text(path).font(Theme.mono(12))
                if old == nil { LabPill(text: "nuevo", color: Theme.approved) }
                else if old == new { LabPill(text: "sin cambios") }
            }
        }
    }

    private var lines: [DiffLine] {
        guard let old, kind == .update else { return new.components(separatedBy: "\n").map { DiffLine.same($0) } }
        return LineDiff.diff(old: old, new: new)
    }

    @ViewBuilder private func row(_ line: DiffLine) -> some View {
        switch line {
        case .added(let t): Text("+ " + t).foregroundStyle(Theme.text).modifier(DiffRow(fill: Theme.approved.opacity(0.12)))
        case .removed(let t): Text("- " + t).foregroundStyle(Theme.text).modifier(DiffRow(fill: Theme.danger.opacity(0.12)))
        case .same(let t): Text("  " + t).foregroundStyle(Theme.muted).modifier(DiffRow(fill: .clear))
        }
    }
}

private struct DiffRow: ViewModifier {
    let fill: Color
    func body(content: Content) -> some View {
        content.font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading).background(fill)
    }
}
