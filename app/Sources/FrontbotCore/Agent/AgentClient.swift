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
    /// Cambió alguna propuesta de trade (nueva, enviada automáticamente, fallida…).
    case tradesChanged(TradeProposal)
    /// Una tarea programada pidió avisar al usuario (`notify_user`).
    case notify(runId: String, title: String, message: String)
    case finished(AgentRun)
}

public enum AgentClientError: Error, Equatable, LocalizedError {
    case restartLimit
    case launchFailed(String)
    case remote(String)
    case timeout

    public var errorDescription: String? {
        switch self {
        case .restartLimit: "El agente se reinició demasiadas veces. Revisa los logs y vuelve a intentar en un minuto."
        case .launchFailed(let why): "No se pudo iniciar el agente: \(why)"
        case .remote(let why): why
        case .timeout: "El agente no respondió a tiempo."
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
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var subscribers: [UUID: AsyncStream<AgentUpdate>.Continuation] = [:]

    private let cancelGrace: Duration
    /// La app muestra la petición y devuelve si el usuario permite el script (sin respuesta = denegado).
    private var scriptApprover: (@Sendable (ScriptRequest) async -> Bool)?
    static let scriptApprovalTimeout: Duration = .seconds(120)

    public func setScriptApprover(_ approver: @escaping @Sendable (ScriptRequest) async -> Bool) { scriptApprover = approver }

    /// Claves de las API wallets de Hyperliquid (la app las lee del llavero).
    private var tradeKeys: (any TradeKeyStore)?
    public func setTradeKeys(_ keys: any TradeKeyStore) { tradeKeys = keys }
    private struct NoKeys: TradeKeyStore { func privateKey(agentId: String, network: TradeNetwork) -> String? { nil } }
    public var trading: TradingService { TradingService(db: db, executor: self, keys: tradeKeys ?? NoKeys()) }
    /// Para operaciones síncronas desde la app (rechazar) sin esperar al actor.
    nonisolated public func tradingService(db: AppDatabase) -> TradingService { TradingService(db: db, executor: self, keys: KeychainTradeKeys()) }

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
    /// `task`: ejecución de una tarea programada (sin nadie mirando; puede usar notify_user).
    public func run(prompt: String, agent: Agent? = nil, brand: Brand?, history: [ChatTurn] = [], model: String? = nil,
                    summarize: Bool = false, task: ScheduledTask? = nil) async throws -> AgentRun {
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
            if let task {
                params["mode"] = "scheduled"
                params["task"] = ["name": .string(task.name)]
            }
            if let agent {
                let memory = MemoryPrompt.trimmed(try db.memories(agentId: agent.id))
                params["agent"] = ["id": .string(agent.id), "name": .string(agent.name), "instructions": .string(agent.instructions),
                                   "is_default": .bool(agent.isDefault), "memory": MemoryPrompt.json(memory)]
                if agent.browser { params["browser"] = .bool(true) }
                if agent.trading {
                    let m = try db.mandate(agentId: agent.id)
                    var trading: [String: JSONValue] = ["network": .string(m.network.rawValue), "mandate": [
                        "mode": .string(m.mode.rawValue), "max_risk_pct": .number(m.maxRiskPct), "max_leverage": .number(Double(m.maxLeverage)),
                        "coins": .array(m.coins.map(JSONValue.string)), "max_trades_per_day": .number(Double(m.maxTradesPerDay)), "paused": .bool(m.paused),
                    ]]
                    if let address = m.address { trading["address"] = .string(address) }
                    params["trading"] = .object(trading)
                }
                let skills = try SkillLibrary(db: db, paths: files.paths).skills(assignedTo: agent.id, activeOnly: true)
                if !skills.isEmpty {
                    params["skills"] = .array(skills.map { ["name": .string($0.name), "dir": .string(ScriptSandbox.realPath(files.paths.skillDir($0.name)))] })
                }
            }
            try send(.request(id: takeId(), method: "agent.run", params: .object(params)))
            return run
        } catch {
            // No dejar el run en "running" si no llegó a enviarse.
            fail(runId: run.id, summary: error.localizedDescription)
            throw error
        }
    }

    /// Llamada con respuesta al sidecar (p. ej. `trade.execute`). La hace la app, nunca el agente.
    public func call(_ method: String, params: JSONValue, timeout: Duration = .seconds(60)) async throws -> JSONValue {
        try ensureProcess()
        let id = takeId()
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try send(.request(id: id, method: method, params: params))
            } catch {
                resolve(id, with: .failure(error))
                return
            }
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.resolve(id, with: .failure(AgentClientError.timeout))
            }
        }
    }

    private func resolve(_ id: Int, with result: Result<JSONValue, Error>) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(with: result)
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
        for id in Array(pending.keys) { resolve(id, with: .failure(AgentClientError.remote("El agente se detuvo inesperadamente."))) }
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
        case .request(let id, "tool.notify_user", let params):
            guard let runId = params["run_id"]?.stringValue, activeRuns.contains(runId) else {
                reply(id, .failure(ValidationError("notify_user solo funciona dentro de una tarea programada.")))
                return
            }
            let title = String((params["title"]?.stringValue ?? "Frontbot").prefix(120))
            let message = String((params["message"]?.stringValue ?? "").prefix(600))
            broadcast(.notify(runId: runId, title: title, message: message))
            reply(id, .success(["ok": true]))
        case .request(let id, "tool.trade_propose", let params):
            do {
                let result = try trading.propose(params: params)
                reply(id, .success(result.json))
                broadcast(.tradesChanged(result.proposal))
                if result.autoExecute {
                    let service = trading
                    Task {
                        if let done = try? await service.executeAuto(id: result.proposal.id) { self.broadcast(.tradesChanged(done)) }
                    }
                }
            } catch {
                reply(id, .failure(error))
            }
        case .request(let id, "tool.skills_run_script", let params):
            let tool = ScriptTool(library: SkillLibrary(db: db, paths: files.paths), sandbox: ScriptSandbox(nodePath: config.nodePath))
            let approver = scriptApprover
            Task {
                do {
                    let result = try await tool.run(params: params) { request in
                        guard let approver else { return false }
                        return await Self.withTimeout(Self.scriptApprovalTimeout, default: false) { await approver(request) }
                    }
                    self.reply(id, .success(result))
                } catch {
                    self.reply(id, .failure(error))
                }
            }
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
        case .response(let id, let result):
            resolve(id, with: .success(result)) // las de agent.run / agent.cancel no tienen continuación: se ignoran
        case .error(let id, _, let message):
            resolve(id, with: .failure(AgentClientError.remote(message)))
        default:
            break
        }
    }

    private func reply(_ id: Int, _ result: Result<JSONValue, Error>) {
        switch result {
        case .success(let value): try? send(.response(id: id, result: value))
        case .failure(let error as ValidationError): try? send(.error(id: id, code: -32000, message: error.message))
        case .failure(let error): try? send(.error(id: id, code: -32000, message: error.localizedDescription))
        }
    }

    /// El primero que termine: la operación o el plazo (que devuelve `default`).
    static func withTimeout<T: Sendable>(_ timeout: Duration, default value: T, _ operation: @escaping @Sendable () async -> T) async -> T {
        await withTaskGroup(of: T.self) { group in
            group.addTask { await operation() }
            group.addTask { try? await Task.sleep(for: timeout); return value }
            let first = await group.next() ?? value
            group.cancelAll()
            return first
        }
    }
}

