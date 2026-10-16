import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var key = ""
    @State private var saved = false

    var body: some View {
        Form {
            SecureField("API key de Anthropic (opcional)", text: $key)
            Text(model.apiKeyPresent
                 ? "Frontbot usa esta API key (se cobra por uso en tu cuenta de Anthropic)."
                 : "Sin API key, Frontbot usa tu sesión de Claude Code en este Mac. La key es opcional.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Guardar") {
                saved = model.saveApiKey(key)
                if saved { key = "" }
            }
            .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if saved { Text("Guardada.").font(.caption) }
            if !saved, let error = model.errorMessage { Text(error).font(.caption).foregroundStyle(.red) }
            Divider()
            Toggle("Usar mi Chrome para buscar en la web", isOn: $model.useBrowser)
            Text("Frontbot navega en tu Chrome con tus sesiones (necesita la extensión Claude in Chrome). Puede hacer clic y rellenar formularios, pero en redes sociales solo lee: nunca publica.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("Redes: inicia sesión una vez en la ventana de Chrome de Frontbot (separada de tu Chrome personal).")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Abrir Instagram") { model.openLogin(.instagram) }
                Button("Abrir LinkedIn") { model.openLogin(.linkedin) }
            }
            Divider()
            Text(model.hotKeyRegistered ? "Atajo global: ⌥Espacio abre Frontbot en el notch." : "⌥Espacio está ocupado por otra app. Abre el panel haciendo clic en el notch.")
                .font(.caption).foregroundStyle(model.hotKeyRegistered ? Color.secondary : Color.orange)
        }
        .padding()
        .frame(width: 420)
    }
}
