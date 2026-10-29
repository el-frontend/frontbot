import SwiftUI
import FrontbotCore

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var key = ""
    @State private var openAIKey = ""
    @State private var credentialProvider: AgentProvider = .claude
    @State private var saved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ajustes").font(.system(size: 18, weight: .semibold))

            section("Proveedores de IA") {
                Picker("Proveedor", selection: $credentialProvider) {
                    Text("Claude").tag(AgentProvider.claude)
                    Text("Codex").tag(AgentProvider.codex)
                }
                .pickerStyle(.segmented)

                if credentialProvider == .claude {
                    claudeCredentials
                } else {
                    codexCredentials
                }
            }

            section("Inicio") {
                Toggle(isOn: Binding(get: { _ = model.launchAtLoginVersion; return model.launchAtLogin }, set: { model.launchAtLogin = $0 })) {
                    Text("Abrir Frontbot al iniciar sesión").font(.system(size: 13, weight: .medium))
                }
                .toggleStyle(.switch).controlSize(.small)
                note("Las tareas programadas solo corren con Frontbot abierto (basta con el notch, sin ventana).")
            }

            section("Agentes") {
                note("El modelo y el uso de tu Chrome se configuran en cada agente, desde su página en la barra lateral.")
            }

            section("Laboratorio") {
                LabDatasetsSettings(model: model)
            }

            section("Funciones experimentales") {
                Toggle(isOn: $model.experimentalFeatures) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Mostrar trading").font(.system(size: 13, weight: .medium))
                        Text("Permite activar en cada agente el trading en Hyperliquid.")
                            .font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch).controlSize(.small)
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
                    (model.hotKeyRegistered
                         ? Text("⌥⌘ Espacio abre Frontbot en el notch.")
                         : Text("⌥⌘ Espacio está ocupado por otra app. Abre el panel haciendo clic en el notch."))
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
        .onChange(of: credentialProvider) { _, _ in saved = false }
    }

    @ViewBuilder
    private var claudeCredentials: some View {
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

    @ViewBuilder
    private var codexCredentials: some View {
        HStack(spacing: 8) {
            StatusDot(color: model.openAIKeyPresent ? Theme.approved : Theme.draft, size: 7)
            Text(model.openAIKeyPresent ? "API key guardada" : "API key no guardada")
                .font(.system(size: 13, weight: .medium))
        }
        note("Codex usa una API key de OpenAI guardada de forma segura en el llavero.")
        note("El uso se factura a tu proyecto de API de OpenAI; no se incluye en tu suscripción de ChatGPT o Codex.")
        note("Frontbot conserva el historial de tus conversaciones.")
        note("Las solicitudes usan store:false: OpenAI no guarda el objeto de respuesta normal. El tratamiento de datos sigue los controles de tu proyecto de API de OpenAI.")
        HStack(spacing: 8) {
            SecureField("API key de OpenAI (opcional)", text: $openAIKey)
                .textFieldStyle(.plain).font(.system(size: 13))
                .padding(.horizontal, 10).frame(height: 30)
                .panel(radius: 7, fill: Theme.raised)
            Button("Guardar") {
                saved = model.saveOpenAIAPIKey(openAIKey)
                if saved { openAIKey = "" }
            }
            .buttonStyle(OutlineButtonStyle(prominent: true))
            .disabled(openAIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        HStack(spacing: 8) {
            Text(model.openAIKeyPresent ? "Guardada en el llavero." : "No hay una API key guardada.")
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
            Spacer()
            if model.openAIKeyPresent {
                Button("Eliminar") { saved = model.deleteOpenAIAPIKey() }
                    .buttonStyle(OutlineButtonStyle())
            }
        }
        if !saved, let error = model.errorMessage {
            Text(error).font(.system(size: 12)).foregroundStyle(Theme.danger)
        }
    }

    private func section(_ title: LocalizedStringKey, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(radius: 10)
    }

    private func note(_ text: LocalizedStringKey) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(Theme.muted)
            .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
    }
}
