import SwiftUI
import FrontbotCore

/// El agente pide salir de su carpeta: escribir fuera de ella o ejecutar un comando sin sandbox.
struct WorkdirApprovalSheet: View {
    let model: AppModel
    let approval: WorkdirApproval
    private static let previewLimit = 20_000

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch approval.kind {
            case .write: writeBody
            case .unsandboxed: unsandboxedBody
            }
        }
        .padding(22).frame(width: 560).background(Theme.sidebar)
        .interactiveDismissDisabled()
    }

    private var writeBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "doc.badge.plus").foregroundStyle(Theme.accent)
                Text("¿Escribir fuera de la carpeta?").font(.system(size: 15, weight: .semibold))
            }
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("Archivo")
                Text(AgentFoldersSection.display(approval.path ?? "")).font(Theme.mono(12)).textSelection(.enabled)
                SectionLabel("Contenido").padding(.top, 6)
                ScrollView {
                    contentPreview.font(Theme.mono(11)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }
                .frame(maxHeight: 320).panel(radius: 8, fill: Theme.raised)
            }
            HStack {
                Spacer()
                Button("Denegar") { model.answerWorkdir(.deny) }.buttonStyle(OutlineButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Permitir en esta conversación") { model.answerWorkdir(.conversation) }.buttonStyle(OutlineButtonStyle(prominent: true))
                Button("Permitir una vez") { model.answerWorkdir(.once) }.buttonStyle(AccentButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
    }

    /// `Edit`: quitado/añadido; `Write`: el contenido entero.
    @ViewBuilder private var contentPreview: some View {
        if let old = approval.oldString, let new = approval.newString {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(LineDiff.diff(old: old, new: new).prefix(400).enumerated()), id: \.offset) { _, line in
                    switch line {
                    case .same(let t): Text("  " + t).foregroundStyle(Theme.muted)
                    case .added(let t): Text("+ " + t).foregroundStyle(Theme.approved)
                    case .removed(let t): Text("- " + t).foregroundStyle(Theme.danger)
                    }
                }
            }
        } else {
            Text(preview)
        }
    }

    private var preview: String {
        let content = approval.content ?? ""
        guard content.count > Self.previewLimit else { return content.isEmpty ? "(vacío)" : content }
        return String(content.prefix(Self.previewLimit)) + "\n… (\(content.count - Self.previewLimit) caracteres más)"
    }

    private var unsandboxedBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.shield").foregroundStyle(Theme.danger)
                Text("¿Ejecutar sin la protección de la carpeta?").font(.system(size: 15, weight: .semibold))
            }
            ScrollView {
                Text(approval.command ?? "").font(Theme.mono(12)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }
            .frame(maxHeight: 220).panel(radius: 8, fill: Theme.raised)
            Label("Este comando podrá leer y escribir en todo tu Mac.", systemImage: "exclamationmark.triangle")
                .font(.system(size: 12)).foregroundStyle(Theme.danger)
            HStack {
                Spacer()
                Button("Denegar") { model.answerWorkdir(.deny) }.buttonStyle(OutlineButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Permitir una vez") { model.answerWorkdir(.once) }.buttonStyle(AccentButtonStyle(destructive: true))
            }
        }
    }
}
