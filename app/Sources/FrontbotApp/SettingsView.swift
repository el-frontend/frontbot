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
                saved = model.saveApiKey(key)
                if saved { key = "" }
            }
            .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if saved { Text("Guardada.").font(.caption) }
            if !saved, let error = model.errorMessage { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .padding()
        .frame(width: 420)
    }
}
