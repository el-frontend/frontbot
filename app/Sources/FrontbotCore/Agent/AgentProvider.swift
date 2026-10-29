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
        case .codex: [
            ("gpt-6-astra", "GPT-6 Astra · general y programación"),
            ("gpt-6-sol", "GPT-6 Sol"),
            ("gpt-6-luna", "GPT-6 Luna"),
            ("gpt-5.6-sol", "GPT-5.6 Sol"),
            ("gpt-5.6-terra", "GPT-5.6 Terra"),
            ("gpt-5.6-luna", "GPT-5.6 Luna"),
            ("gpt-5.5", "GPT-5.5"),
        ]
        }
    }

    public static func resolve(_ stored: String?, for provider: AgentProvider) -> String {
        guard let stored, models(for: provider).contains(where: { $0.id == stored }) else {
            return defaultModel(for: provider)
        }
        return stored
    }
}
