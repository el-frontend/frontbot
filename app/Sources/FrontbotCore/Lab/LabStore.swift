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
        guard !q.isEmpty else { throw ValidationError(String(localized: "El tema necesita una pregunta.")) }
        guard q.count <= maxQuestion else { throw ValidationError(String(localized: "La pregunta es demasiado larga: máximo \(String(maxQuestion)) caracteres.")) }
        guard w.count <= maxWhy else { throw ValidationError(String(localized: "El porqué es demasiado largo: máximo \(String(maxWhy)) caracteres.")) }
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
            throw ValidationError(String(localized: "Ya tienes \(String(limit)) temas abiertos: pausa o abandona uno antes de abrir otro."))
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
            guard var topic = try LabTopic.fetchOne(db, key: id) else { throw ValidationError(String(localized: "No existe tema con id \(id).")) }
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
            guard var topic = try LabTopic.fetchOne(db, key: topicId) else { throw ValidationError(String(localized: "No existe tema con id \(topicId).")) }
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
    public func startLabSession(topicId: String, budgetTokens: Int = 0, now: Date) throws -> LabSession {
        try writer.write { db in
            guard try LabTopic.fetchOne(db, key: topicId) != nil else { throw ValidationError("No existe tema con id \(topicId).") }
            let session = LabSession(id: UUID().uuidString, topicId: topicId, agentRunId: nil, status: .running, tokens: 0,
                                     models: [], outcome: nil, summary: nil, startedAt: now, finishedAt: nil, budgetTokens: budgetTokens)
            try session.insert(db)
            return session
        }
    }

    public func attachAgentRun(labSessionId: String, agentRunId: String) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE labSession SET agentRunId = ? WHERE id = ?", arguments: [agentRunId, labSessionId])
        }
    }

    /// Guarda lo que decidió el agente al llamar a `lab_end_session`; la sesión sigue `running` hasta `agent.done`.
    public func recordSessionEnd(id: String, outcome: LabOutcome, summary: String, conclusion: String?, now: Date) throws {
        try writer.write { db in
            guard var session = try LabSession.fetchOne(db, key: id) else { throw ValidationError("No existe sesión con id \(id).") }
            session.outcome = outcome
            session.summary = summary
            try session.update(db)
            if let conclusion, var topic = try LabTopic.fetchOne(db, key: session.topicId) {
                topic.conclusion = conclusion
                topic.updatedAt = now
                try topic.update(db)
            }
        }
    }

    /// Las últimas `limit` notas sobre el modelo del agente, de todos sus temas, de la más antigua a la más reciente.
    public func modelNotes(agentId: String, limit: Int) throws -> [LabEntry] {
        try writer.read { db in
            let ids = try String.fetchAll(db, sql: "SELECT id FROM labTopic WHERE agentId = ?", arguments: [agentId])
            guard !ids.isEmpty else { return [] }
            let rows = try LabEntry.filter(ids.contains(Column("topicId")) && Column("kind") == LabEntryKind.model_note.rawValue)
                .order(Column("id").desc).limit(limit).fetchAll(db)
            return rows.reversed()
        }
    }

    /// Sesiones del tema, de la más reciente a la más antigua.
    public func labSessions(topicId: String) throws -> [LabSession] {
        try writer.read { try LabSession.filter(Column("topicId") == topicId).order(Column("startedAt").desc).fetchAll($0) }
    }

    public func labSession(id: String) throws -> LabSession? {
        try writer.read { try LabSession.fetchOne($0, key: id) }
    }

    /// Registra la sesión y los totales del tema. Solo cierra una sesión `running`: una segunda llamada no hace nada.
    /// Las reglas de espera y fallos (`LabScheduler.apply`) solo se aplican si el tema sigue `studying`:
    /// si el usuario lo pausó o abandonó durante la sesión, eso manda.
    @discardableResult
    public func finishLabSession(id: String, status: LabSessionStatus, outcome: LabOutcome?, summary: String?, conclusion: String?,
                                 tokens: Int, models: [LabModelUsage], cutReason: LabCutReason? = nil, now: Date) throws -> LabTopic {
        try writer.write { db in
            guard let session = try LabSession.fetchOne(db, key: id) else { throw ValidationError("No existe sesión con id \(id).") }
            return try Self.finish(session, status: status, outcome: outcome, summary: summary, conclusion: conclusion,
                                   tokens: tokens, models: models, cutReason: cutReason, now: now, db: db)
        }
    }

    private static func finish(_ session: LabSession, status: LabSessionStatus, outcome: LabOutcome?, summary: String?, conclusion: String?,
                               tokens: Int, models: [LabModelUsage], cutReason: LabCutReason?, now: Date, db: Database) throws -> LabTopic {
        var session = session
        guard var topic = try LabTopic.fetchOne(db, key: session.topicId) else { throw ValidationError("No existe tema con id \(session.topicId).") }
        guard session.status == .running else { return topic }
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
        if topic.status == .studying {
            LabScheduler.apply(finished: status, outcome: outcome, cutReason: cutReason, to: &topic, now: now)
        }
        try topic.update(db)
        return topic
    }

    /// Cierra una sesión cuyo final nunca llegó, cobrando su presupuesto entero (lo gastado es desconocido).
    /// `failed` (el watchdog) cuenta como fallo; `cut` con `.user` ("Detener") solo espera.
    @discardableResult
    public func closeLabSessionChargingBudget(id: String, status: LabSessionStatus, cutReason: LabCutReason? = nil, now: Date) throws -> LabTopic {
        try writer.write { db in
            guard let session = try LabSession.fetchOne(db, key: id) else { throw ValidationError("No existe sesión con id \(id).") }
            return try Self.finish(session, status: status, outcome: nil, summary: session.summary, conclusion: nil,
                                   tokens: max(session.tokens, session.budgetTokens), models: session.models, cutReason: cutReason, now: now, db: db)
        }
    }

    /// Al arrancar la app: las sesiones que quedaron `running` (la app se cerró o murió) pasan a `cut`, que no cuenta
    /// como fallo. Lo gastado se desconoce: se cobra el presupuesto entero y el tema espera 20 min como tras un corte.
    public func failRunningLabSessions(now: Date? = nil) throws -> Int {
        let now = now ?? .dbNow()
        return try writer.write { db in
            let running = try LabSession.filter(Column("status") == LabSessionStatus.running.rawValue).fetchAll(db)
            for session in running {
                _ = try Self.finish(session, status: .cut, outcome: nil, summary: session.summary, conclusion: nil,
                                    tokens: session.tokens == 0 ? session.budgetTokens : session.tokens, models: session.models,
                                    cutReason: nil, now: now, db: db)
            }
            return running.count
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
