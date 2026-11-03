import Foundation

/// Las imágenes que se están creando para cada post. Vive en la app, no en el editor: si lo cierras a mitad,
/// lo creado queda pendiente y se selecciona al reabrir ese post (sin guardar el post).
public struct ImageJobs: Sendable {
    public struct Job: Equatable, Sendable {
        public var runId: String
        public var total: Int
        /// Cuántas se crearon en este trabajo (las tomadas también cuentan).
        public var done: Int
        public var running: Bool
        public var error: String?
        /// Creadas que el editor aún no agregó al post, en orden.
        var pending: [String]
    }

    private var jobs: [String: Job] = [:]

    public init() {}

    public func job(postId: String) -> Job? { jobs[postId] }

    /// false si ese post ya tiene un trabajo en marcha. Lo pendiente de uno anterior se conserva.
    public mutating func begin(postId: String, runId: String, total: Int) -> Bool {
        if jobs[postId]?.running == true { return false }
        jobs[postId] = Job(runId: runId, total: total, done: 0, running: true, error: nil, pending: jobs[postId]?.pending ?? [])
        return true
    }

    public mutating func created(runId: String, assetId: String) {
        guard let postId = postId(runId: runId) else { return }
        jobs[postId]?.done += 1
        jobs[postId]?.pending.append(assetId)
    }

    public mutating func finish(runId: String, error: String?) {
        guard let postId = postId(runId: runId) else { return }
        jobs[postId]?.running = false
        jobs[postId]?.error = error
    }

    /// Lo pendiente de ese post, una sola vez. Un trabajo terminado sin error desaparece al tomarlo.
    public mutating func take(postId: String) -> [String] {
        guard var job = jobs[postId] else { return [] }
        let taken = job.pending
        job.pending = []
        jobs[postId] = !job.running && job.error == nil ? nil : job
        return taken
    }

    /// El aviso de error se cierra a mano.
    public mutating func dismissError(postId: String) {
        jobs[postId]?.error = nil
        if jobs[postId]?.running == false, jobs[postId]?.pending.isEmpty == true { jobs[postId] = nil }
    }

    public func postId(runId: String) -> String? {
        jobs.first { $0.value.runId == runId }?.key
    }
}
