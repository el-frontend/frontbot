import SwiftUI
import FrontbotCore

/// Ajustes del laboratorio del agente, plegados por defecto.
struct LabSettingsSection: View {
    let model: AppModel
    let agent: Agent
    @State private var expanded = false

    var body: some View {
        let settings = model.lab.settings(agentId: agent.id)
        VStack(alignment: .leading, spacing: 12) {
            Button { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 10)).foregroundStyle(Theme.muted)
                    Text("Ajustes").font(.system(size: 14, weight: .semibold))
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                Toggle("Laboratorio activo", isOn: binding(settings, \.enabled)).toggleStyle(.switch).controlSize(.small)
                HStack(spacing: 16) {
                    number("Tokens por sesión", settings.sessionTokenCap, \.sessionTokenCap, settings)
                    number("Tokens por día", settings.dailyTokenCap, \.dailyTokenCap, settings)
                    number("Temas abiertos", settings.maxOpenTopics, \.maxOpenTopics, settings)
                    Spacer()
                }
                Toggle(isOn: binding(settings, \.allowOpus)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Permitir Opus").font(.system(size: 13, weight: .medium))
                        Text("Opus gasta mucho más presupuesto: solo para pasos que lo piden.")
                            .font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }
                }
                .toggleStyle(.switch).controlSize(.small)
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading).panel(radius: 12)
    }

    private func binding<T>(_ s: AgentLabSettings, _ key: WritableKeyPath<AgentLabSettings, T>) -> Binding<T> {
        Binding(get: { model.lab.settings(agentId: agent.id)[keyPath: key] }, set: { value in
            var next = model.lab.settings(agentId: agent.id)
            next[keyPath: key] = value
            model.lab.save(next)
        })
    }

    private func number(_ label: String, _ value: Int, _ key: WritableKeyPath<AgentLabSettings, Int>, _ s: AgentLabSettings) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(label)
            TextField("", value: Binding(get: { value }, set: { v in
                var next = model.lab.settings(agentId: agent.id)
                next[keyPath: key] = max(1, v)
                model.lab.save(next)
            }), format: .number.grouping(.never))
                .textFieldStyle(.plain).padding(.horizontal, 10).frame(width: 120, height: 30).panel(radius: 8)
        }
    }
}
