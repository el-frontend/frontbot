import SwiftUI
import FrontbotCore

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var key = ""
    @State private var saved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ajustes").font(.system(size: 18, weight: .semibold))

            section("Cuenta de Claude") {
                HStack(spacing: 8) {
                    StatusDot(color: Theme.approved, size: 7)
                    Text(model.apiKeyPresent ? "Usando tu API key de Anthropic" : "Usando tu sesión de Claude Code")
                        .font(.system(size: 13, weight: .medium))
                }
                note(model.apiKeyPresent
                     ? "Se cobra por uso en tu cuenta de Anthropic."
                     : "No necesitas API key. Si pones una, Frontbot la usará en lugar de tu sesión.")
                HStack(spacing: 8) {
                    SecureField("API key de Anthropic (opcional)", text: $key)
                        .textFieldStyle(.plain).font(.system(size: 13))
                        .padding(.horizontal, 10).frame(height: 30)
                        .panel(radius: 7, fill: Theme.raised)
                    Button("Guardar") {
                        saved = model.saveApiKey(key)
                        if saved { key = "" }
                    }
                    .buttonStyle(OutlineButtonStyle(prominent: true))
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if saved { note("Guardada en el llavero.") }
                if !saved, let error = model.errorMessage {
                    Text(error).font(.system(size: 12)).foregroundStyle(Theme.danger)
                }
            }

            section("Modelo") {
                Picker("Modelo", selection: $model.selectedModel) {
                    ForEach(AgentModel.all, id: \.id) { Text($0.label).tag($0.id) }
                }
                .labelsHidden().pickerStyle(.radioGroup)
                note("También puedes cambiarlo en el chat, junto al botón de enviar.")
            }

            section("Navegador") {
                Toggle(isOn: $model.useBrowser) {
                    Text("Usar mi Chrome para buscar en la web").font(.system(size: 13, weight: .medium))
                }
                .toggleStyle(.switch).controlSize(.small)
                note("Frontbot navega en tu Chrome con tus sesiones. Necesita la extensión Claude in Chrome. Puede hacer clic y rellenar formularios, pero en redes sociales solo lee: nunca publica.")
            }

            section("Redes") {
                note("Se abren en tu navegador, donde ya tienes la sesión iniciada.")
                HStack(spacing: 8) {
                    Button("Abrir Instagram") { model.openNetwork(.instagram) }.buttonStyle(OutlineButtonStyle())
                    Button("Abrir LinkedIn") { model.openNetwork(.linkedin) }.buttonStyle(OutlineButtonStyle())
                }
            }

            section("Atajo") {
                HStack(spacing: 8) {
                    StatusDot(color: model.hotKeyRegistered ? Theme.approved : Theme.draft, size: 7)
                    Text(model.hotKeyRegistered
                         ? "⌥ Espacio abre Frontbot en el notch."
                         : "⌥ Espacio está ocupado por otra app. Abre el panel haciendo clic en el notch.")
                        .font(.system(size: 13))
                }
            }
        }
        .foregroundStyle(Theme.text)
        .padding(22)
        .frame(width: 500, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.background)
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(radius: 10)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(Theme.muted)
            .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
    }
}
