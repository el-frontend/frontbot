import Foundation

/// Qué lectura automática toca a un post publicado. Si la app estuvo cerrada y se pasaron varios momentos,
/// solo se lee el más reciente; los anteriores quedan saltados.
public enum MetricsSchedule {
    public static let interval: Duration = .seconds(15 * 60)
    static let automatic: [MetricsCheckpoint] = [.h24, .h48, .h72]
    /// Un momento sigue pendiente hasta 24 h después de su hora; luego se da por saltado.
    static let windowHours = 24.0

    public static func due(_ meta: PostMetadata, now: Date) -> (checkpoint: MetricsCheckpoint, skip: [MetricsCheckpoint])? {
        guard let published = meta.publishedAt else { return nil }
        let elapsed = now.timeIntervalSince(published) / 3600
        let done = Set(meta.metrics.map(\.checkpoint)).union(meta.skipped)
        let passed = automatic.filter { Double($0.hours!) <= elapsed }
        guard let candidate = passed.last, !done.contains(candidate),
              elapsed < Double(candidate.hours!) + windowHours else { return nil }
        // Ya hay uno posterior hecho (no debería pasar, pero no se vuelve atrás).
        if automatic.drop(while: { $0 != candidate }).dropFirst().contains(where: done.contains) { return nil }
        return (candidate, passed.dropLast().filter { !done.contains($0) })
    }

    /// Momentos automáticos sin leer cuya ventana ya pasó: se marcan como saltados.
    public static func stale(_ meta: PostMetadata, now: Date) -> [MetricsCheckpoint] {
        guard let published = meta.publishedAt else { return [] }
        let elapsed = now.timeIntervalSince(published) / 3600
        let done = Set(meta.metrics.map(\.checkpoint)).union(meta.skipped)
        return automatic.filter { !done.contains($0) && elapsed >= Double($0.hours!) + windowHours }
    }

    /// Una lectura automática solo arranca con un agente Claude (Chrome) y sin ningún otro run activo.
    public static func canStart(activeRuns: Int, provider: AgentProvider) -> Bool {
        activeRuns == 0 && provider == .claude
    }
}

/// Intentos automáticos que no guardaron nada (sin Chrome, detenidos, con error). Cada uno cuesta un run:
/// se espera una hora entre intentos y hay como mucho 4 por momento. Vive en memoria (se reinicia con la app).
public struct MetricsAttempts: Sendable {
    public static let retryAfter: TimeInterval = 3600
    public static let maxAttempts = 4

    private var attempts: [String: (count: Int, last: Date)] = [:]

    public init() {}

    public func allows(postId: String, _ checkpoint: MetricsCheckpoint, now: Date) -> Bool {
        guard let a = attempts[key(postId, checkpoint)] else { return true }
        return a.count < Self.maxAttempts && now.timeIntervalSince(a.last) >= Self.retryAfter
    }

    public mutating func failed(postId: String, _ checkpoint: MetricsCheckpoint, at date: Date) {
        let k = key(postId, checkpoint)
        attempts[k] = ((attempts[k]?.count ?? 0) + 1, date)
    }

    private func key(_ postId: String, _ checkpoint: MetricsCheckpoint) -> String { "\(postId)|\(checkpoint.rawValue)" }
}
