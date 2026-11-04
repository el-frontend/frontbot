import Foundation

/// Estado de la sesión de Codex propia de Frontbot (lo informa el sidecar con `codex.status`).
public struct CodexStatus: Equatable, Sendable {
    public var installed: Bool
    public var compatible: Bool
    public var version: String?
    public var email: String?
    public var plan: String?
    /// Modelos que ofrece la suscripción conectada.
    public var models: [String]

    public init(installed: Bool, compatible: Bool, version: String?, email: String?, plan: String?, models: [String]) {
        self.installed = installed; self.compatible = compatible; self.version = version
        self.email = email; self.plan = plan; self.models = models
    }

    public init(json: JSONValue) {
        let account = json["account"]
        self.init(installed: json["installed"]?.boolValue ?? false, compatible: json["compatible"]?.boolValue ?? false,
                  version: json["version"]?.stringValue, email: account?["email"]?.stringValue, plan: account?["plan"]?.stringValue,
                  models: (json["models"]?.arrayValue ?? []).compactMap(\.stringValue))
    }

    /// Con sesión, Codex corre sobre su runtime real (web, Chrome, carpeta, Laboratorio).
    public var connected: Bool { installed && compatible && (email != nil || plan != nil) }

    public static let unknown = CodexStatus(installed: false, compatible: false, version: nil, email: nil, plan: nil, models: [])
}

/// Qué puede hacer un agente según su proveedor y, en Codex, según haya sesión conectada.
public struct AgentCapabilities: Equatable, Sendable {
    public var web: Bool
    public var browser: Bool
    public var workdir: Bool
    public var lab: Bool

    public init(web: Bool, browser: Bool, workdir: Bool, lab: Bool) {
        self.web = web; self.browser = browser; self.workdir = workdir; self.lab = lab
    }

    /// Codex solo con API key queda en el modo básico: herramientas de Frontbot y nada más.
    public static func of(provider: AgentProvider, codexConnected: Bool) -> AgentCapabilities {
        let full = provider == .claude || codexConnected
        return AgentCapabilities(web: full, browser: full, workdir: full, lab: full)
    }
}
