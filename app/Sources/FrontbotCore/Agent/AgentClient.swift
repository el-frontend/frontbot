import Foundation

public struct AgentConfig: Sendable {
    public static let defaultModel = "claude-sonnet-5-5"
    public var nodePath: String
    public var scriptPath: String
    public var apiKey: String?
    public var model: String
    public var fakeAgent: Bool

    public init(nodePath: String, scriptPath: String, apiKey: String?, model: String, fakeAgent: Bool) {
        self.nodePath = nodePath; self.scriptPath = scriptPath; self.apiKey = apiKey; self.model = model; self.fakeAgent = fakeAgent
    }
}

/// Modelos que se pueden elegir en la app.
public enum AgentModel {
    public static let all: [(id: String, label: String)] = [
        (AgentConfig.defaultModel, "Sonnet 5.5 · día a día"),
        ("claude-opus-5-5", "Opus 5.5 · investigación a fondo"),
        ("claude-haiku-4-5-20251001", "Haiku 4.5 · rápido y barato"),
    ]

    /// El guardado si sigue en el catálogo; si no, el de por defecto.
    public static func resolve(_ stored: String?) -> String {
        all.contains { $0.id == stored } ? stored! : AgentConfig.defaultModel
    }

    /// "claude-sonnet-5-5" → "sonnet-5.5"; "claude-haiku-4-5-20251001" → "haiku-4.5".
    public static func shortName(_ id: String) -> String {
        let parts = id.replacingOccurrences(of: "claude-", with: "").split(separator: "-")
        guard parts.count >= 3 else { return id }
        return "\(parts[0])-\(parts[1]).\(parts[2])"
    }
}

public enum AgentUpdate: Sendable, Equatable {
    case event(runId: String, type: String, text: String)
    case finished(AgentRun)
}

public enum AgentClientError: Error, Equatable, LocalizedError {
    case restartLimit
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .restartLimit: "El agente se reinició demasiadas veces. Revisa los logs y vuelve a intentar en un minuto."
        case .launchFailed(let why): "No se pudo iniciar el agente: \(why)"
        }
    }
}

