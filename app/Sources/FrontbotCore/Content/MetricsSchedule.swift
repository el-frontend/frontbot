import Foundation

/// Qué lectura automática toca a un post publicado. Si la app estuvo cerrada y se pasaron varios momentos,
/// solo se lee el más reciente; los anteriores quedan saltados.
public enum MetricsSchedule {
    public static let interval: Duration = .seconds(15 * 60)
    static let automatic: [MetricsCheckpoint] = [.h24, .h48, .h72]

    public static func due(_ meta: PostMetadata, now: Date) -> (checkpoint: MetricsCheckpoint, skip: [MetricsCheckpoint])? {
        guard let published = meta.publishedAt else { return nil }
        let elapsed = now.timeIntervalSince(published) / 3600
        let done = Set(meta.metrics.map(\.checkpoint)).union(meta.skipped)
        let passed = automatic.filter { Double($0.hours!) <= elapsed }
        guard let candidate = passed.last, !done.contains(candidate) else { return nil }
        // Ya hay uno posterior hecho (no debería pasar, pero no se vuelve atrás).
        if automatic.drop(while: { $0 != candidate }).dropFirst().contains(where: done.contains) { return nil }
        return (candidate, passed.dropLast().filter { !done.contains($0) })
    }

    /// Una lectura automática solo arranca con un agente Claude (Chrome) y sin ningún otro run activo.
    public static func canStart(activeRuns: Int, provider: AgentProvider) -> Bool {
        activeRuns == 0 && provider == .claude
    }
}
