import SwiftUI
import FrontbotCore

/// Revisión de una propuesta de skill: evidencia, comentario opcional y decisión.
struct ProposalReviewSheet: View {
    let model: AppModel
    let proposal: SkillProposal
    @Environment(\.dismiss) private var dismiss
    @State private var comment = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Graduar «\(proposal.skillName)»").font(.system(size: 16, weight: .semibold))
            ScrollView {
                MarkdownView(text: proposal.evidenceSummary)
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 140, maxHeight: 320).panel(radius: 10)
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("Comentario (opcional)")
                TextField("Por qué lo rechazas o qué cambiarías", text: $comment)
                    .textFieldStyle(.plain).padding(.horizontal, 10).frame(height: 32).panel(radius: 8)
            }
            if let error = model.errorMessage { Text(error).font(.system(size: 12)).foregroundStyle(Theme.danger) }
            HStack {
                Button("Cerrar") { dismiss() }.buttonStyle(OutlineButtonStyle())
                Spacer()
                Button("Rechazar") { decide { model.lab.reject(proposal, comment: trimmedComment) } }
                    .buttonStyle(OutlineButtonStyle()).foregroundStyle(Theme.danger)
                Button("Aprobar") { decide { model.lab.approve(proposal) } }
                    .buttonStyle(AccentButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22).frame(width: 640)
        .background(Theme.sidebar)
        .onAppear { model.errorMessage = nil }
        .onDisappear { model.errorMessage = nil }
    }

    private var trimmedComment: String? {
        let t = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// Los errores quedan en `model.errorMessage`: si no hay, la propuesta se resolvió y la hoja se cierra.
    private func decide(_ action: () -> Void) {
        model.errorMessage = nil
        action()
        if model.errorMessage == nil { dismiss() }
    }
}
