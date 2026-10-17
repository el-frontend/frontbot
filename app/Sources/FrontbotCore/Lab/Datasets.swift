import Foundation

/// Descarga un recurso público a un archivo local. Solo la app lo usa; los scripts del agente nunca tocan la red.
public protocol DatasetDownloader: Sendable {
    func download(_ url: URL, to file: URL, maxBytes: Int) async throws
}

/// Decide si un host apunta a la máquina o a la red local (no son datos públicos).
public enum PublicHost {
    public static func localError(_ host: String) -> ValidationError {
        ValidationError("Solo se descargan datos públicos: \(host) es una dirección local.")
    }

    /// Comprobación sin DNS: nombres locales y direcciones IP literales.
    public static func isLocalLiteral(_ rawHost: String) -> Bool {
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if host.isEmpty || host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") { return true }
        return isLocalAddress(host)
    }

    /// `true` si `text` es una IP literal loopback/privada/link-local/no especificada.
    public static func isLocalAddress(_ text: String) -> Bool {
        var v4 = in_addr()
        if inet_pton(AF_INET, text, &v4) == 1 {
            let b = withUnsafeBytes(of: v4) { Array($0) }
            return isLocalV4(b)
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, text, &v6) == 1 {
            let b = withUnsafeBytes(of: v6) { Array($0) }
            if b.dropLast().allSatisfy({ $0 == 0 }) && (b[15] == 0 || b[15] == 1) { return true }  // :: y ::1
            if b[0] & 0xFE == 0xFC { return true }                                                // fc00::/7
            if b[0] == 0xFE && b[1] & 0xC0 == 0x80 { return true }                                // fe80::/10
            if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xFF && b[11] == 0xFF { return isLocalV4(Array(b[12..<16])) }
            return false
        }
        return false
    }

    private static func isLocalV4(_ b: [UInt8]) -> Bool {
        b[0] == 127 || b[0] == 10 || b[0] == 0 || (b[0] == 172 && (16...31).contains(b[1]))
            || (b[0] == 192 && b[1] == 168) || (b[0] == 169 && b[1] == 254)
    }

    /// Direcciones a las que resuelve el host (getaddrinfo).
    public static func systemResolve(_ host: String) -> [String] {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0, let first = res else { return [] }
        defer { freeaddrinfo(res) }
        var out: [String] = []
        var cur: UnsafeMutablePointer<addrinfo>? = first
        while let ai = cur {
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(ai.pointee.ai_addr, ai.pointee.ai_addrlen, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 {
                out.append(String(cString: buf))
            }
            cur = ai.pointee.ai_next
        }
        return out
    }
}

/// Implementación real: sesión efímera sin cookies ni credenciales, solo https público, HTTP 200 y tope de bytes.
public struct URLSessionDatasetDownloader: DatasetDownloader {
    let protocolClasses: [AnyClass]
    let resolver: @Sendable (String) -> [String]

    public init() { self.init(protocolClasses: [], resolver: PublicHost.systemResolve) }

    /// Para tests: protocolos de red simulados y resolución de DNS inyectable.
    init(protocolClasses: [AnyClass], resolver: @escaping @Sendable (String) -> [String]) {
        self.protocolClasses = protocolClasses
        self.resolver = resolver
    }

    public func download(_ url: URL, to file: URL, maxBytes: Int) async throws {
        try Self.check(url, resolver: resolver)
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        if !protocolClasses.isEmpty { config.protocolClasses = protocolClasses }
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        let task = DownloadDelegate(handle: handle, maxBytes: maxBytes, resolver: resolver)
        let session = URLSession(configuration: config, delegate: task, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                task.continuation = cont
                session.dataTask(with: request).resume()
            }
        } onCancel: { session.invalidateAndCancel() }
    }

    static func check(_ url: URL, resolver: (String) -> [String]) throws {
        guard url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty else {
            throw ValidationError("Solo se admiten URLs https.")
        }
        if PublicHost.isLocalLiteral(host) { throw PublicHost.localError(host) }
        if resolver(host).contains(where: PublicHost.isLocalAddress) { throw PublicHost.localError(host) }
    }

    private final class DownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        let handle: FileHandle
        let maxBytes: Int
        let resolver: @Sendable (String) -> [String]
        var continuation: CheckedContinuation<Void, Error>?
        private var failure: Error?
        private var total = 0

        init(handle: FileHandle, maxBytes: Int, resolver: @escaping @Sendable (String) -> [String]) {
            self.handle = handle
            self.maxBytes = maxBytes
            self.resolver = resolver
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            guard let target = request.url else { completionHandler(nil); return }
            do {
                try URLSessionDatasetDownloader.check(target, resolver: resolver)
                completionHandler(request)
            } catch {
                failure = error
                completionHandler(nil)
                task.cancel()
            }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            let name = dataTask.originalRequest?.url?.lastPathComponent ?? "El archivo"
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                failure = ValidationError("La descarga de \(name) no respondió 200.")
                completionHandler(.cancel)
                return
            }
            if http.expectedContentLength > Int64(maxBytes) {
                failure = ValidationError("\(name) supera el límite de tamaño del dataset.")
                completionHandler(.cancel)
                return
            }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            total += data.count
            if total > maxBytes {
                failure = ValidationError("\(dataTask.originalRequest?.url?.lastPathComponent ?? "El archivo") supera el límite de tamaño del dataset.")
                dataTask.cancel()
                return
            }
            do { try handle.write(contentsOf: data) } catch { failure = error; dataTask.cancel() }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let failure { continuation?.resume(throwing: failure) }
            else if let error { continuation?.resume(throwing: error) }
            else { continuation?.resume() }
            continuation = nil
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
            if let host = url.host, PublicHost.isLocalLiteral(host) { throw PublicHost.localError(host) }
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
