import Foundation

/// Lo que la app fija para un run de métricas: qué post y qué momento. El agente no elige ninguno.
public struct MetricsRunPlan: Equatable, Sendable {
    public var postId: String
    public var checkpoint: MetricsCheckpoint

    public init(postId: String, checkpoint: MetricsCheckpoint) {
        self.postId = postId
        self.checkpoint = checkpoint
    }
}

public enum MetricsToolOutcome: Equatable, Sendable {
    case recorded
    /// No había Chrome conectado: no se guardó nada y la lectura automática se pospone.
    case unavailable
}

/// `tool.metrics_post` y `tool.posts_record_metrics`: solo existen dentro de un run de métricas.
public actor MetricsTool {
    let db: AppDatabase
    let store: PostMetadataStore
    private var plans: [String: MetricsRunPlan] = [:]
    private var recorded: Set<String> = []

    public init(db: AppDatabase, store: PostMetadataStore) {
        self.db = db
        self.store = store
    }

    public func beginRun(_ runId: String, plan: MetricsRunPlan) {
        plans[runId] = plan
    }

    public func endRun(_ runId: String) {
        plans[runId] = nil
        recorded.remove(runId)
    }

    public func handle(method: String, params: JSONValue, now: Date = Date()) throws -> (result: JSONValue, outcome: MetricsToolOutcome?) {
        guard let runId = params["run_id"]?.stringValue, let plan = plans[runId] else {
            throw ValidationError("Esta herramienta solo existe en una lectura de métricas.")
        }
        guard let post = try db.posts(brandId: nil, status: nil).first(where: { $0.id == plan.postId }) else {
            throw ValidationError("El post \(plan.postId) ya no existe.")
        }
        switch method {
        case "tool.metrics_post":
            let brand = try db.brand(id: post.brandId)
            let meta = store.read(postId: post.id)
            return (["post_id": .string(post.id), "network": .string(post.network.rawValue), "body": .string(post.body),
                     "published_url": post.publishedUrl.map(JSONValue.string) ?? .null,
                     "published_at": meta.publishedAt.map { .string(ToolHandler.isoString($0)) } ?? .null,
                     "checkpoint": .string(plan.checkpoint.rawValue),
                     "brand": ["name": .string(brand?.name ?? ""), "links": .array((brand?.links ?? []).map(JSONValue.string))]], nil)
        case "tool.posts_record_metrics":
            guard params["post_id"]?.stringValue == plan.postId else {
                throw ValidationError("En esta lectura solo puedes guardar métricas del post \(plan.postId).")
            }
            guard !recorded.contains(runId) else { throw ValidationError("Ya guardaste la lectura de esta corrida.") }
            if params["unavailable"]?.boolValue == true {
                recorded.insert(runId)
                return (["ok": true, "saved": false], .unavailable)
            }
            func count(_ key: String) throws -> Int? {
                guard let value = params[key], value != .null else { return nil }
                guard let n = value.doubleValue, n >= 0, n.isFinite else {
                    throw ValidationError("\(key) debe ser un número entero de 0 o más, o null si no se ve.")
                }
                return Int(n)
            }
            let reading = MetricsReading(checkpoint: plan.checkpoint, readAt: now,
                                         reach: try count("reach"), views: try count("views"),
                                         likes: try count("likes"), reposts: try count("reposts"),
                                         sourceUrl: params["source_url"]?.stringValue, note: params["note"]?.stringValue)
            try store.record(postId: plan.postId, reading)
            recorded.insert(runId)
            return (["ok": true, "saved": true], .recorded)
        default:
            throw ValidationError("Herramienta desconocida: \(method)")
        }
    }
}
