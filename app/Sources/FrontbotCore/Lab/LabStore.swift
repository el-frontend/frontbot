import Foundation
import GRDB

private let maxQuestion = 300
private let maxWhy = 1000
private let maxEntryText = 4000

extension AppDatabase {
    // MARK: Temas
    public func openTopic(agentId: String, question: String, why: String, origin: LabOrigin, now: Date) throws -> LabTopic {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let w = why.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { throw ValidationError("El tema necesita una pregunta.") }
        guard q.count <= maxQuestion else { throw ValidationError("La pregunta es demasiado larga: máximo \(maxQuestion) caracteres.") }
        guard w.count <= maxWhy else { throw ValidationError("El porqué es demasiado largo: máximo \(maxWhy) caracteres.") }
        return try writer.write { db in
            try Self.requireRoom(agentId: agentId, db: db)
            let topic = LabTopic(id: UUID().uuidString, agentId: agentId, question: q, why: w, origin: origin, status: .studying,
                                 conclusion: nil, sessions: 0, tokensUsed: 0, nextSessionAfter: now, consecutiveFailures: 0,
                                 pausedReason: nil, createdAt: now, updatedAt: now)
            try topic.insert(db)
            return topic
        }
    }

    private static func requireRoom(agentId: String, db: Database) throws {
        let limit = try AgentLabSettings.fetchOne(db, key: agentId)?.maxOpenTopics
            ?? AgentLabSettings.defaults(agentId: agentId).maxOpenTopics
        let open = try LabTopic.filter(Column("agentId") == agentId
            && [LabTopicStatus.studying.rawValue, LabTopicStatus.paused.rawValue].contains(Column("status"))).fetchCount(db)
        if open >= limit {
            throw ValidationError("Ya tienes \(limit) temas abiertos: pausa o abandona uno antes de abrir otro.")
        }
    }

    /// Abiertos primero, luego por `updatedAt` descendente.
    public func topics(agentId: String) throws -> [LabTopic] {
        try writer.read { db in
            try LabTopic.filter(Column("agentId") == agentId).fetchAll(db)
                .sorted { a, b in
                    a.status.isOpen != b.status.isOpen ? a.status.isOpen : a.updatedAt > b.updatedAt
                }
        }
    }

    public func topic(id: String) throws -> LabTopic? {
        try writer.read { try LabTopic.fetchOne($0, key: id) }
    }

    @discardableResult
    public func setTopicStatus(id: String, _ status: LabTopicStatus, reason: String?, now: Date) throws -> LabTopic {
        try writer.write { db in
            guard var topic = try LabTopic.fetchOne(db, key: id) else { throw ValidationError("No existe tema con id \(id).") }
            // Un tema pausado ya cuenta como abierto; solo pasar de cerrado a abierto puede superar el límite.
            if !topic.status.isOpen && status.isOpen { try Self.requireRoom(agentId: topic.agentId, db: db) }
            if status == .studying {
                topic.consecutiveFailures = 0
                topic.pausedReason = nil
                topic.nextSessionAfter = now
            } else if status == .paused {
                topic.pausedReason = reason
            }
            topic.status = status
            topic.updatedAt = now
            try topic.update(db)
            return topic
        }
    }

    @discardableResult
    public func studyNow(topicId: String, now: Date) throws -> LabTopic {
        try writer.write { db in
            guard var topic = try LabTopic.fetchOne(db, key: topicId) else { throw ValidationError("No existe tema con id \(topicId).") }
            topic.nextSessionAfter = now
            topic.updatedAt = now
            try topic.update(db)
            return topic
        }
    }

    // MARK: Cuaderno
    @discardableResult
    public func addEntry(topicId: String, sessionId: String?, kind: LabEntryKind, text: String,
                         evidence: Evidence?, sources: [String], model: String?) throws -> LabEntry {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { throw ValidationError("La entrada del cuaderno no puede estar vacía.") }
        guard t.count <= maxEntryText else { throw ValidationError("La entrada es demasiado larga: máximo \(maxEntryText) caracteres.") }
        return try writer.write { db in
            guard try LabTopic.fetchOne(db, key: topicId) != nil else { throw ValidationError("No existe tema con id \(topicId).") }
            var entry = LabEntry(id: nil, topicId: topicId, sessionId: sessionId, kind: kind, text: t, evidence: evidence,
                                 sources: sources, model: model, createdAt: .dbNow())
            try entry.insert(db)
            return entry
        }
    }

