import SwiftUI
import AppKit
import FrontbotCore

/// Chip de la barra del composer: carpeta de trabajo y carpetas de lectura de la conversación.
struct WorkdirChip: View {
    let model: AppModel

    var body: some View {
        Menu {
            Button("Elegir carpeta de trabajo…") { if let url = Self.pickFolder("Elegir carpeta de trabajo") { model.chooseWorkdir(url) } }
            Button("Añadir carpeta de lectura…") { if let url = Self.pickFolder("Añadir carpeta de lectura") { model.addReadDir(url) } }
            Section("Lectura") {
                Text("~/Downloads")
                ForEach(model.readDirs, id: \.self) { path in
                    Button("Quitar \(AgentFoldersSection.display(path))") { model.removeReadDir(path) }
                }
            }
            if let path = model.workdir {
                Button("Mostrar en Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                Button("Quitar carpeta") { model.clearWorkdir() }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                Text(model.workdir.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Carpeta").lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .font(Theme.mono()).foregroundStyle(Theme.muted)
            .padding(.horizontal, 10).frame(height: 28).frame(maxWidth: 180)
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.borderStrong))
            .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .fixedSize()
        .disabled(model.isRunningHere)
        .help(model.workdir ?? "Carpeta de trabajo")
    }

    /// Solo directorios; nil si el usuario cancela.
    @MainActor private static func pickFolder(_ title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}
