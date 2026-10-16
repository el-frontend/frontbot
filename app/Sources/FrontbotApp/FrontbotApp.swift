import SwiftUI
import AppKit

@main
struct FrontbotApp: App {
    @State private var model: AppModel? = try? AppModel()
    @State private var notch: NotchController?

    init() {
        // Ejecutable SwiftPM: hay que pedir explícitamente una app con ventana y foco.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup("Frontbot") {
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
