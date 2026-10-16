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
