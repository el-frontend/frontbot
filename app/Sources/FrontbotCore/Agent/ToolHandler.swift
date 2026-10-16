import Foundation

/// Atiende las llamadas `tool.*` que hace el sidecar del agente, contra el store.
/// No existe ninguna herramienta que apruebe ni publique posts.
public struct ToolHandler: Sendable {
    let db: AppDatabase
    let files: BrandFiles
    let workspaceId: String

    public init(db: AppDatabase, files: BrandFiles, workspaceId: String) {
        self.db = db
        self.files = files
        self.workspaceId = workspaceId
    }

    public func handle(method: String, params: JSONValue) throws -> JSONValue {
        switch method {
        case "tool.brands_list":
            let brands = try db.brands(workspaceId: workspaceId)
            return ["brands": .array(brands.map { b in
                ["id": .string(b.id), "name": .string(b.name), "industry": .string(b.industry),
                 "networks": .array(b.networks.map { .string($0.rawValue) })]
            })]
        case "tool.brands_get_guide":
            let id = try string(params, "brand_id")
            return ["guide": try files.readGuide(brandId: id).map(JSONValue.string) ?? .null]
        case "tool.brands_write_guide":
            let id = try string(params, "brand_id")
            guard try db.brand(id: id) != nil else { throw ValidationError("No existe marca con id \(id).") }
            try files.writeGuide(brandId: id, markdown: try string(params, "markdown"))
            return ["ok": true]
        case "tool.brands_list_assets":
            let id = try string(params, "brand_id")
            let assets = try db.assets(brandId: id, kind: nil)
            return ["assets": .array(assets.map { a in
                ["id": .string(a.id), "kind": .string(a.kind), "file_name": .string(URL(fileURLWithPath: a.path).lastPathComponent)]
            })]
        case "tool.posts_list":
            let status = try params["status"]?.stringValue.map(parseStatus)
            let posts = try db.posts(brandId: params["brand_id"]?.stringValue, status: status)
            return ["posts": .array(posts.map { p in
                ["id": .string(p.id), "brand_id": .string(p.brandId), "network": .string(p.network.rawValue),
                 "body": .string(p.body), "status": .string(p.status.rawValue),
                 "scheduled_for": p.scheduledFor.map { .string(Self.isoString($0)) } ?? .null]
            })]
        case "tool.posts_create_draft":
            let post = try db.createDraft(
                brandId: try string(params, "brand_id"), network: try parseNetwork(try string(params, "network")),
                body: try string(params, "body"), media: mediaIds(params) ?? [], scheduledFor: try optionalDate(params, "scheduled_for"))
            return ["post_id": .string(post.id)]
        case "tool.posts_update_draft":
            _ = try db.updateDraft(id: try string(params, "post_id"), body: params["body"]?.stringValue,
                                   media: mediaIds(params), scheduledFor: try optionalDate(params, "scheduled_for"))
            return ["ok": true]
        case "tool.tasks_list":
            let day = try optionalDate(params, "date")
            let tasks = try db.tasks(workspaceId: workspaceId, on: day)
            return ["tasks": .array(tasks.map { t in
                ["id": .string(t.id), "title": .string(t.title), "done": .bool(t.done),
                 "due_date": t.dueDate.map { .string(Self.isoString($0)) } ?? .null]
            })]
        case "tool.tasks_create":
            let task = try db.createTask(workspaceId: workspaceId, title: try string(params, "title"),
                                         dueDate: try optionalDate(params, "due_date"), brandId: params["brand_id"]?.stringValue)
            return ["task_id": .string(task.id)]
        case "tool.tasks_complete":
            _ = try db.completeTask(id: try string(params, "task_id"))
            return ["ok": true]
        case "tool.ideas_create":
            guard let score = params["score"]?.intValue else { throw ValidationError("Falta el parámetro score.") }
            let sources = (params["sources"]?.arrayValue ?? []).compactMap(\.stringValue)
            let idea = try db.createIdea(workspaceId: workspaceId, title: try string(params, "title"),
                                         summary: try string(params, "summary"), sources: sources, score: score)
            let url = try files.writeIdeaReport(ideaId: idea.id, markdown: try string(params, "report_markdown"))
            try db.setIdeaReportPath(id: idea.id, path: url.path)
            return ["idea_id": .string(idea.id)]
        default:
            throw ValidationError("Herramienta desconocida: \(method).")
        }
    }

    // MARK: Helpers

    static func isoString(_ date: Date) -> String {
        date.formatted(.iso8601)
    }

    private func string(_ params: JSONValue, _ key: String) throws -> String {
        guard let value = params[key]?.stringValue else { throw ValidationError("Falta el parámetro \(key).") }
        return value
    }

    private func mediaIds(_ params: JSONValue) -> [String]? {
        params["media"]?.arrayValue?.compactMap(\.stringValue)
    }

    private func parseNetwork(_ raw: String) throws -> Network {
        guard let n = Network(rawValue: raw) else { throw ValidationError("Red no soportada: \(raw). Usa instagram o linkedin.") }
        return n
    }

    private func parseStatus(_ raw: String) throws -> PostStatus {
        guard let s = PostStatus(rawValue: raw) else { throw ValidationError("Estado desconocido: \(raw).") }
        return s
    }

    /// Acepta ISO-8601 con zona ("2026-10-20T09:00:00Z"), fecha y hora sin zona (hora local)
    /// o solo fecha ("2026-10-20", hora local 09:00).
    private func optionalDate(_ params: JSONValue, _ key: String) throws -> Date? {
        guard let raw = params[key]?.stringValue else { return nil }
        if let d = try? Date(raw, strategy: .iso8601) { return d }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm"] {
            fmt.dateFormat = format
            if let d = fmt.date(from: raw) { return d }
        }
        fmt.dateFormat = "yyyy-MM-dd"
        if let d = fmt.date(from: raw) { return Calendar.current.date(byAdding: .hour, value: 9, to: d) }
        throw ValidationError("Fecha inválida en \(key): \(raw). Usa YYYY-MM-DD o ISO-8601.")
    }
}
