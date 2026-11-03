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
        /// El último error de una herramienta: el agente puede terminar bien aunque una imagen haya fallado.
        var lastToolError: String? = nil
        /// El usuario pulsó Detener: el final no cuenta como fallo.
        var stopped = false
    }

    private var jobs: [String: Job] = [:]

    public init() {}

    public func job(postId: String) -> Job? { jobs[postId] }

    /// false si ese post ya tiene un trabajo en marcha. Lo pendiente de uno anterior se conserva.
    public mutating func begin(postId: String, runId: String, total: Int) -> Bool {
        guard reserve(postId: postId, total: total) else { return false }
        attach(postId: postId, runId: runId)
        return true
    }

    /// Marca el post como ocupado antes de lanzar el run (aún sin id): un segundo clic no lanza otro.
    public mutating func reserve(postId: String, total: Int) -> Bool {
        if jobs[postId]?.running == true { return false }
        jobs[postId] = Job(runId: "", total: total, done: 0, running: true, error: nil, pending: jobs[postId]?.pending ?? [])
        return true
    }

    public mutating func attach(postId: String, runId: String) {
        jobs[postId]?.runId = runId
    }

    /// El run no llegó a lanzarse.
    public mutating func failStart(postId: String, error: String) {
        jobs[postId]?.running = false
        jobs[postId]?.error = error
    }

    public mutating func toolFailed(runId: String, message: String) {
        guard let postId = postId(runId: runId) else { return }
        jobs[postId]?.lastToolError = message
    }

    public mutating func stop(postId: String) {
        jobs[postId]?.stopped = true
    }

    public mutating func created(runId: String, assetId: String) {
        guard let postId = postId(runId: runId) else { return }
        jobs[postId]?.done += 1
        jobs[postId]?.pending.append(assetId)
    }

    public mutating func finish(runId: String, error: String?) {
        guard let postId = postId(runId: runId), var job = jobs[postId] else { return }
        job.running = false
        if job.stopped {
            job.error = nil
        } else if let error {
            job.error = error
        } else if job.done < job.total {
            job.error = job.lastToolError ?? String(localized: "Se crearon \(job.done) de \(job.total) imágenes.")
        }
        jobs[postId] = job
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
        guard !runId.isEmpty else { return nil }
        return jobs.first { $0.value.runId == runId }?.key
    }
}
