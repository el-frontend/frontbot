import Foundation

/// Ejecuta scripts de skills con `sandbox-exec`: sin red, sin leer la carpeta personal (salvo la del skill)
/// y escribiendo solo en la carpeta del skill y en un temporal. Siempre tras la aprobación del usuario.
public struct ScriptSandbox: Sendable {
    public struct Result: Equatable, Sendable {
        public let stdout: String
        public let stderr: String
        public let exitCode: Int32
        public let timedOut: Bool
    }

    public static let outputLimit = 20_000
    let timeout: TimeInterval
    let nodePath: String?

    public init(timeout: TimeInterval = 60, nodePath: String? = nil) {
        self.timeout = timeout
        self.nodePath = nodePath
    }

    /// Ruta real del script (dentro del skill) y su intérprete.
    public static func resolve(script: String, in skillDir: URL, nodePath: String? = nil) throws -> (url: URL, interpreter: String) {
        let base = skillDir.resolvingSymlinksInPath().standardizedFileURL.path
        guard !script.hasPrefix("/"), !script.split(separator: "/").contains("..") else {
            throw ValidationError("El script debe ser una ruta dentro del skill: \(script).")
        }
        let url = skillDir.appendingPathComponent(script).resolvingSymlinksInPath().standardizedFileURL
        guard url.path.hasPrefix(base + "/") else { throw ValidationError("El script debe estar dentro del skill: \(script).") }
        guard FileManager.default.fileExists(atPath: url.path) else { throw ValidationError("No existe el script \(script) en el skill.") }
        switch url.pathExtension.lowercased() {
        case "py": return (url, pythonPath)
        case "sh", "bash": return (url, "/bin/sh")
        case "js", "mjs", "cjs":
            guard let nodePath else { throw ValidationError("No hay node disponible para ejecutar \(script).") }
            return (url, nodePath)
        default: throw ValidationError("Tipo de script no soportado: \(script) (usa .py, .sh o .js).")
        }
    }

    /// `/usr/bin/python3` es un intermediario de xcrun que escribe una caché fuera de la sandbox:
    /// se resuelve el binario real una vez, fuera de ella.
    static let pythonPath: String = {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        p.arguments = ["-f", "python3"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "/usr/bin/python3" }
        p.waitUntilExit()
        let path = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return p.terminationStatus == 0 && FileManager.default.isExecutableFile(atPath: path) ? path : "/usr/bin/python3"
    }()

    /// Ruta canónica como la ve el kernel (`resolvingSymlinksInPath` quita `/private` y el perfil no coincidiría).
    static func realPath(_ url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else { return url.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func profile(skillDir: String, tmpDir: String, home: String, interpreterDir: String = "/usr/bin") -> String {
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        return """
        (version 1)
        (deny default)
        (allow process-exec process-fork signal sysctl-read mach-lookup ipc-posix-shm)
        (allow file-read*)
        (deny file-read* (subpath \(q(home))))
        (allow file-read* (subpath \(q(skillDir))) (subpath \(q(tmpDir))) (subpath \(q(interpreterDir))))
        (allow file-read-metadata)
        (allow file-write* (subpath \(q(skillDir))) (subpath \(q(tmpDir))) (literal "/dev/null"))
        (deny network*)
        (deny appleevent-send)
        (deny mach-lookup
          (global-name-prefix "com.apple.pasteboard")
          (global-name-prefix "com.apple.coreservices.launchservicesd")
          (global-name-prefix "com.apple.lsd")
          (global-name "com.apple.coreservices.quarantine-resolver")
          (global-name "com.apple.SecurityServer")
          (global-name-prefix "com.apple.securityd")
          (global-name-prefix "com.apple.tccd")
          (global-name-prefix "com.apple.windowserver")
          (global-name "com.apple.dock.server"))
        (deny process-exec
          (literal "/usr/bin/open") (literal "/usr/bin/osascript") (literal "/usr/bin/pbpaste") (literal "/usr/bin/pbcopy")
          (literal "/usr/bin/screencapture") (literal "/usr/bin/security") (literal "/usr/bin/sudo"))
        """
    }

    public func run(script: String, args: [String], in skillDir: URL) throws -> Result {
        let (url, interpreter) = try Self.resolve(script: script, in: skillDir, nodePath: nodePath)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("frontbot-script-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let real = Self.realPath
        let home = URL(fileURLWithPath: NSHomeDirectory())

        // perl crea un grupo de procesos propio para poder matar también a los hijos que el script deje en segundo plano.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = ["-e", "setpgrp(0, 0); exec @ARGV or die $!", "/usr/bin/sandbox-exec",
                       "-p", Self.profile(skillDir: real(skillDir), tmpDir: real(tmp), home: real(home),
                                          interpreterDir: real(URL(fileURLWithPath: interpreter).deletingLastPathComponent())),
                       interpreter, url.path] + args
        p.currentDirectoryURL = url.deletingLastPathComponent()
        p.environment = ["PATH": "/usr/bin:/bin", "HOME": real(tmp), "TMPDIR": real(tmp), "LANG": "en_US.UTF-8"]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice

        // Lectura incremental: un hijo que herede el pipe no puede bloquear la espera de EOF.
        let outBuffer = OutputBuffer(), errBuffer = OutputBuffer()
        out.fileHandleForReading.readabilityHandler = { outBuffer.append($0.availableData) }
        err.fileHandleForReading.readabilityHandler = { errBuffer.append($0.availableData) }
        let finished = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in finished.signal() }

        try p.run()
        let group = p.processIdentifier
        let timedOut = finished.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            killpg(group, SIGTERM)
            if finished.wait(timeout: .now() + 1) == .timedOut { killpg(group, SIGKILL); _ = finished.wait(timeout: .now() + 2) }
        }
        killpg(group, SIGKILL) // nada del script sigue vivo después de devolver el resultado
        Thread.sleep(forTimeInterval: 0.05)
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        return Result(stdout: Self.truncated(outBuffer.data), stderr: Self.truncated(errBuffer.data),
                      exitCode: p.isRunning ? -1 : p.terminationStatus, timedOut: timedOut)
    }

    /// Acumula la salida con un tope (lo que pase de 4× el límite se descarta).
    final class OutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()
        func append(_ chunk: Data) {
            lock.lock(); defer { lock.unlock() }
            if storage.count < ScriptSandbox.outputLimit * 4 { storage.append(chunk) }
        }
        var data: Data { lock.lock(); defer { lock.unlock() }; return storage }
    }

    static func truncated(_ data: Data) -> String {
        let text = String(decoding: data, as: UTF8.self)
        guard text.utf8.count > outputLimit else { return text }
        return String(text.utf8.prefix(outputLimit)).map { $0 + "…[salida recortada]" } ?? String(text.prefix(outputLimit / 4)) + "…[salida recortada]"
    }
}
