import Foundation
import GRDB

public enum TaskStatus: String, Codable, Sendable { case draft, active, paused }
public enum TaskRunStatus: String, Codable, Sendable { case running, done, failed, skipped }

/// Instrucción de un agente que corre sola con una frecuencia.
public struct ScheduledTask: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Hashable, Sendable {
    public var id: String
    public var agentId: String
    public var name: String
    public var instruction: String
    public var schedule: Schedule
    public var model: String
    public var status: TaskStatus
    public var maxRunsPerDay: Int
    public var lastRunAt: Date?
    public var nextRunAt: Date?
    public var createdByAgentId: String?
    public var templateKey: String?
    public var createdAt: Date
    public var updatedAt: Date
}

public struct TaskRun: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable {
    public var id: String
    public var taskId: String
    public var agentRunId: String?
    public var status: TaskRunStatus
    public var summary: String?
    public var notified: Bool
    public var conversationId: String?
    public var costUsd: Double
    public var startedAt: Date
    public var finishedAt: Date?
}

public struct TaskDraft: Equatable, Sendable {
    public var name: String
    public var instruction: String
    public var schedule: Schedule
    public var model: String?
    public var maxRunsPerDay: Int

    public init(name: String, instruction: String, schedule: Schedule, model: String? = nil, maxRunsPerDay: Int = 24) {
        self.name = name; self.instruction = instruction; self.schedule = schedule; self.model = model; self.maxRunsPerDay = maxRunsPerDay
    }

    public init(task: ScheduledTask) {
        self.init(name: task.name, instruction: task.instruction, schedule: task.schedule, model: task.model, maxRunsPerDay: task.maxRunsPerDay)
    }
}

/// Tareas que sugiere una plantilla (en borrador: el usuario decide si las activa).
enum TemplateTasks {
    static func tasks(for templateId: String?) -> [(key: String, draft: TaskDraft)] {
        guard templateId == AgentTemplate.cryptoTrader.id else { return [] }
        return [("crypto-market-4h", TaskDraft(
            name: "Revisión de mercado cada 4 h",
            instruction: """
            Revisa BTC y ETH en 4h y 1h (velas, funding, libro) y el contexto de noticias. Si encuentras un setup con confluencia \
            y riesgo/beneficio de al menos 1:2 dentro del mandato, propón el trade con trade_propose y avísame con notify_user \
            explicando la tesis en dos líneas. Si no hay nada claro, no me avises: deja un resumen breve.
            """,
            schedule: .interval(minutes: 240), maxRunsPerDay: 6))]
    }
}