/// Arranca y vigila el sidecar `frontbot-agent`, le envía runs y atiende sus llamadas `tool.*`.
public actor AgentClient {
    private var config: AgentConfig
    private let db: AppDatabase
    private let files: BrandFiles
    private let tools: ToolHandler
    private let workspaceId: String

    private var process: Process?
    private var stdin: FileHandle?
    private var framer = LineFramer()
    private var nextId = 1
    private var generation = 0
    private var activeRuns: Set<String> = []
    private var launches: [Date] = []
    private var subscribers: [UUID: AsyncStream<AgentUpdate>.Continuation] = [:]

    private let cancelGrace: Duration

    public init(config: AgentConfig, db: AppDatabase, files: BrandFiles, workspaceId: String, cancelGrace: Duration = .seconds(10)) {
        self.cancelGrace = cancelGrace
        self.config = config
        self.db = db
        self.files = files
        self.workspaceId = workspaceId
        self.tools = ToolHandler(db: db, files: files, workspaceId: workspaceId)
    }

    public func setConfig(_ config: AgentConfig) {
        self.config = config
        stop() // el próximo run relanza con la nueva config (p. ej. nueva API key)
    }

    public func updates() -> AsyncStream<AgentUpdate> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<AgentUpdate>.makeStream()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.removeSubscriber(id) } }
        return stream
    }

    private func removeSubscriber(_ id: UUID) { subscribers[id] = nil }

    private func broadcast(_ update: AgentUpdate) {
        for c in subscribers.values { c.yield(update) }
    }

    /// `agent`: quién responde (sin agente, el sidecar usa Frontbot). Su `browser` activa el Chrome del usuario
    /// detrás del guardián del sidecar. `model`: el elegido en la app (si no, el de la configuración).
    /// `summarize`: run en segundo plano que solo guarda en la memoria lo aprendido en `history`.
    public func run(prompt: String, agent: Agent? = nil, brand: Brand?, history: [ChatTurn] = [], model: String? = nil,
                    summarize: Bool = false) async throws -> AgentRun {
        try ensureProcess()
        let run = try db.startRun(workspaceId: workspaceId, brandId: brand?.id, prompt: prompt)
        activeRuns.insert(run.id)
        do {
            var params: [String: JSONValue] = ["run_id": .string(run.id), "prompt": .string(prompt), "model": .string(model ?? config.model)]
            if let brand {
                let guide = try files.readGuide(brandId: brand.id)
                params["brand"] = ["id": .string(brand.id), "name": .string(brand.name), "guide": guide.map(JSONValue.string) ?? .null]
            }
            if !history.isEmpty { params["history"] = ChatHistory.json(ChatHistory.trimmed(history)) }
            if summarize { params["mode"] = "summarize" }
            if let agent {
                let memory = MemoryPrompt.trimmed(try db.memories(agentId: agent.id))
                params["agent"] = ["id": .string(agent.id), "name": .string(agent.name), "instructions": .string(agent.instructions),
                                   "is_default": .bool(agent.isDefault), "memory": MemoryPrompt.json(memory)]
                if agent.browser { params["browser"] = .bool(true) }
            }
            try send(.request(id: takeId(), method: "agent.run", params: .object(params)))
            return run
        } catch {
            // No dejar el run en "running" si no llegó a enviarse.
            fail(runId: run.id, summary: error.localizedDescription)
            throw error
        }
    }

    public func cancel(runId: String) async {
        try? send(.request(id: takeId(), method: "agent.cancel", params: ["run_id": .string(runId)]))
        // Si el sidecar no confirma a tiempo (runner colgado), se da por cancelado y se reinicia el proceso.
        let grace = cancelGrace
        Task { [weak self] in
            try? await Task.sleep(for: grace)
            await self?.forceCancelIfStillActive(runId: runId)
        }
    }

    private func forceCancelIfStillActive(runId: String) {
        guard activeRuns.contains(runId) else { return }
        fail(runId: runId, summary: "Cancelado")
        stop()
    }

    private func fail(runId: String, summary: String) {
        activeRuns.remove(runId)
        if let run = try? db.finishRun(id: runId, status: .failed, summary: summary, inputTokens: 0, outputTokens: 0, costUsd: 0) {
            broadcast(.finished(run))
        }
    }

    public func stop() {
        guard let process else { return }
        generation += 1 // ignora el EOF de este proceso
        if process.isRunning { process.terminate() }
        self.process = nil
        stdin = nil
        handleExit()
    }

    // MARK: Proceso

    /// Entorno mínimo del sidecar. Con API key, el SDK la usa; sin ella, usa la sesión de Claude Code
    /// del usuario en este Mac (uso personal). Nunca se hereda una key de la shell.
    static func sidecarEnvironment(config: AgentConfig, inherited: [String: String]) -> [String: String] {
        var env = inherited.filter { ["PATH", "HOME", "TMPDIR", "USER"].contains($0.key) }
        env["CLAUDE_AGENT_SDK_CLIENT_APP"] = "frontbot/0.1.0"
        if let key = CredentialStore.normalizedApiKey(config.apiKey) { env["ANTHROPIC_API_KEY"] = key }
        if config.fakeAgent { env["FRONTBOT_FAKE_AGENT"] = "1" }
        return env
    }

    private func takeId() -> Int { defer { nextId += 1 }; return nextId }

    private func ensureProcess() throws {
        if let process, process.isRunning { return }
        if process != nil {
            // Murió pero su EOF aún no se procesó: sus runs fallan antes de relanzar.
            process = nil
            stdin = nil
            handleExit()
        }
        let now = Date()
        launches = launches.filter { now.timeIntervalSince($0) < 60 }
        guard launches.count < 3 else { throw AgentClientError.restartLimit }
        launches.append(now)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: config.nodePath)
        p.arguments = [config.scriptPath]
        p.environment = Self.sidecarEnvironment(config: config, inherited: ProcessInfo.processInfo.environment)

        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        inPipe.disableSigpipe()

        // Un único stream ordenado: lanzar un Task por chunk podría reordenar los datos.
        let (chunks, chunkSink) = AsyncStream<Data>.makeStream()
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                chunkSink.finish() // EOF: el proceso cerró stdout
            } else {
                chunkSink.yield(data)
            }
        }
        generation += 1
        let gen = generation
        do { try p.run() } catch { throw AgentClientError.launchFailed(error.localizedDescription) }
        framer = LineFramer()
        process = p
        stdin = inPipe.fileHandleForWriting
        Task { [weak self] in
            for await data in chunks { await self?.receive(data, generation: gen) }
            // Se procesa todo lo leído antes de declarar el proceso muerto.
            await self?.processExited(generation: gen)
        }
    }

    private func processExited(generation gen: Int) {
        guard gen == generation else { return } // salida de un proceso ya reemplazado
        process = nil
        stdin = nil
        handleExit()
    }

    private func handleExit() {
        for runId in activeRuns { fail(runId: runId, summary: "El agente se detuvo inesperadamente.") }
    }

    private func send(_ message: RPCMessage) throws {
        guard let stdin else { throw AgentClientError.launchFailed("proceso no disponible") }
        try stdin.write(contentsOf: message.encodedLine())
    }

    // MARK: Mensajes entrantes

    /// Solo procesa la salida del proceso actual; lo que quede de uno ya detenido se descarta.
    func receive(_ data: Data, generation gen: Int) {
        guard gen == generation else { return }
        for line in framer.append(data) {
            guard let message = try? RPCMessage.decode(line) else { continue }
            handle(message)
        }
    }

    private func handle(_ message: RPCMessage) {
        switch message {
        case .request(let id, let method, let params):
            do {
                let result = try tools.handle(method: method, params: params)
                try? send(.response(id: id, result: result))
            } catch let error as ValidationError {
                try? send(.error(id: id, code: -32000, message: error.message))
            } catch {
                try? send(.error(id: id, code: -32000, message: error.localizedDescription))
            }
        case .notification("agent.event", let params):
            broadcast(.event(runId: params["run_id"]?.stringValue ?? "", type: params["type"]?.stringValue ?? "", text: params["text"]?.stringValue ?? ""))
        case .notification("agent.done", let params):
            guard let runId = params["run_id"]?.stringValue, activeRuns.contains(runId) else { return }
            activeRuns.remove(runId)
            let ok = params["ok"]?.boolValue ?? false
            let summary = ok ? params["summary"]?.stringValue : (params["error"]?.stringValue ?? "Error desconocido")
            if let run = try? db.finishRun(id: runId, status: ok ? .done : .failed, summary: summary,
                                           inputTokens: params["input_tokens"]?.intValue ?? 0,
                                           outputTokens: params["output_tokens"]?.intValue ?? 0,
                                           costUsd: params["cost_usd"]?.doubleValue ?? 0) {
                broadcast(.finished(run))
            }
        default:
            break
        }
    }
}
