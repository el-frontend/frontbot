import Foundation

public struct ChatTurn: Equatable, Sendable {
    public enum Role: String, Sendable { case user, agent }
    public let role: Role
    public let text: String

    public init(role: Role, text: String) {
        self.role = role
        self.text = text
    }
}

/// Historial que se manda al agente con cada mensaje: acotado para no agotar el contexto.
public enum ChatHistory {
    public static let maxTurns = 20
    public static let maxCharsPerTurn = 4_000

    public static func trimmed(_ turns: [ChatTurn]) -> [ChatTurn] {
        turns.suffix(maxTurns).map { t in
            t.text.count > maxCharsPerTurn ? ChatTurn(role: t.role, text: String(t.text.prefix(maxCharsPerTurn)) + "…") : t
        }
    }

    public static func json(_ turns: [ChatTurn]) -> JSONValue {
        .array(turns.map { ["role": .string($0.role.rawValue), "text": .string($0.text)] })
    }
}
