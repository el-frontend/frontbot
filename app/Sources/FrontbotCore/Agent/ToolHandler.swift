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

    var skills: SkillLibrary { SkillLibrary(db: db, paths: files.paths) }

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
        case "tool.memory_list":
            let memories = try db.memories(agentId: try string(params, "agent_id"))
            return ["memories": .array(memories.map { m in
                ["id": .number(Double(m.id ?? 0)), "text": .string(m.text), "date": .string(Self.isoString(m.createdAt))]
            })]
        case "tool.memory_remember":
            let result = try db.remember(agentId: try string(params, "agent_id"), text: try string(params, "text"))
            return ["memory_id": .number(Double(result.memory.id ?? 0)), "evicted_oldest": .bool(result.evictedOldest)]
        case "tool.memory_forget":
            guard let id = params["memory_id"]?.intValue else { throw ValidationError("Falta el parámetro memory_id.") }
            try db.forget(agentId: try string(params, "agent_id"), memoryId: Int64(id))
            return ["ok": true]
        case "tool.skills_list":
            let agentId = try string(params, "agent_id")
            let assigned = Set(try skills.skills(assignedTo: agentId, activeOnly: false).map(\.id))
            return ["skills": .array(try skills.all().map { sk in
                ["name": .string(sk.name), "description": .string(sk.description), "status": .string(sk.status.rawValue),
                 "assigned": .bool(assigned.contains(sk.id)), "has_scripts": .bool(sk.hasScripts),
                 "mine": .bool(sk.createdByAgentId == agentId)]
            })]
        case "tool.skills_create_draft":
            let skill = try skills.createDraft(agentId: try string(params, "agent_id"), name: try string(params, "name"),
                                               description: try string(params, "description"), body: try string(params, "body"),
                                               files: try stringMap(params, "files") ?? [:])
            return ["name": .string(skill.name), "status": "draft",
                    "note": "Quedó en borrador: el usuario debe revisarlo y activarlo para que se cargue."]
        case "tool.skills_update_draft":
            let skill = try skills.updateDraft(agentId: try string(params, "agent_id"), name: try string(params, "name"),
                                               description: params["description"]?.stringValue, body: params["body"]?.stringValue,
                                               files: try stringMap(params, "files"))
            return ["name": .string(skill.name), "status": .string(skill.status.rawValue)]
        case "tool.schedule_list":
            let tasks = try db.tasks(agentId: try string(params, "agent_id"))
            return ["tasks": .array(tasks.map { t in
                ["task_id": .string(t.id), "name": .string(t.name), "instruction": .string(t.instruction), "schedule": .string(t.schedule.agentSummary),
                 "status": .string(t.status.rawValue), "next_run": t.nextRunAt.map { .string(Self.isoString($0)) } ?? .null]
            })]
        case "tool.schedule_create_draft":
            guard let schedule = params["schedule"] else { throw ValidationError("Falta el parámetro schedule.") }
            let agentId = try string(params, "agent_id")
            let draft = TaskDraft(name: try string(params, "name"), instruction: try string(params, "instruction"),
                                  schedule: try Schedule.parse(schedule), model: params["model"]?.stringValue,
                                  maxRunsPerDay: params["max_runs_per_day"]?.intValue ?? 24)
            let task = try db.createTask(agentId: agentId, draft: draft, status: .draft, createdBy: agentId)
            return ["task_id": .string(task.id), "status": "draft", "schedule": .string(task.schedule.agentSummary),
                    "note": "Quedó en borrador: el usuario debe activarla en la página del agente."]
        case "tool.schedule_update_draft":
            let agentId = try string(params, "agent_id")
            guard let task = try db.task(id: try string(params, "task_id")), task.agentId == agentId else { throw ValidationError("No tienes esa tarea.") }
            guard task.status == .draft else { throw ValidationError("Esa tarea ya está activa: solo el usuario puede cambiarla.") }
            var draft = TaskDraft(task: task)
            if let name = params["name"]?.stringValue { draft.name = name }
            if let instruction = params["instruction"]?.stringValue { draft.instruction = instruction }
            if let schedule = params["schedule"], schedule != .null { draft.schedule = try Schedule.parse(schedule) }
            if let model = params["model"]?.stringValue { draft.model = model }
            if let max = params["max_runs_per_day"]?.intValue { draft.maxRunsPerDay = max }
            let updated = try db.updateTask(id: task.id, draft: draft)
            return ["task_id": .string(updated.id), "status": "draft", "schedule": .string(updated.schedule.agentSummary)]
        case "tool.agents_create_draft":
            let caller = try string(params, "agent_id")
            guard try db.agent(id: caller)?.isDefault == true else { throw ValidationError("Solo Frontbot puede crear agentes.") }
            let draft = AgentDraft(name: try string(params, "name"), icon: params["icon"]?.stringValue ?? "person.crop.circle",
                                   description: params["description"]?.stringValue ?? "", instructions: try string(params, "instructions"),
                                   model: params["model"]?.stringValue ?? AgentConfig.defaultModel,
                                   browser: params["browser"]?.boolValue ?? false)
            let agent = try db.createAgent(workspaceId: workspaceId, draft: draft, status: .draft)
            return ["agent_id": .string(agent.id), "status": "draft"]
        case "tool.files_folders":
            return ["folders": .array(try db.folders(agentId: try string(params, "agent_id")).map(JSONValue.string))]
        case "tool.files_list":
            let listing = try agentFiles(params).list(try string(params, "path"))
            return ["path": .string(listing.path), "truncated": .bool(listing.truncated), "entries": .array(listing.entries.map { e in
                var entry: [String: JSONValue] = ["name": .string(e.name), "type": .string(e.kind.rawValue)]
                if let size = e.size { entry["size"] = .number(Double(size)) }
                return .object(entry)
            })]
        case "tool.files_read":
            let contents = try agentFiles(params).read(try string(params, "path"))
            return ["path": .string(contents.path), "content": .string(contents.text), "truncated": .bool(contents.truncated)]
        default:
            if method.hasPrefix("tool.lab_") { return try LabToolHandler(db: db, paths: files.paths).handle(method: method, params: params) }
            throw ValidationError("Herramienta desconocida: \(method).")
        }
    }

    // MARK: Helpers

    private func agentFiles(_ params: JSONValue) throws -> AgentFiles {
        try AgentFiles.forAgent(try string(params, "agent_id"), db: db, paths: files.paths)
    }

    static func isoString(_ date: Date) -> String {
        date.formatted(.iso8601)
    }

    private func stringMap(_ params: JSONValue, _ key: String) throws -> [String: String]? {
        guard let value = params[key], value != .null else { return nil }
        guard case .object(let dict) = value else { throw ValidationError("\(key) debe ser un objeto ruta → texto.") }
        return try dict.mapValues { v in
            guard let text = v.stringValue else { throw ValidationError("Cada archivo de \(key) debe ser texto.") }
            return text
        }
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
