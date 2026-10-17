import SwiftUI
import AppKit
import Observation
import FrontbotCore

/// Ajustes → Laboratorio: datasets compartidos y entorno de Python para los scripts de los agentes.
struct LabDatasetsSettings: View {
    let model: AppModel
    @State private var env = LabPythonEnv()
    @State private var importing: URL?
    @State private var deleting: DatasetMeta?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Datasets")
            if model.lab.datasets.isEmpty {
                note("Sin datasets. Los agentes los descargan (solo datos públicos) o los añades tú desde una carpeta.")
            }
            ForEach(model.lab.datasets, id: \.name) { meta in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(meta.name).font(Theme.mono(12))
                        Text("\(ByteCountFormatter.string(fromByteCount: Int64(meta.bytes), countStyle: .file)) · \(origin(meta))")
                            .font(.system(size: 11)).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    Button("Borrar") { deleting = meta }.buttonStyle(OutlineButtonStyle()).foregroundStyle(Theme.danger)
                }
            }
            Button("Añadir carpeta como dataset…") { pickFolder() }.buttonStyle(OutlineButtonStyle(prominent: true))

            SectionLabel("Python").padding(.top, 6)
            if env.running {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Preparando el entorno…").font(.system(size: 13)) }
            } else if env.isReady {
                HStack(spacing: 8) {
                    StatusDot(color: Theme.approved, size: 7)
                    Text("Entorno listo (numpy, pandas)").font(.system(size: 13, weight: .medium))
                    Spacer()
                    Button("Reinstalar") { env.install(paths: model.paths) }.buttonStyle(OutlineButtonStyle())
                }
            } else {
                note("Los scripts de los laboratorios necesitan numpy y pandas. Se instalan en un entorno propio, con red, solo cuando lo pides.")
                Button("Preparar entorno de Python") { env.install(paths: model.paths) }.buttonStyle(OutlineButtonStyle(prominent: true))
            }
            if let result = env.result {
                Text(result).font(.system(size: 12)).foregroundStyle(env.failed ? Theme.danger : Theme.muted)
            }
            if !env.log.isEmpty {
                ScrollView {
                    Text(env.log).font(Theme.mono(10)).foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
                .frame(height: 90).padding(8).panel(radius: 8, fill: Theme.raised)
            }
            if let error = model.errorMessage { Text(error).font(.system(size: 12)).foregroundStyle(Theme.danger) }
        }
        .onAppear { env.refresh(paths: model.paths); model.lab.reloadDatasets() }
        .sheet(item: Binding(get: { importing.map(FolderChoice.init) }, set: { importing = $0?.url })) { choice in
            DatasetNameSheet(folder: choice.url) { name, description in
                model.errorMessage = nil
                model.lab.importDataset(folder: choice.url, name: name, description: description)
                return model.errorMessage == nil
            }
        }
        .confirmationDialog("¿Borrar \(deleting?.name ?? "")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { meta in
            Button("Borrar dataset", role: .destructive) { model.lab.deleteDataset(meta) }
        } message: { _ in
            Text("Los scripts que lo usen dejarán de encontrarlo.")
        }
    }

    private func origin(_ meta: DatasetMeta) -> String {
        guard let id = meta.fetchedByAgentId else { return "añadido por ti" }
        return "lo trajo " + (model.agent(id: id)?.name ?? "un agente")
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Elegir"
        if panel.runModal() == .OK { importing = panel.url }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(Theme.muted).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
    }
}

private struct FolderChoice: Identifiable { let url: URL; var id: String { url.path } }

/// Nombre y descripción de un dataset que viene de una carpeta local.
private struct DatasetNameSheet: View {
    let folder: URL
    let onSave: (String, String) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var description = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Añadir dataset").font(.system(size: 16, weight: .semibold))
            Text(folder.path).font(Theme.mono(11)).foregroundStyle(Theme.muted).lineLimit(2)
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("Nombre (kebab-case)")
                TextField("btc-4h-binance", text: $name).font(Theme.mono(13)).textFieldStyle(.plain)
                    .padding(.horizontal, 10).frame(height: 32).panel(radius: 8)
            }
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("Descripción")
                TextField("Qué contiene y de dónde viene", text: $description).textFieldStyle(.plain)
                    .padding(.horizontal, 10).frame(height: 32).panel(radius: 8)
            }
            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }.buttonStyle(OutlineButtonStyle())
                Button("Añadir") { if onSave(name.trimmingCharacters(in: .whitespacesAndNewlines), description) { dismiss() } }
                    .buttonStyle(AccentButtonStyle()).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22).frame(width: 460).background(Theme.sidebar)
    }
}

/// Crea `labs/.venv` e instala numpy y pandas. Corre fuera de la sandbox y solo cuando el usuario lo pide.
@MainActor @Observable
final class LabPythonEnv {
    private(set) var running = false
    private(set) var isReady = false
    private(set) var failed = false
    private(set) var result: String?
    private(set) var log = ""

    func refresh(paths: AppPaths) {
        guard !running else { return }
        let fm = FileManager.default
        let lib = paths.labsDir.appendingPathComponent(".venv/lib", isDirectory: true)
        let versions = (try? fm.contentsOfDirectory(atPath: lib.path)) ?? []
        isReady = fm.isExecutableFile(atPath: paths.labVenvPython.path)
            && versions.contains { fm.fileExists(atPath: lib.appendingPathComponent("\($0)/site-packages/pandas").path) }
    }

    func install(paths: AppPaths) {
        guard !running else { return }
        running = true; failed = false; result = nil; log = ""
        let venv = paths.labsDir.appendingPathComponent(".venv", isDirectory: true)
        let python = ScriptSandbox.pythonPath
        Task {
            do {
                try FileManager.default.createDirectory(at: paths.labsDir, withIntermediateDirectories: true)
                try await run(python, ["-m", "venv", "--clear", venv.path])
                try await run(venv.appendingPathComponent("bin/pip").path, ["install", "numpy", "pandas"])
                result = "Entorno listo."
            } catch {
                failed = true
                result = "No se pudo preparar el entorno: \(error.localizedDescription)"
            }
            running = false
            refresh(paths: paths)
        }
    }

    private struct Failure: LocalizedError {
        let status: Int32
        var errorDescription: String? { "el comando terminó con código \(status). Revisa el registro." }
    }

    private func run(_ executable: String, _ arguments: [String]) async throws {
        log += "$ \((executable as NSString).lastPathComponent) \(arguments.joined(separator: " "))\n"
        let status: Int32 = try await withCheckedThrowingContinuation { cont in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                let text = String(decoding: data, as: UTF8.self)
                Task { @MainActor in self?.append(text) }
            }
            process.terminationHandler = { p in
                pipe.fileHandleForReading.readabilityHandler = nil
                cont.resume(returning: p.terminationStatus)
            }
            do { try process.run() } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                cont.resume(throwing: error)
            }
        }
        if status != 0 { throw Failure(status: status) }
    }

    private func append(_ text: String) {
        log += text
        if log.count > 20_000 { log = String(log.suffix(20_000)) }
    }
}
