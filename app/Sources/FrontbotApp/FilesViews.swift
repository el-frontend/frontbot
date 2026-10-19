import SwiftUI
import FrontbotCore

/// Carpetas del usuario en las que el agente puede leer y, con aprobación, escribir.
struct AgentFoldersSection: View {
    @Bindable var model: AppModel
    let agent: Agent
    @State private var choosing = false

    var body: some View {
        let folders = model.folders(agentId: agent.id)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Archivos").font(.system(size: 14, weight: .semibold))
                Text("\(folders.count) carpetas").font(Theme.mono()).foregroundStyle(Theme.muted)
                Spacer()
                Button("Añadir carpeta") { choosing = true }.buttonStyle(OutlineButtonStyle(prominent: true))
            }
            Text(folders.isEmpty
                 ? "\(agent.name) no puede tocar tus archivos. Añade una carpeta para que pueda leer en ella; cada vez que quiera escribir te pedirá permiso."
                 : "Lee lo que hay en estas carpetas sin preguntar. Para crear o reemplazar un archivo te pide permiso y te enseña el contenido. En las tareas programadas solo lee.")
                .font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            ForEach(folders, id: \.self) { path in
                HStack(spacing: 10) {
                    Image(systemName: "folder").foregroundStyle(Theme.muted)
                    Text(Self.display(path)).font(Theme.mono(12)).lineLimit(1).truncationMode(.middle).help(path)
                    Spacer()
                    Button { NSWorkspace.shared.open(URL(fileURLWithPath: path)) } label: { Image(systemName: "arrow.up.forward.square") }
                        .buttonStyle(.plain).foregroundStyle(Theme.muted).help("Abrir en Finder")
                    Button { model.removeFolder(path, agentId: agent.id) } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).foregroundStyle(Theme.muted).help("Quitar acceso").accessibilityLabel("Quitar acceso a \(path)")
                }
                .padding(.vertical, 4)
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading).panel(radius: 12)
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first { model.addFolder(url, agentId: agent.id) }
        }
    }

    /// "~/Documents/marcas" en vez de "/Users/nombre/Documents/marcas".
    static func display(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

/// Sitios a los que pueden conectarse los comandos del agente cuando trabaja en una carpeta.
struct AgentNetworkSection: View {
    @Bindable var model: AppModel
    let agent: Agent
    @State private var newDomain = ""
    @State private var problem: String?

    private var domains: [String] { agent.networkDomains ?? Workdir.defaultNetworkDomains }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Sitios de red").font(.system(size: 14, weight: .semibold))
                Text("\(domains.count) sitios").font(Theme.mono()).foregroundStyle(Theme.muted)
                Spacer()
                if agent.networkDomains != nil {
                    Button("Restaurar lista base") { model.setNetworkDomains(agentId: agent.id, nil) }.buttonStyle(OutlineButtonStyle())
                }
            }
            Text("Sitios a los que pueden conectarse sus comandos cuando trabaja en una carpeta.")
                .font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            ForEach(domains, id: \.self) { domain in
                HStack(spacing: 10) {
                    Image(systemName: "network").foregroundStyle(Theme.muted)
                    Text(domain).font(Theme.mono(12)).lineLimit(1)
                    Spacer()
                    Button("Quitar") { model.setNetworkDomains(agentId: agent.id, domains.filter { $0 != domain }) }
                        .buttonStyle(.plain).foregroundStyle(Theme.muted).font(.system(size: 12))
                        .accessibilityLabel("Quitar \(domain)")
                }
                .padding(.vertical, 2)
            }
            HStack(spacing: 8) {
                TextField("ejemplo.com o *.ejemplo.com", text: $newDomain)
                    .textFieldStyle(.plain).font(Theme.mono(12)).padding(.horizontal, 10).frame(height: 28)
                    .panel(radius: 7, fill: Theme.raised).onSubmit(add)
                Button("Añadir", action: add).buttonStyle(OutlineButtonStyle(prominent: true))
            }
            if let problem { Text(problem).font(.system(size: 11)).foregroundStyle(Theme.danger) }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading).panel(radius: 12)
    }

    private func add() {
        do {
            let domain = try Workdir.validatedDomain(newDomain)
            problem = nil
            newDomain = ""
            // Al editar sin lista propia se parte de la base.
            if !domains.contains(domain) { model.setNetworkDomains(agentId: agent.id, domains + [domain]) }
        } catch let e as ValidationError {
            problem = e.message
        } catch {
            problem = error.localizedDescription
        }
    }
}

/// Un agente quiere crear o reemplazar un archivo: el usuario ve la ruta y el contenido y decide.
struct FileWriteApprovalSheet: View {
    let model: AppModel
    let request: FileWriteRequest
    private static let previewLimit = 20_000

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "doc.badge.plus").foregroundStyle(Theme.accent)
                Text("\(request.agentName) quiere \(request.replaces ? "reemplazar" : "crear") un archivo").font(.system(size: 15, weight: .semibold))
            }
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("Archivo")
                Text(AgentFoldersSection.display(request.path)).font(Theme.mono(12)).textSelection(.enabled)
                if request.replaces {
                    Label("Ya existe\(request.previousSize.map { " (\(ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)))" } ?? ""): su contenido actual se perderá.",
                          systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12)).foregroundStyle(Theme.danger)
                }
                SectionLabel("Contenido · \(ByteCountFormatter.string(fromByteCount: Int64(request.content.utf8.count), countStyle: .file))").padding(.top, 6)
                ScrollView {
                    Text(preview).font(Theme.mono(11)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }
                .frame(maxHeight: 320).panel(radius: 8, fill: Theme.raised)
            }
            HStack {
                Spacer()
                Button("Denegar") { model.answerFileWrite(false) }.buttonStyle(OutlineButtonStyle()).keyboardShortcut(.cancelAction)
                Button(request.replaces ? "Reemplazar" : "Crear archivo") { model.answerFileWrite(true) }
                    .buttonStyle(AccentButtonStyle(destructive: request.replaces))
            }
        }
        .padding(22).frame(width: 560).background(Theme.sidebar)
        .interactiveDismissDisabled()
    }

    private var preview: String {
        guard request.content.count > Self.previewLimit else { return request.content.isEmpty ? "(vacío)" : request.content }
        return String(request.content.prefix(Self.previewLimit)) + "\n… (\(request.content.count - Self.previewLimit) caracteres más)"
    }
}
