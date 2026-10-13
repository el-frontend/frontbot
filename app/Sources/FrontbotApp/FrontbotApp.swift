import SwiftUI
import AppKit

@main
struct FrontbotApp: App {
    @State private var model: AppModel? = try? AppModel()

    init() {
        // Ejecutable SwiftPM: hay que pedir explícitamente una app con ventana y foco.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup("Frontbot") {
            if let model {
                NavigationSplitView {
                    BrandsView(model: model)
                } detail: {
                    ChatView(model: model)
                }
                .frame(minWidth: 900, minHeight: 600)
            } else {
                Text("No se pudo abrir la base de datos de Frontbot.").padding()
            }
        }
        Settings {
            if let model { SettingsView(model: model) }
        }
    }
}
