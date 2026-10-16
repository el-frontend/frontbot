import SwiftUI
import AppKit
import FrontbotCore

@main
struct FrontbotApp: App {
    @State private var model: AppModel? = try? AppModel()
    @State private var notch: NotchController?

    init() {
        if CommandLine.arguments.contains("--self-check") { SelfCheck.run() }
        // Ejecutable SwiftPM: hay que pedir explícitamente una app con ventana y foco.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup("Frontbot", id: AppModel.mainWindowId) {
            if let model {
                RootView(model: model)
                    .task {
                        // El panel del notch y ⌥Espacio se crean una sola vez, con la primera ventana.
                        guard notch == nil else { return }
                        let controller = NotchController(model: model)
                        controller.show()
                        HotKey.shared.register { controller.toggle() }
                        model.hotKeyRegistered = HotKey.shared.registered
                        notch = controller
                    }
            } else {
                Text("No se pudo abrir la base de datos de Frontbot.").padding()
            }
        }
        Settings {
            if let model { SettingsView(model: model) }
        }
    }
}

/// `Frontbot --self-check`: comprueba que el bundle trae Node y el sidecar, sin abrir la UI.
enum SelfCheck {
    static func run() -> Never {
        guard let loc = AgentLocator.locate(environment: ProcessInfo.processInfo.environment, resources: Bundle.main.resourceURL) else {
            print("agente: NO ENCONTRADO — \(AgentLocator.notFoundMessage)")
            exit(1)
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: loc.node)
        p.arguments = ["--version"]
        let out = Pipe()
        p.standardOutput = out
        do { try p.run(); p.waitUntilExit() } catch { print("node: ERROR — \(error.localizedDescription)"); exit(1) }
        let version = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
        print("node: OK (\(version))")
        print("agente: OK (\(loc.script))")
        exit(p.terminationStatus == 0 ? 0 : 1)
    }
}
