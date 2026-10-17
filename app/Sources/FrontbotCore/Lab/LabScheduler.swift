import Foundation

public struct LabCandidate: Sendable {
    public var topic: LabTopic
    public var agent: Agent
    public var settings: AgentLabSettings
    public var usedToday: Int

    public init(topic: LabTopic, agent: Agent, settings: AgentLabSettings, usedToday: Int) {
        self.topic = topic; self.agent = agent; self.settings = settings; self.usedToday = usedToday
    }
}

/// Decide qué sesión de estudio toca, con qué presupuesto y cuánto esperar tras cada resultado. Sin E/S.
public enum LabScheduler {
    public static let minimumBudget = 20_000
    public static let continueDelay: TimeInterval = 20 * 60
    static let failureDelays: [TimeInterval] = [20 * 60, 60 * 60, 4 * 60 * 60]
    static let maxConsecutiveFailures = 3

    public static func next(candidates: [LabCandidate], sessionRunning: Bool, agentsInChat: Set<String>, now: Date) -> LabCandidate? {
        guard !sessionRunning else { return nil }
        return candidates
            .filter { c in
                c.topic.status == .studying
                    && c.agent.status == .active
                    && c.settings.enabled
                    && !agentsInChat.contains(c.agent.id)
                    && (c.topic.nextSessionAfter.map { $0 <= now } ?? true)
                    && budget(settings: c.settings, usedToday: c.usedToday) != nil
            }
            .min { $0.topic.createdAt < $1.topic.createdAt }
    }

    public static func budget(settings: AgentLabSettings, usedToday: Int) -> Int? {
        let value = min(settings.sessionTokenCap, settings.dailyTokenCap - usedToday)
        return value < minimumBudget ? nil : value
    }

    public static func apply(finished status: LabSessionStatus, outcome: LabOutcome?, to topic: inout LabTopic, now: Date) {
        switch status {
        case .done:
            switch outcome {
            case .pause: topic.status = .paused
            case .resolve: topic.status = .resolved
            case .abandon: topic.status = .abandoned
            case .continue, nil:
                topic.consecutiveFailures = 0
                topic.nextSessionAfter = now.addingTimeInterval(continueDelay)
            }
        case .cut:
            topic.nextSessionAfter = now.addingTimeInterval(continueDelay)
        case .failed:
            topic.consecutiveFailures += 1
            topic.nextSessionAfter = now.addingTimeInterval(failureDelays[min(topic.consecutiveFailures - 1, failureDelays.count - 1)])
            if topic.consecutiveFailures >= maxConsecutiveFailures {
                topic.status = .paused
                topic.pausedReason = "Falló 3 veces seguidas"
            }
        case .running:
            break
        }
    }
}
