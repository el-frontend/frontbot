import SwiftUI

struct SettingsView: View {
    let model: AppModel
    @State private var key = ""
    @State private var saved = false

    var body: some View {
        Form {
            SecureField("API key de Anthropic", text: $key)
            Text(model.apiKeyPresent ? "Hay una key guardada en el Keychain." : "No hay key guardada.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Guardar") {
                model.saveApiKey(key)
                key = ""
                saved = true
            }
            .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
            if saved { Text("Guardada.").font(.caption) }
        }
        .padding()
        .frame(width: 420)
    }
}
