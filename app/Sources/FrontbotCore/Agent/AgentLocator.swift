import Foundation

public struct AgentLocation: Equatable, Sendable {
    public let node: String
    public let script: String
}

/// Dónde están Node y el sidecar: variables de entorno (desarrollo) o dentro del `.app`.
public enum AgentLocator {
    public static let notFoundMessage = "No encontré el agente de Frontbot. Reinstala la app o define FRONTBOT_NODE y FRONTBOT_AGENT_SCRIPT."

    public static func locate(environment: [String: String], resources: URL?,
                              exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> AgentLocation? {
        if let node = environment["FRONTBOT_NODE"], let script = environment["FRONTBOT_AGENT_SCRIPT"], exists(node), exists(script) {
            return AgentLocation(node: node, script: script)
        }
        if let resources {
            let node = resources.appendingPathComponent("node/bin/node").path
            let script = resources.appendingPathComponent("agent/dist/main.js").path
            if exists(node), exists(script) { return AgentLocation(node: node, script: script) }
        }
        return nil
    }
}
