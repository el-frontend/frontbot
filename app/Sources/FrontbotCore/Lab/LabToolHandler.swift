import Foundation

/// Atiende las llamadas `tool.lab_*` del sidecar. El sidecar fija `agent_id` y, en las de estudio, `topic_id` y `session_id`.
public struct LabToolHandler: Sendable {
    public static let notInStudy = "Esta herramienta solo funciona dentro de una sesión de estudio."

    let db: AppDatabase
    let paths: AppPaths
    let nodePath: String?
    let downloader: DatasetDownloader

    public init(db: AppDatabase, paths: AppPaths, nodePath: String? = nil, downloader: DatasetDownloader = URLSessionDatasetDownloader()) {
        self.db = db
        self.paths = paths
        self.nodePath = nodePath
        self.downloader = downloader
    }

    // MARK: Síncronas

    public func handle(method: String, params: JSONValue) throws -> JSONValue {
        switch method {
        case "tool.lab_open_topic":
            let topic = try db.openTopic(agentId: try string(params, "agent_id"), question: try string(params, "question"),
                                         why: try string(params, "why"), origin: .agent, now: .dbNow())
            return ["topic_id": .string(topic.id), "status": .string(topic.status.rawValue)]
        case "tool.lab_list_topics":
            return ["topics": .array(try db.topics(agentId: try string(params, "agent_id")).map { t in
                ["topic_id": .string(t.id), "question": .string(t.question), "status": .string(t.status.rawValue),
                 "conclusion": t.conclusion.map(JSONValue.string) ?? .null, "sessions": .number(Double(t.sessions))]
            })]
        case "tool.lab_resume_topic":
            let topic = try ownedTopic(params, agentId: try string(params, "agent_id"))
            guard topic.status == .paused else { throw ValidationError("Ese tema no está pausado: está \(topic.status.rawValue).") }
            let resumed = try db.setTopicStatus(id: topic.id, .studying, reason: nil, now: .dbNow())
            return ["topic_id": .string(resumed.id), "status": .string(resumed.status.rawValue)]
        case "tool.lab_read_notebook":
            let topic = try ownedTopic(params, agentId: try string(params, "agent_id"))
            return ["entries": .array(try db.entries(topicId: topic.id).map { e in
                ["kind": .string(e.kind.rawValue), "text": .string(e.text),
                 "evidence": e.evidence.map { .string($0.rawValue) } ?? .null,
                 "sources": .array(e.sources.map(JSONValue.string)), "date": .string(ToolHandler.isoString(e.createdAt))]
            })]
        case "tool.lab_list_datasets":
            return ["datasets": .array(try datasets.list().map(Self.json))]
        case "tool.lab_note":
            let ctx = try studyContext(params)
            guard let kind = LabEntryKind(rawValue: try string(params, "kind")) else {
                throw ValidationError("kind debe ser hypothesis, test, result, conclusion, model_note, feedback o note.")
            }
            var evidence: Evidence?
            if let raw = params["evidence"]?.stringValue {
                guard let e = Evidence(rawValue: raw) else { throw ValidationError("evidence debe ser weak, medium o strong.") }
                evidence = e
            }
            let sources = (params["sources"]?.arrayValue ?? []).compactMap(\.stringValue)
            let entry = try db.addEntry(topicId: ctx.topic.id, sessionId: ctx.session.id, kind: kind, text: try string(params, "text"),
                                        evidence: evidence, sources: sources, model: nil)
            return ["entry_id": .number(Double(entry.id ?? 0))]
        case "tool.lab_write_file":
            let ctx = try studyContext(params)
            try workspace(ctx).write(try string(params, "path"), content: try string(params, "content"))
            return ["ok": true]
        case "tool.lab_read_file":
            let ctx = try studyContext(params)
            let r = try workspace(ctx).read(try string(params, "path"))
            return ["content": .string(r.text), "truncated": .bool(r.truncated)]
        case "tool.lab_list_files":
            let ctx = try studyContext(params)
            return ["files": .array(try workspace(ctx).list(params["dir"]?.stringValue).map(JSONValue.string))]
        case "tool.lab_end_session":
            let ctx = try studyContext(params)
            guard let outcome = LabOutcome(rawValue: try string(params, "outcome")) else {
                throw ValidationError("outcome debe ser continue, pause, resolve o abandon.")
            }
            let trimmed = params["conclusion"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            let conclusion = (trimmed?.isEmpty ?? true) ? nil : trimmed
            if outcome == .resolve && conclusion == nil { throw ValidationError("Para resolver el tema necesitas escribir una conclusión.") }
            try db.recordSessionEnd(id: ctx.session.id, outcome: outcome, summary: try string(params, "summary"),
                                    conclusion: conclusion, now: .dbNow())
            return ["ok": true, "note": "Sesión cerrada: termina tu respuesta."]
        case "tool.lab_propose_skill":
            let ctx = try studyContext(params)
            guard let kind = SkillProposalKind(rawValue: try string(params, "kind")) else { throw ValidationError("kind debe ser new o update.") }
            let proposal = try SkillVersions(library: SkillLibrary(db: db, paths: paths)).propose(
                agentId: ctx.topic.agentId, topicId: ctx.topic.id, kind: kind, skillName: try string(params, "skill_name"),
                description: try string(params, "description"), body: try string(params, "body"),
                files: try stringMap(params, "files") ?? [:], evidenceSummary: try string(params, "evidence_summary"))
            return ["proposal_id": .string(proposal.id), "status": "pending",
                    "note": "Quedó en propuesta: el usuario debe revisarla antes de que se active."]
        default:
            throw ValidationError("Herramienta desconocida: \(method).")
        }
    }

    // MARK: Asíncronas (sin aprobación)

    public func handleAsync(method: String, params: JSONValue) async throws -> JSONValue {
        let ctx = try studyContext(params)
        switch method {
        case "tool.lab_run":
            let args = (params["args"]?.arrayValue ?? []).compactMap(\.stringValue)
            let script = try string(params, "script")
            let sandbox = LabSandbox(paths: paths, db: db, nodePath: nodePath)
            let (agentId, topicId) = (ctx.topic.agentId, ctx.topic.id)
            // La sandbox bloquea hasta 5 min: se ejecuta fuera del actor que llama.
            let r = try await Task.detached { try sandbox.run(agentId: agentId, topicId: topicId, script: script, args: args) }.value
            return ["exit_code": .number(Double(r.exitCode)), "stdout": .string(r.stdout), "stderr": .string(r.stderr), "timed_out": .bool(r.timedOut)]
        case "tool.lab_fetch_dataset":
            let urls = (params["urls"]?.arrayValue ?? []).compactMap(\.stringValue)
            let meta = try await datasets.fetch(name: try string(params, "name"), urls: urls,
                                                description: try string(params, "description"), agentId: ctx.topic.agentId)
            return Self.json(meta)
        default:
            throw ValidationError("Herramienta desconocida: \(method).")
        }
    }

    // MARK: Helpers

    private var datasets: Datasets { Datasets(paths: paths, downloader: downloader) }

    private func workspace(_ ctx: (topic: LabTopic, session: LabSession)) -> LabWorkspace {
        LabWorkspace(paths: paths, db: db, agentId: ctx.topic.agentId, topicId: ctx.topic.id)
    }

    /// La sesión debe estar `running`, ser del tema, y el tema del agente.
    func studyContext(_ params: JSONValue) throws -> (topic: LabTopic, session: LabSession) {
        guard let agentId = params["agent_id"]?.stringValue, let topicId = params["topic_id"]?.stringValue,
              let sessionId = params["session_id"]?.stringValue,
              let session = try db.labSession(id: sessionId), session.status == .running, session.topicId == topicId,
              let topic = try db.topic(id: topicId), topic.agentId == agentId else {
            throw ValidationError(Self.notInStudy)
        }
        return (topic, session)
    }

    private func ownedTopic(_ params: JSONValue, agentId: String) throws -> LabTopic {
        let id = try string(params, "topic_id")
        guard let topic = try db.topic(id: id), topic.agentId == agentId else { throw ValidationError("No tienes ese tema.") }
        return topic
    }

    static func json(_ m: DatasetMeta) -> JSONValue {
        ["name": .string(m.name), "description": .string(m.description), "files": .array(m.files.map(JSONValue.string)),
         "bytes": .number(Double(m.bytes)), "sources": .array(m.sources.map(JSONValue.string)),
         "fetched_by_agent_id": m.fetchedByAgentId.map(JSONValue.string) ?? .null,
         "created_at": .string(ToolHandler.isoString(m.createdAt))]
    }

    private func string(_ params: JSONValue, _ key: String) throws -> String {
        guard let value = params[key]?.stringValue else { throw ValidationError("Falta el parámetro \(key).") }
        return value
    }

    private func stringMap(_ params: JSONValue, _ key: String) throws -> [String: String]? {
        guard let value = params[key], value != .null else { return nil }
        guard case .object(let dict) = value else { throw ValidationError("\(key) debe ser un objeto ruta → texto.") }
        return try dict.mapValues { v in
            guard let text = v.stringValue else { throw ValidationError("Cada archivo de \(key) debe ser texto.") }
            return text
        }
    }
}
