import Foundation

/// Descarga un recurso público a un archivo local. Solo la app lo usa; los scripts del agente nunca tocan la red.
public protocol DatasetDownloader: Sendable {
    func download(_ url: URL, to file: URL, maxBytes: Int) async throws
}

/// Implementación real: sesión efímera sin cookies ni credenciales, solo https, HTTP 200 y tope de bytes.
public struct URLSessionDatasetDownloader: DatasetDownloader {
    public init() {}

    public func download(_ url: URL, to file: URL, maxBytes: Int) async throws {
        guard url.scheme?.lowercased() == "https" else { throw ValidationError("Solo se admiten URLs https.") }
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        let session = URLSession(configuration: config, delegate: HTTPSOnlyDelegate(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ValidationError("La descarga de \(url.absoluteString) no respondió 200.")
        }
        if http.expectedContentLength > Int64(maxBytes) {
            throw ValidationError("\(url.lastPathComponent) supera el límite de tamaño del dataset.")
        }
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        var total = 0
        var buffer = Data()
        for try await byte in bytes {
            buffer.append(byte)
            total += 1
            if total > maxBytes { throw ValidationError("\(url.lastPathComponent) supera el límite de tamaño del dataset.") }
            if buffer.count >= 65_536 {
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        if !buffer.isEmpty { try handle.write(contentsOf: buffer) }
    }

    private final class HTTPSOnlyDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(request.url?.scheme?.lowercased() == "https" ? request : nil)
        }
    }
}

public struct DatasetMeta: Codable, Equatable, Sendable {
    public var name: String
    public var description: String
    public var files: [String]
    public var bytes: Int
    public var sources: [String]
    public var fetchedByAgentId: String?
    public var createdAt: Date
}

/// Datasets públicos compartidos por todos los laboratorios: `datasets/<name>/<archivos>` + `meta.json`. Inmutables.
public struct Datasets: Sendable {
    public let paths: AppPaths
    public let downloader: DatasetDownloader
    public let maxDatasetBytes: Int
    public let maxTotalBytes: Int

    public init(paths: AppPaths, downloader: DatasetDownloader,
                maxDatasetBytes: Int = 500_000_000, maxTotalBytes: Int = 2_000_000_000) {
        self.paths = paths
        self.downloader = downloader
        self.maxDatasetBytes = maxDatasetBytes
        self.maxTotalBytes = maxTotalBytes
    }

    static let metaFile = "meta.json"

