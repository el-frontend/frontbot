import Foundation

/// Proveedor que ejecuta un agente.
public enum AgentProvider: String, Codable, CaseIterable, Sendable {
    case claude
    case codex

    public static func defaultModel(for provider: AgentProvider) -> String {
        switch provider {
        case .claude: AgentConfig.defaultModel
        case .codex: "gpt-5-codex"
        }
    }

    public static func models(for provider: AgentProvider) -> [(id: String, label: String)] {
        switch provider {
        case .claude: AgentModel.all
        case .codex: [
            ("gpt-5-codex", "GPT-5 Codex · programación"),
            ("gpt-5", "GPT-5 · general"),
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
