import Foundation
import GRDB

public final class AppDatabase: Sendable {
    public let writer: any DatabaseWriter

    init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    public static func inMemory() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue())
    }

    public static func open(at url: URL) throws -> AppDatabase {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return try AppDatabase(DatabasePool(path: url.path))
    }

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "workspace") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "brand") { t in
                t.primaryKey("id", .text)
                t.column("workspaceId", .text).notNull().references("workspace", onDelete: .cascade)
                t.column("name", .text).notNull()
                t.column("industry", .text).notNull()
                t.column("networks", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "brandAsset") { t in
                t.primaryKey("id", .text)
                t.column("brandId", .text).notNull().references("brand", onDelete: .cascade)
                t.column("kind", .text).notNull()
                t.column("path", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "post") { t in
                t.primaryKey("id", .text)
                t.column("brandId", .text).notNull().references("brand", onDelete: .cascade)
                t.column("network", .text).notNull()
                t.column("body", .text).notNull()
                t.column("media", .text).notNull()
                t.column("status", .text).notNull()
                t.column("scheduledFor", .datetime)
                t.column("publishedUrl", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(table: "task") { t in
                t.primaryKey("id", .text)
                t.column("workspaceId", .text).notNull().references("workspace", onDelete: .cascade)
                t.column("title", .text).notNull()
                t.column("dueDate", .datetime)
                t.column("done", .boolean).notNull().defaults(to: false)
                t.column("brandId", .text).references("brand", onDelete: .setNull)
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "businessIdea") { t in
                t.primaryKey("id", .text)
                t.column("workspaceId", .text).notNull().references("workspace", onDelete: .cascade)
                t.column("title", .text).notNull()
                t.column("summary", .text).notNull()
                t.column("sources", .text).notNull()
                t.column("score", .integer).notNull()
                t.column("reportPath", .text)
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "agentRun") { t in
                t.primaryKey("id", .text)
                t.column("workspaceId", .text).notNull().references("workspace", onDelete: .cascade)
                t.column("brandId", .text).references("brand", onDelete: .setNull)
                t.column("prompt", .text).notNull()
                t.column("status", .text).notNull()
                t.column("resultSummary", .text)
                t.column("inputTokens", .integer).notNull()
                t.column("outputTokens", .integer).notNull()
                t.column("costUsd", .double).notNull()
                t.column("logPath", .text)
                t.column("createdAt", .datetime).notNull()
            }
        }
        m.registerMigration("v2-conversations") { db in
            try db.create(table: "conversation") { t in
                t.primaryKey("id", .text)
                t.column("workspaceId", .text).notNull().references("workspace", onDelete: .cascade)
                t.column("brandId", .text).references("brand", onDelete: .setNull)
                t.column("title", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                // Orden de "Recientes": crece con cada mensaje; las horas pueden empatar en el mismo milisegundo.
                t.column("activity", .integer).notNull().indexed()
            }
            try db.create(table: "chatMessage") { t in
                t.autoIncrementedPrimaryKey("id") // el orden de inserción es el orden de la conversación
                t.column("conversationId", .text).notNull().indexed().references("conversation", onDelete: .cascade)
                t.column("role", .text).notNull()
                t.column("text", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
        }
        m.registerMigration("v3-agents") { db in
            try db.create(table: "agent") { t in
                t.primaryKey("id", .text)
                t.column("workspaceId", .text).notNull().references("workspace", onDelete: .cascade)
                t.column("name", .text).notNull()
                t.column("icon", .text).notNull()
                t.column("description", .text).notNull()
                t.column("instructions", .text).notNull()
                t.column("model", .text).notNull()
                t.column("browser", .boolean).notNull()
                t.column("trading", .boolean).notNull()
                t.column("status", .text).notNull()
                t.column("isDefault", .boolean).notNull()
                t.column("templateId", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.alter(table: "conversation") { t in
                t.add(column: "agentId", .text).indexed().references("agent", onDelete: .cascade)
                t.add(column: "summarizedAt", .datetime)
            }
        }
        m.registerMigration("v4-memory") { db in
            try db.create(table: "agentMemory") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("agentId", .text).notNull().indexed().references("agent", onDelete: .cascade)
                t.column("text", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.alter(table: "conversation") { t in
                t.add(column: "summarizedThrough", .integer).notNull().defaults(to: 0)
            }
        }
        m.registerMigration("v5-skills") { db in
            try db.create(table: "skill") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull().unique()
                t.column("description", .text).notNull()
                t.column("source", .text).notNull()
                t.column("status", .text).notNull()
                t.column("hasScripts", .boolean).notNull()
                t.column("createdByAgentId", .text).references("agent", onDelete: .setNull)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(table: "agentSkill") { t in
                t.column("agentId", .text).notNull().references("agent", onDelete: .cascade)
                t.column("skillId", .text).notNull().indexed().references("skill", onDelete: .cascade)
                t.primaryKey(["agentId", "skillId"])
            }
        }
        m.registerMigration("v6-trading") { db in
            try db.create(table: "tradingMandate") { t in
                t.primaryKey("agentId", .text).references("agent", onDelete: .cascade)
                t.column("network", .text).notNull()
                t.column("mode", .text).notNull()
                t.column("maxRiskPct", .double).notNull()
                t.column("maxLeverage", .integer).notNull()
                t.column("coins", .text).notNull()
                t.column("maxTradesPerDay", .integer).notNull()
                t.column("paused", .boolean).notNull()
                t.column("address", .text)
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(table: "tradeProposal") { t in
                t.primaryKey("id", .text)
                t.column("agentId", .text).notNull().indexed().references("agent", onDelete: .cascade)
                t.column("network", .text).notNull()
                t.column("coin", .text).notNull()
                t.column("side", .text).notNull()
                t.column("sizeUsd", .double).notNull()
                t.column("leverage", .integer).notNull()
                t.column("entryType", .text).notNull()
                t.column("entryPrice", .double)
                t.column("stopLoss", .double).notNull()
                t.column("takeProfit", .double)
                t.column("rationale", .text).notNull()
                t.column("riskUsd", .double).notNull()
                t.column("referencePrice", .double).notNull()
                t.column("status", .text).notNull()
                t.column("auto", .boolean).notNull()
                t.column("orderIds", .text).notNull()
                t.column("filledSize", .text)
                t.column("avgPrice", .text)
                t.column("error", .text)
                t.column("executedAt", .datetime)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
        }
        m.registerMigration("v7-scheduled-tasks") { db in
            try db.create(table: "scheduledTask") { t in
                t.primaryKey("id", .text)
                t.column("agentId", .text).notNull().indexed().references("agent", onDelete: .cascade)
                t.column("name", .text).notNull()
                t.column("instruction", .text).notNull()
                t.column("schedule", .text).notNull()
                t.column("model", .text).notNull()
                t.column("status", .text).notNull()
                t.column("maxRunsPerDay", .integer).notNull()
                t.column("lastRunAt", .datetime)
                t.column("nextRunAt", .datetime)
                t.column("createdByAgentId", .text).references("agent", onDelete: .setNull)
                t.column("templateKey", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(table: "taskRun") { t in
                t.primaryKey("id", .text)
                t.column("taskId", .text).notNull().indexed().references("scheduledTask", onDelete: .cascade)
                t.column("agentRunId", .text)
                t.column("status", .text).notNull()
                t.column("summary", .text)
                t.column("notified", .boolean).notNull()
                t.column("conversationId", .text).references("conversation", onDelete: .setNull)
                t.column("costUsd", .double).notNull()
                t.column("startedAt", .datetime).notNull()
                t.column("finishedAt", .datetime)
            }
        }
        m.registerMigration("v8-agent-folders") { db in
            try db.create(table: "agentFolder") { t in
                t.column("agentId", .text).notNull().references("agent", onDelete: .cascade)
                t.column("path", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.primaryKey(["agentId", "path"])
            }
        }
        m.registerMigration("v9-lab") { db in
            try db.alter(table: "skill") { t in
                t.add(column: "version", .integer).notNull().defaults(to: 1)
            }
            try db.create(table: "labTopic") { t in
                t.primaryKey("id", .text)
                t.column("agentId", .text).notNull().references("agent", onDelete: .cascade)
                t.column("question", .text).notNull()
                t.column("why", .text).notNull()
                t.column("origin", .text).notNull()
                t.column("status", .text).notNull()
                t.column("conclusion", .text)
                t.column("sessions", .integer).notNull().defaults(to: 0)
                t.column("tokensUsed", .integer).notNull().defaults(to: 0)
                t.column("nextSessionAfter", .datetime)
                t.column("consecutiveFailures", .integer).notNull().defaults(to: 0)
                t.column("pausedReason", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(index: "labTopic_agentId", on: "labTopic", columns: ["agentId"])
            try db.create(table: "labSession") { t in
                t.primaryKey("id", .text)
                t.column("topicId", .text).notNull().references("labTopic", onDelete: .cascade)
                t.column("agentRunId", .text)
                t.column("status", .text).notNull()
                t.column("tokens", .integer).notNull().defaults(to: 0)
                t.column("models", .text).notNull()
                t.column("outcome", .text)
                t.column("summary", .text)
                t.column("startedAt", .datetime).notNull()
                t.column("finishedAt", .datetime)
            }
            try db.create(index: "labSession_topicId", on: "labSession", columns: ["topicId"])
            try db.create(table: "labEntry") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("topicId", .text).notNull().references("labTopic", onDelete: .cascade)
                t.column("sessionId", .text)
                t.column("kind", .text).notNull()
                t.column("text", .text).notNull()
                t.column("evidence", .text)
                t.column("sources", .text).notNull()
                t.column("model", .text)
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(index: "labEntry_topicId", on: "labEntry", columns: ["topicId"])
            try db.create(table: "skillProposal") { t in
                t.primaryKey("id", .text)
                t.column("agentId", .text).notNull()
                t.column("topicId", .text)
                t.column("kind", .text).notNull()
                t.column("skillName", .text).notNull()
                t.column("description", .text).notNull()
                t.column("body", .text).notNull()
                t.column("files", .text).notNull()
                t.column("evidenceSummary", .text).notNull()
                t.column("baseVersion", .integer)
                t.column("status", .text).notNull()
                t.column("comment", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("decidedAt", .datetime)
            }
            try db.create(table: "skillVersion") { t in
                t.primaryKey("id", .text)
                t.column("skillId", .text).notNull().references("skill", onDelete: .cascade)
                t.column("number", .integer).notNull()
                t.column("proposalId", .text)
                t.column("snapshotPath", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "agentLabSettings") { t in
                t.primaryKey("agentId", .text).references("agent", onDelete: .cascade)
                t.column("sessionTokenCap", .integer).notNull()
                t.column("dailyTokenCap", .integer).notNull()
                t.column("maxOpenTopics", .integer).notNull()
                t.column("enabled", .boolean).notNull()
                t.column("allowOpus", .boolean).notNull()
            }
        }
        return m
    }

    public func ensureDefaultWorkspace() throws -> Workspace {
        try writer.write { db in
            if let existing = try Workspace.order(Column("createdAt")).fetchOne(db) { return existing }
            let ws = Workspace(id: UUID().uuidString, name: "Mi espacio", createdAt: .dbNow())
            try ws.insert(db)
            return ws
        }
    }
}

extension Date {
    /// "Ahora" pasado por la codificación de GRDB (texto con milisegundos), para que un
    /// registro recién creado sea idéntico, bit a bit, al que se lee de la base.
    static func dbNow() -> Date {
        Date.fromDatabaseValue(Date().databaseValue) ?? Date()
    }
}
