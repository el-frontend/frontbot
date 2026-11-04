import Foundation

/// Proveedor que ejecuta un agente.
public enum AgentProvider: String, Codable, CaseIterable, Sendable {
    case claude
    case codex

    public static func defaultModel(for provider: AgentProvider) -> String {
        switch provider {
        case .claude: AgentConfig.defaultModel
        case .codex: "gpt-6-astra"
        }
    }

    public static func models(for provider: AgentProvider) -> [(id: String, label: String)] {
        switch provider {
        case .claude: AgentModel.all
        // API ∪ suscripción, sin duplicados: así `resolve` conserva los modelos de las dos formas de ejecutar Codex.
        case .codex: codexAPIModels + codexSessionModels.filter { m in !codexAPIModels.contains { $0.id == m.id } }
        }
    }

    /// Modelos de la API de OpenAI (modo básico, con API key).
    public static let codexAPIModels: [(id: String, label: String)] = [
        ("gpt-6-astra", "GPT-6 Astra · general y programación"),
        ("gpt-6.1-sol", "GPT-6.1 Sol"),
        ("gpt-6.1-terra", "GPT-6.1 Terra"),
        ("gpt-6-luna", "GPT-6 Luna"),
    ]

    /// Modelos de una suscripción de ChatGPT con Codex (`model/list` del app-server).
    public static let codexSessionModels: [(id: String, label: String)] = [
        ("gpt-6-astra", "GPT-6 Astra · general y programación"),
        ("gpt-6-sol", "GPT-6 Sol"),
        ("gpt-6-luna", "GPT-6 Luna"),
        ("gpt-5.6-sol", "GPT-5.6 Sol"),
        ("gpt-5.6-terra", "GPT-5.6 Terra"),
        ("gpt-5.6-luna", "GPT-5.6 Luna"),
    ]

    /// Los que se ofrecen en la ficha del agente: con sesión, los de la suscripción; sin ella, los de la API.
    public static func pickerModels(for provider: AgentProvider, codex: CodexStatus?) -> [(id: String, label: String)] {
        guard provider == .codex else { return models(for: provider) }
        guard let codex, codex.connected else { return codexAPIModels }
        return codex.models.isEmpty ? codexSessionModels : codexSessionModels.filter { codex.models.contains($0.id) }
    }

    public static func resolve(_ stored: String?, for provider: AgentProvider) -> String {
        guard let stored, models(for: provider).contains(where: { $0.id == stored }) else {
            return defaultModel(for: provider)
        }
        return stored
    }
}
