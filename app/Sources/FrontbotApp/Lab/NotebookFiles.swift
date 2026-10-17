import SwiftUI
import FrontbotCore

/// "Archivos del tema": lista de solo lectura con vista previa al tocar uno.
struct NotebookFiles: View {
    let model: AppModel
    let agent: Agent
    let topic: LabTopic
    @State private var dir = ""
    @State private var selected: String?

    private static let codeLanguages: Set<String> = ["py", "js", "sh", "csv"]
    private static let previewLines = 60

    var body: some View {
        let workspace = model.lab.workspace(agentId: agent.id, topicId: topic.id)
        let items = listing(workspace)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Archivos del tema").font(.system(size: 14, weight: .semibold))
                if !dir.isEmpty {
                    Button { dir = parent(of: dir); selected = nil } label: { Label("Subir", systemImage: "arrow.up") }
                        .buttonStyle(OutlineButtonStyle())
                    Text(dir).font(Theme.mono(11)).foregroundStyle(Theme.muted)
                }
            }
            if items.isEmpty { Text("Aún no hay archivos.").font(.system(size: 12)).foregroundStyle(Theme.muted) }
            ForEach(items, id: \.self) { path in
                Button {
                    if path.hasSuffix("/") { dir = String(path.dropLast()); selected = nil } else { selected = selected == path ? nil : path }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: path.hasSuffix("/") ? "folder" : "doc.text").foregroundStyle(Theme.muted)
                        Text(path).font(Theme.mono(12))
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if selected == path { preview(path, workspace) }
            }
        }
    }

    private func listing(_ workspace: LabWorkspace) -> [String] {
        let all = (try? workspace.list(dir.isEmpty ? nil : dir)) ?? []
        // En la raíz `list` añade accesos a shared/, skills y datasets que no son del tema.
        return dir.isEmpty ? all.filter { $0 != "shared/" && !$0.hasPrefix("skill:") && !$0.hasPrefix("dataset:") } : all
    }

    private func parent(of path: String) -> String {
        let parts = path.split(separator: "/").dropLast()
        return parts.joined(separator: "/")
    }

    @ViewBuilder
    private func preview(_ path: String, _ workspace: LabWorkspace) -> some View {
        switch Result(catching: { try workspace.read(path) }) {
        case .failure(let error):
            Text((error as? ValidationError)?.message ?? error.localizedDescription).font(.system(size: 12)).foregroundStyle(Theme.danger)
        case .success(let file):
            let ext = (path as NSString).pathExtension.lowercased()
            let lines = file.text.split(separator: "\n", omittingEmptySubsequences: false)
            let clipped = file.truncated || lines.count > Self.previewLines
            let shown = lines.prefix(Self.previewLines).joined(separator: "\n")
            VStack(alignment: .leading, spacing: 6) {
                if ext == "md" {
                    MarkdownView(text: shown)
                } else if Self.codeLanguages.contains(ext) {
                    CodeBlockView(language: ext, code: shown)
                } else {
                    Text(shown).font(Theme.mono(12)).textSelection(.enabled)
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading).panel(radius: 8)
                }
                if clipped { Text("Vista recortada.").font(.system(size: 11)).foregroundStyle(Theme.muted) }
            }
        }
    }
}