    public func list() throws -> [DatasetMeta] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: paths.datasetsDir.path) else { return [] }
        let dirs = try fm.contentsOfDirectory(at: paths.datasetsDir, includingPropertiesForKeys: [.isDirectoryKey])
        var result: [DatasetMeta] = []
        for dir in dirs where !dir.lastPathComponent.hasPrefix(".") {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let data = try? Data(contentsOf: dir.appendingPathComponent(Self.metaFile)),
                  let meta = try? Self.decoder.decode(DatasetMeta.self, from: data) else { continue }
            result.append(meta)
        }
        return result.sorted { $0.name < $1.name }
    }

    public func fetch(name: String, urls: [String], description: String, agentId: String) async throws -> DatasetMeta {
        try Self.validate(name: name)
        guard (1...50).contains(urls.count) else { throw ValidationError("Un dataset admite de 1 a 50 URLs.") }
        var parsed: [URL] = []
        for raw in urls {
            guard let url = URL(string: raw), url.scheme?.lowercased() == "https", url.host?.isEmpty == false else {
                throw ValidationError("Solo se admiten URLs https (\(raw)).")
            }
            parsed.append(url)
        }
        let fm = FileManager.default
        try ensureAvailable(name)
        let used = try list().reduce(0) { $0 + $1.bytes }
        guard used < maxTotalBytes else {
            throw ValidationError("Los datasets ya ocupan el máximo permitido; borra alguno antes de descargar más.")
        }
        try fm.createDirectory(at: paths.datasetsDir, withIntermediateDirectories: true)
        let tmp = paths.datasetsDir.appendingPathComponent(".tmp-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        do {
            var files: [String] = []
            var total = 0
            for url in parsed {
                let fileName = Self.uniqueFileName(for: url, taken: files)
                let dest = tmp.appendingPathComponent(fileName)
                let allowed = min(maxDatasetBytes - total, maxTotalBytes - used - total)
                try await downloader.download(url, to: dest, maxBytes: max(allowed, 0))
                let size = (try fm.attributesOfItem(atPath: dest.path)[.size] as? NSNumber)?.intValue ?? 0
                total += size
                if total > maxDatasetBytes {
                    throw ValidationError("El dataset supera el límite de \(Self.mb(maxDatasetBytes)) MB.")
                }
                if used + total > maxTotalBytes {
                    throw ValidationError("Los datasets superarían el máximo total de \(Self.mb(maxTotalBytes)) MB.")
                }
                files.append(fileName)
            }
            let meta = DatasetMeta(name: name, description: description, files: files, bytes: total,
                                   sources: parsed.map(\.absoluteString), fetchedByAgentId: agentId, createdAt: Date())
            try Self.encoder.encode(meta).write(to: tmp.appendingPathComponent(Self.metaFile))
            try ensureAvailable(name)
            try fm.moveItem(at: tmp, to: paths.datasetDir(name))
            return meta
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
    }

    /// Copia una carpeta local (la elige el usuario). Rechaza enlaces simbólicos.
    public func importFolder(_ source: URL, name: String, description: String) throws -> DatasetMeta {
        try Self.validate(name: name)
        let fm = FileManager.default
        try ensureAvailable(name)
        try SkillLibrary.rejectSymlinks(in: source)
        var files: [String] = []
        var total = 0
        if let e = fm.enumerator(at: source, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) {
            for case let url as URL in e {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values.isRegularFile == true else { continue }
                files.append(String(url.standardizedFileURL.path.dropFirst(source.standardizedFileURL.path.count + 1)))
                total += values.fileSize ?? 0
            }
        }
        guard !files.isEmpty else { throw ValidationError("La carpeta no tiene archivos.") }
        guard total <= maxDatasetBytes else { throw ValidationError("El dataset supera el límite de \(Self.mb(maxDatasetBytes)) MB.") }
        let used = try list().reduce(0) { $0 + $1.bytes }
        guard used + total <= maxTotalBytes else {
            throw ValidationError("Los datasets superarían el máximo total de \(Self.mb(maxTotalBytes)) MB.")
        }
        try fm.createDirectory(at: paths.datasetsDir, withIntermediateDirectories: true)
        let tmp = paths.datasetsDir.appendingPathComponent(".tmp-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.copyItem(at: source, to: tmp)
            let meta = DatasetMeta(name: name, description: description, files: files.sorted(), bytes: total,
                                   sources: [source.path], fetchedByAgentId: nil, createdAt: Date())
            try Self.encoder.encode(meta).write(to: tmp.appendingPathComponent(Self.metaFile))
            try fm.moveItem(at: tmp, to: paths.datasetDir(name))
            return meta
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
    }

    public func delete(name: String) throws {
        try Self.validate(name: name)
        let dir = paths.datasetDir(name)
        guard FileManager.default.fileExists(atPath: dir.path) else { throw ValidationError("No existe el dataset \(name).") }
        try FileManager.default.removeItem(at: dir)
    }

    // MARK: - Helpers

    private func ensureAvailable(_ name: String) throws {
        if FileManager.default.fileExists(atPath: paths.datasetDir(name).path) {
            throw ValidationError("Ya existe el dataset \(name): los datasets no se reescriben, usa otro nombre.")
        }
    }

    static func validate(name: String) throws {
        guard SkillManifest.isValidName(name) else {
            throw ValidationError("El nombre del dataset debe ser kebab-case (minúsculas, números y guiones; máx. 64).")
        }
    }

    static func uniqueFileName(for url: URL, taken: [String]) -> String {
        var base = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        base = base.replacingOccurrences(of: "/", with: "_")
        if base.isEmpty || base == "/" || base == "." || base == ".." { base = "archivo" }
        if base.hasPrefix(".") { base = "_" + base }
        let reserved = Set(taken.map { $0.lowercased() } + [metaFile])
        var candidate = base
        var n = 2
        let ext = (base as NSString).pathExtension
        let stem = (base as NSString).deletingPathExtension
        while reserved.contains(candidate.lowercased()) {
            candidate = ext.isEmpty ? "\(stem)-\(n)" : "\(stem)-\(n).\(ext)"
            n += 1
        }
        return candidate
    }

    private static func mb(_ bytes: Int) -> Int { bytes / 1_000_000 }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
