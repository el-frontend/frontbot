import Foundation

public enum CodexLoginCheckResult: Equatable, Sendable {
    case signedIn
    case signedOut
    case unavailable
}

public enum CodexStatus: Equatable, Sendable {
    case checking
    case available(executable: String)
    case notInstalled
    case notSignedIn(executable: String)
    case unavailable(executable: String)
}

/// Discovers the Codex CLI without invoking a shell, and checks its local account session.
public enum CodexLocator {
    public static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        candidatePaths: [String]? = nil,
        exists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        let candidates = candidatePaths ?? supportedPaths(environment: environment)
        let explicit = [environment["FRONTBOT_CODEX"], environment["CODEX_CLI_PATH"]].compactMap { $0 }
        let pathCandidates = (environment["PATH"] ?? "").split(separator: ":").map { "\($0)/codex" }
        return (explicit + pathCandidates + candidates).first(where: exists)
    }

    public static func status(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        candidatePaths: [String]? = nil,
        exists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        loginCheck: ((String) -> CodexLoginCheckResult)? = nil
    ) -> CodexStatus {
        guard let executable = locate(environment: environment, candidatePaths: candidatePaths, exists: exists) else {
            return .notInstalled
        }
        switch (loginCheck ?? defaultLoginCheck)(executable) {
        case .signedIn: return .available(executable: executable)
        case .signedOut: return .notSignedIn(executable: executable)
        case .unavailable: return .unavailable(executable: executable)
        }
    }

    private static func supportedPaths(environment: [String: String]) -> [String] {
        var paths = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
        if let home = environment["HOME"] {
            paths += [
                "\(home)/.local/bin/codex",
                "\(home)/.cargo/bin/codex",
                "\(home)/.npm-global/bin/codex",
                "\(home)/.volta/bin/codex",
                "\(home)/.asdf/shims/codex",
                "\(home)/.local/share/mise/shims/codex",
            ]
        }
        return paths
    }

    private static func defaultLoginCheck(_ executable: String) -> CodexLoginCheckResult {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["login", "status"]
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
        } catch {
            return .unavailable
        }

        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            finished.signal()
        }
        guard finished.wait(timeout: .now() + .seconds(3)) == .success else {
            process.terminate()
            return .unavailable
        }

        let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.lowercased() ?? ""
        if process.terminationStatus == 0 { return .signedIn }
        if text.contains("not logged in") || text.contains("not signed in") || text.contains("please log in") {
            return .signedOut
        }
        return .unavailable
    }
}
