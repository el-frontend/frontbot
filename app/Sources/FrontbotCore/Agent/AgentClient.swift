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

public enum AgentUpdate: Sendable, Equatable {
    case event(runId: String, type: String, text: String)
    case finished(AgentRun)
}

public enum AgentClientError: Error, Equatable, LocalizedError {
    case missingApiKey
    case restartLimit
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingApiKey: "Configura tu API key de Anthropic en Ajustes."
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

    public func run(prompt: String, brand: Brand?, history: [ChatTurn] = []) async throws -> AgentRun {
        if !config.fakeAgent, CredentialStore.normalizedApiKey(config.apiKey) == nil {
            throw AgentClientError.missingApiKey
        }
        try ensureProcess()
        let run = try db.startRun(workspaceId: workspaceId, brandId: brand?.id, prompt: prompt)
        activeRuns.insert(run.id)
        do {
            var params: [String: JSONValue] = ["run_id": .string(run.id), "prompt": .string(prompt), "model": .string(config.model)]
            if let brand {
                let guide = try files.readGuide(brandId: brand.id)
                params["brand"] = ["id": .string(brand.id), "name": .string(brand.name), "guide": guide.map(JSONValue.string) ?? .null]
            }
            if !history.isEmpty { params["history"] = ChatHistory.json(ChatHistory.trimmed(history)) }
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
        var env = ProcessInfo.processInfo.environment.filter { ["PATH", "HOME", "TMPDIR", "USER"].contains($0.key) }
        env["CLAUDE_AGENT_SDK_CLIENT_APP"] = "frontbot/0.1.0"
        if let key = CredentialStore.normalizedApiKey(config.apiKey) { env["ANTHROPIC_API_KEY"] = key }
        if config.fakeAgent { env["FRONTBOT_FAKE_AGENT"] = "1" }
        p.environment = env

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
            break // respuestas a agent.run / agent.cancel: no se necesitan
        }
    }
}