extension AgentClient: TradeExecutor {
    public func snapshot(network: TradeNetwork, coin: String, address: String?) async throws -> MarketSnapshot {
        var params: [String: JSONValue] = ["network": .string(network.rawValue), "coin": .string(coin)]
        if let address { params["address"] = .string(address) }
        let r = try await call("market.snapshot", params: .object(params), timeout: .seconds(30))
        guard let price = r["price"]?.doubleValue else { throw AgentClientError.remote("Respuesta inválida de Hyperliquid.") }
        return MarketSnapshot(price: price, accountValue: r["account_value"]?.doubleValue)
    }

    public func execute(network: TradeNetwork, privateKey: String, address: String, proposal p: TradeProposal) async throws -> TradeOutcome {
        var params: [String: JSONValue] = [
            "network": .string(network.rawValue), "private_key": .string(privateKey), "address": .string(address), "coin": .string(p.coin),
            "side": .string(p.side.rawValue), "size_usd": .number(p.sizeUsd), "leverage": .number(Double(p.leverage)),
            "entry_type": .string(p.entryType.rawValue), "stop_loss": .number(p.stopLoss),
        ]
        if let e = p.entryPrice { params["entry_price"] = .number(e) }
        if let tp = p.takeProfit { params["take_profit"] = .number(tp) }
        // Más que el presupuesto del sidecar (varias llamadas a Hyperliquid de hasta 15 s cada una).
        let r = try await call("trade.execute", params: .object(params), timeout: .seconds(120))
        return TradeOutcome(status: r["status"]?.stringValue ?? "failed",
                            orderIds: (r["orderIds"]?.arrayValue ?? []).compactMap(\.intValue),
                            filledSize: r["filledSize"]?.stringValue, avgPrice: r["avgPrice"]?.stringValue, error: r["error"]?.stringValue)
    }

    public func close(network: TradeNetwork, privateKey: String, address: String, coin: String) async throws {
        _ = try await call("trade.close", params: ["network": .string(network.rawValue), "private_key": .string(privateKey),
                                                   "address": .string(address), "coin": .string(coin)], timeout: .seconds(120))
    }

    public func positionSize(network: TradeNetwork, address: String, coin: String) async throws -> Double {
        let overview = try await accountOverview(network: network, address: address)
        let position = (overview["positions"]?.arrayValue ?? []).first { $0["coin"]?.stringValue == coin.uppercased() }
        return position?["size"]?.doubleValue ?? 0
    }

    /// Valor de la cuenta, posiciones y órdenes abiertas (para la pestaña Trades).
    public func accountOverview(network: TradeNetwork, address: String) async throws -> JSONValue {
        try await call("account.overview", params: ["network": .string(network.rawValue), "address": .string(address)], timeout: .seconds(30))
    }
}

