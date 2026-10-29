import Foundation

/// Lo que va pasando en una ejecución programada (texto, herramientas, aviso) hasta que termina.
public struct ScheduledRunLog: Sendable {
    public let taskRunId: String
    public let task: ScheduledTask
    public let startedAt: Date
    /// Lanzada con "Ejecutar ahora": el usuario está mirando y quiere ver el resultado.
    public let manual: Bool
    public private(set) var transcript: [(role: ChatRole, text: String)] = []
    public var notification: (title: String, message: String)?

    public init(taskRunId: String, task: ScheduledTask, startedAt: Date, manual: Bool = false) {
        self.taskRunId = taskRunId
        self.task = task
        self.startedAt = startedAt
        self.manual = manual
    }

    public mutating func record(_ role: ChatRole, _ text: String) {
        if transcript.count < 400 { transcript.append((role, text)) }
    }
}

extension AppDatabase {
    /// Cierra la ejecución. Si el agente avisó o propuso un trade, la guarda como conversación (🕒) para seguirla.
    public func completeScheduledRun(_ log: ScheduledRunLog, run: AgentRun, workspaceId: String,
                                     proposalsCreated: Int) throws -> (conversationId: String?, surfaced: Bool) {
        let surfaced = log.notification != nil || proposalsCreated > 0
        var conversationId: String?
        if surfaced || log.manual {
            let conversation = try createConversation(workspaceId: workspaceId, agentId: log.task.agentId, brandId: nil,
                                                      firstPrompt: "🕒 " + log.task.name)
            try appendMessage(conversationId: conversation.id, role: .user, text: "🕒 Tarea programada «\(log.task.name)»: \(log.task.instruction)")
            for item in log.transcript { try appendMessage(conversationId: conversation.id, role: item.role, text: item.text) }
            if run.status == .failed { try appendMessage(conversationId: conversation.id, role: .error, text: run.resultSummary ?? "Error") }
            conversationId = conversation.id
        }
        try finishTaskRun(id: log.taskRunId, status: run.status == .failed ? .failed : .done, summary: run.resultSummary,
                          notified: surfaced, conversationId: conversationId, costUsd: run.costAvailable ? run.costUsd : nil)
        return (conversationId, surfaced)
    }
}