    public func entries(topicId: String) throws -> [LabEntry] {
        try writer.read { try LabEntry.filter(Column("topicId") == topicId).order(Column("id")).fetchAll($0) }
    }

    // MARK: Sesiones
    public func startLabSession(topicId: String, now: Date) throws -> LabSession {
        try writer.write { db in
            guard try LabTopic.fetchOne(db, key: topicId) != nil else { throw ValidationError("No existe tema con id \(topicId).") }
            let session = LabSession(id: UUID().uuidString, topicId: topicId, agentRunId: nil, status: .running, tokens: 0,
                                     models: [], outcome: nil, summary: nil, startedAt: now, finishedAt: nil)
            try session.insert(db)
            return session
        }
    }

    public func attachAgentRun(labSessionId: String, agentRunId: String) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE labSession SET agentRunId = ? WHERE id = ?", arguments: [agentRunId, labSessionId])
        }
    }

    /// Registra la sesión y los totales del tema. Las reglas de espera y fallos las aplica `LabScheduler.apply`.
    @discardableResult
    public func finishLabSession(id: String, status: LabSessionStatus, outcome: LabOutcome?, summary: String?, conclusion: String?,
                                 tokens: Int, models: [LabModelUsage], now: Date) throws -> LabTopic {
        try writer.write { db in
            guard var session = try LabSession.fetchOne(db, key: id) else { throw ValidationError("No existe sesión con id \(id).") }
            guard var topic = try LabTopic.fetchOne(db, key: session.topicId) else { throw ValidationError("No existe tema con id \(session.topicId).") }
            session.status = status
            session.outcome = outcome
            session.summary = summary
            session.tokens = tokens
            session.models = models
            session.finishedAt = now
            try session.update(db)
            topic.sessions += 1
            topic.tokensUsed += tokens
            if let conclusion { topic.conclusion = conclusion }
            topic.updatedAt = now
            LabScheduler.apply(finished: status, outcome: outcome, to: &topic, now: now)
            try topic.update(db)
            return topic
        }
    }

    /// Al arrancar la app: las sesiones que quedaron `running` pasan a `cut`, que no cuenta como fallo.
    public func failRunningLabSessions() throws -> Int {
        try writer.write { db in
            try db.execute(sql: "UPDATE labSession SET status = ?, finishedAt = ? WHERE status = ?",
                           arguments: [LabSessionStatus.cut.rawValue, Date.dbNow(), LabSessionStatus.running.rawValue])
            return db.changesCount
        }
    }

    public func runningLabSession() throws -> LabSession? {
        try writer.read { try LabSession.filter(Column("status") == LabSessionStatus.running.rawValue).fetchOne($0) }
    }

    // MARK: Uso de tokens
    /// Suma `tokens` de las sesiones con `startedAt` en [from, to).
    public func labTokensUsed(agentId: String, from: Date, to: Date) throws -> Int {
        try writer.read { db in
            let topicIds = try String.fetchAll(db, sql: "SELECT id FROM labTopic WHERE agentId = ?", arguments: [agentId])
            guard !topicIds.isEmpty else { return 0 }
            return try LabSession.filter(topicIds.contains(Column("topicId")) && Column("startedAt") >= from && Column("startedAt") < to)
                .fetchAll(db).reduce(0) { $0 + $1.tokens }
        }
    }

    public func labTokensUsed(agentId: String, day: Date, calendar: Calendar = .current) throws -> Int {
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return 0 }
        return try labTokensUsed(agentId: agentId, from: start, to: end)
    }

    // MARK: Ajustes
    public func labSettings(agentId: String) throws -> AgentLabSettings {
        try writer.read { try AgentLabSettings.fetchOne($0, key: agentId) } ?? .defaults(agentId: agentId)
    }

    public func saveLabSettings(_ settings: AgentLabSettings) throws {
        try writer.write { try settings.save($0) }
    }
}
