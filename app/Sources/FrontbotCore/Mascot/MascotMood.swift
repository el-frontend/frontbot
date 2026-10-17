import Foundation

/// Lo que está haciendo la mascota.
public enum MascotState: String, CaseIterable, Sendable {
    case idle, listening, thinking, talking, happy, sad
}

/// Decide el estado de la mascota a partir de los eventos del agente, con hora (sin depender de la UI).
/// Prioridad: run en curso (pensando/hablando) > reacción reciente (feliz/triste) > escuchando > reposo.
public struct MascotMood: Equatable, Sendable {
    public static let reactionDuration: TimeInterval = 2
    public static let talkingHold: TimeInterval = 1.5

    private var running = false
    private var lastSpoke: Date?
    private var reaction: (ok: Bool, at: Date)?

    public init() {}

    public mutating func runStarted(at date: Date) {
        running = true
        lastSpoke = nil
        reaction = nil
    }

    public mutating func agentSpoke(at date: Date) {
        lastSpoke = date
    }

    public mutating func runFinished(ok: Bool, at date: Date) {
        running = false
        lastSpoke = nil
        reaction = (ok, date)
    }

    /// `listening`: el notch está abierto o el usuario está escribiendo.
    public func state(at now: Date, listening: Bool) -> MascotState {
        if running {
            if let spoke = lastSpoke, now.timeIntervalSince(spoke) < Self.talkingHold { return .talking }
            return .thinking
        }
        if let reaction, now.timeIntervalSince(reaction.at) < Self.reactionDuration { return reaction.ok ? .happy : .sad }
        return listening ? .listening : .idle
    }

    public static func == (a: MascotMood, b: MascotMood) -> Bool {
        a.running == b.running && a.lastSpoke == b.lastSpoke && a.reaction?.ok == b.reaction?.ok && a.reaction?.at == b.reaction?.at
    }
}
