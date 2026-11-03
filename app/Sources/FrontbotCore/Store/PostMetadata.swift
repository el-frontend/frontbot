import Foundation

/// Momento de una lectura de métricas: a las 24/48/72 h de publicado o a pedido.
public enum MetricsCheckpoint: String, Codable, CaseIterable, Sendable {
    case h24 = "24h", h48 = "48h", h72 = "72h", manual

    public var hours: Int? {
        switch self {
        case .h24: 24
        case .h48: 48
        case .h72: 72
        case .manual: nil
        }
    }
}

/// Una lectura. Lo que no se vio en la página queda nil (nunca estimado).
public struct MetricsReading: Equatable, Sendable {
    public var checkpoint: MetricsCheckpoint
    public var readAt: Date
    public var reach: Int?
    public var views: Int?
    public var likes: Int?
    public var reposts: Int?
    public var sourceUrl: String?
    public var note: String?

    public init(checkpoint: MetricsCheckpoint, readAt: Date, reach: Int?, views: Int?, likes: Int?, reposts: Int?,
                sourceUrl: String?, note: String?) {
        self.checkpoint = checkpoint
        self.readAt = readAt
        self.reach = reach
        self.views = views
        self.likes = likes
        self.reposts = reposts
        self.sourceUrl = sourceUrl
        self.note = note
    }
}

public struct PostMetadata: Equatable, Sendable {
    public var publishedAt: Date?
    public var metrics: [MetricsReading]
    public var skipped: [MetricsCheckpoint]

    public init(publishedAt: Date?, metrics: [MetricsReading], skipped: [MetricsCheckpoint]) {
        self.publishedAt = publishedAt
        self.metrics = metrics
        self.skipped = skipped
    }

    public static let empty = PostMetadata(publishedAt: nil, metrics: [], skipped: [])
}

/// `posts/<id>/metadata.json`. Se lee y escribe como objeto abierto: las claves que la app no conoce se conservan.
public struct PostMetadataStore: Sendable {
    let paths: AppPaths

    public init(paths: AppPaths) {
        self.paths = paths
    }

    public func read(postId: String) -> PostMetadata {
        guard let object = try? load(postId: postId) else { return .empty }
        return Self.decode(object)
    }

    public func setPublishedAt(postId: String, _ date: Date) throws {
        try update(postId: postId) { $0["published_at"] = Self.iso(date) }
    }

    public func record(postId: String, _ reading: MetricsReading) throws {
        try update(postId: postId) { object in
            var metrics = object["metrics"] as? [Any] ?? []
            metrics.append(Self.encode(reading))
            object["metrics"] = metrics
        }
    }

    public func skip(postId: String, _ checkpoints: [MetricsCheckpoint]) throws {
        guard !checkpoints.isEmpty else { return }
        try update(postId: postId) { object in
            var skipped = object["skipped"] as? [String] ?? []
            for c in checkpoints where !skipped.contains(c.rawValue) { skipped.append(c.rawValue) }
            object["skipped"] = skipped
        }
    }

    // MARK: Archivo

    /// nil si no existe; lanza si existe pero no es un objeto JSON.
    private func load(postId: String) throws -> [String: Any]? {
        let url = paths.postMetadata(postId)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw ValidationError(String(localized: "La metadata del post está dañada; no se sobrescribe."))
        }
        return object
    }

    private func update(postId: String, _ change: (inout [String: Any]) -> Void) throws {
        var object = try load(postId: postId) ?? [:]
        change(&object)
        let url = paths.postMetadata(postId)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    // MARK: Formato

    private static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
    private static func date(_ value: Any?) -> Date? { (value as? String).flatMap { ISO8601DateFormatter().date(from: $0) } }
    private static func int(_ value: Any?) -> Int? { (value as? NSNumber).map { max(0, $0.intValue) } }

    private static func encode(_ r: MetricsReading) -> [String: Any] {
        func orNull(_ v: Any?) -> Any { v ?? NSNull() }
        return ["checkpoint": r.checkpoint.rawValue, "read_at": iso(r.readAt), "reach": orNull(r.reach), "views": orNull(r.views),
                "likes": orNull(r.likes), "reposts": orNull(r.reposts), "source_url": orNull(r.sourceUrl), "note": orNull(r.note)]
    }

    private static func decode(_ object: [String: Any]) -> PostMetadata {
        let metrics = (object["metrics"] as? [[String: Any]] ?? []).compactMap { m -> MetricsReading? in
            guard let checkpoint = (m["checkpoint"] as? String).flatMap(MetricsCheckpoint.init(rawValue:)),
                  let readAt = date(m["read_at"]) else { return nil }
            return MetricsReading(checkpoint: checkpoint, readAt: readAt, reach: int(m["reach"]), views: int(m["views"]),
                                  likes: int(m["likes"]), reposts: int(m["reposts"]),
                                  sourceUrl: m["source_url"] as? String, note: m["note"] as? String)
        }
        let skipped = (object["skipped"] as? [String] ?? []).compactMap(MetricsCheckpoint.init(rawValue:))
        return PostMetadata(publishedAt: date(object["published_at"]), metrics: metrics, skipped: skipped)
    }
}
