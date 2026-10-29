import Foundation

public struct MarketSnapshot: Equatable, Sendable {
    public let price: Double
    public let accountValue: Double?
    public init(price: Double, accountValue: Double?) { self.price = price; self.accountValue = accountValue }
}

public struct TradeOutcome: Equatable, Sendable {
    public let status: String          // open | resting | failed
    public let orderIds: [Int]
    public let filledSize: String?
    public let avgPrice: String?
    public let error: String?
    public init(status: String, orderIds: [Int], filledSize: String?, avgPrice: String?, error: String?) {
        self.status = status; self.orderIds = orderIds; self.filledSize = filledSize; self.avgPrice = avgPrice; self.error = error
    }
}

/// El exchange (vía el sidecar). Solo la app lo usa; el agente nunca.
public protocol TradeExecutor: Sendable {
    func snapshot(network: TradeNetwork, coin: String, address: String?) async throws -> MarketSnapshot
    func execute(network: TradeNetwork, privateKey: String, address: String, proposal: TradeProposal) async throws -> TradeOutcome
    func close(network: TradeNetwork, privateKey: String, address: String, coin: String) async throws
    /// Tamaño actual de la posición en `coin` (0 si no hay): para saber qué pasó si no llegó respuesta.
    func positionSize(network: TradeNetwork, address: String, coin: String) async throws -> Double
}

/// Claves de las API wallets (en la app: el llavero).
public protocol TradeKeyStore: Sendable {
    func privateKey(agentId: String, network: TradeNetwork) -> String?
}

public struct ProposalResult: Sendable {
    public let proposal: TradeProposal
    public let autoExecute: Bool
    public let json: JSONValue
}

/// Propuestas de los agentes → validación del mandato → envío tras aprobación (o automático dentro del mandato).
public struct TradingService: Sendable {
    let db: AppDatabase
    let executor: any TradeExecutor
    let keys: any TradeKeyStore

    public init(db: AppDatabase, executor: any TradeExecutor, keys: any TradeKeyStore) {
        self.db = db
        self.executor = executor
        self.keys = keys
    }

    /// `tool.trade_propose`: guarda la propuesta (o el rechazo con sus motivos). El snapshot lo pone el sidecar.
    public func propose(params: JSONValue) throws -> ProposalResult {
        guard let agentId = params["agent_id"]?.stringValue, let agent = try db.agent(id: agentId) else { throw ValidationError("Agente desconocido.") }
        guard agent.trading else { throw ValidationError("Este agente no tiene trading activado.") }
        let mandate = try db.mandate(agentId: agentId)
        let idea = try Self.idea(from: params)
        guard let price = params["snapshot"]?["price"]?.doubleValue, price > 0 else { throw ValidationError("Falta el precio de mercado.") }
        let account = params["snapshot"]?["account_value"]?.doubleValue
        let snapshotNetwork = params["snapshot"]?["network"]?.stringValue.flatMap(TradeNetwork.init(rawValue:))
        // Sin cuenta conectada no se puede medir el riesgo todavía: se vuelve a validar al aprobar.
        var check = TradeRules.check(idea, mandate: mandate, accountValue: account ?? .greatestFiniteMagnitude,
                                     currentPrice: price, tradesToday: try db.tradesToday(agentId: agentId))
        if let snapshotNetwork, snapshotNetwork != mandate.network {
            check = TradeCheck(entry: check.entry, riskUsd: check.riskUsd,
                               problems: check.problems + ["el mandato cambió de red (ahora \(mandate.network.rawValue)): vuelve a analizar con los datos de esa red"])
        }
        let now = Date.dbNow()
        let proposal = TradeProposal(
            id: UUID().uuidString, agentId: agentId, network: mandate.network, coin: idea.coin.uppercased(), side: idea.side,
            sizeUsd: idea.sizeUsd, leverage: idea.leverage, entryType: idea.entryType, entryPrice: idea.entryPrice,
            stopLoss: idea.stopLoss, takeProfit: idea.takeProfit, rationale: idea.rationale, riskUsd: check.riskUsd,
            referencePrice: price, status: check.ok ? .proposed : .rejected, auto: false, orderIds: [], filledSize: nil,
            avgPrice: nil, error: check.ok ? nil : check.problems.joined(separator: "; "), executedAt: nil, createdAt: now, updatedAt: now)
        try db.saveProposal(proposal)

        let canAuto = check.ok && mandate.mode == .auto && !mandate.paused && account != nil
            && keys.privateKey(agentId: agentId, network: mandate.network) != nil && mandate.address != nil
        var json: [String: JSONValue] = ["proposal_id": .string(proposal.id), "status": .string(proposal.status.rawValue),
                                         "network": .string(mandate.network.rawValue), "risk_usd": .number((check.riskUsd * 100).rounded() / 100)]
        if !check.ok {
            json["problems"] = .array(check.problems.map(JSONValue.string))
            json["note"] = "Rechazada por el mandato: corrige y vuelve a proponer."
        } else if canAuto {
            json["status"] = "sending"
            json["note"] = "Cumple el mandato en modo automático: la app la está enviando."
        } else {
            json["note"] = account == nil ? "Guardada. El usuario debe conectar su cuenta y aprobarla." : "Guardada. El usuario la revisará y decidirá."
        }
        return ProposalResult(proposal: proposal, autoExecute: canAuto, json: .object(json))
    }

    /// El usuario aprueba: se revalida con datos frescos y se envía.
    public func approve(id: String) async throws -> TradeProposal { try await send(id: id, auto: false) }

    /// Modo automático: misma validación que una aprobación manual.
    public func executeAuto(id: String) async throws -> TradeProposal { try await send(id: id, auto: true) }

    public func reject(id: String) throws -> TradeProposal {
        guard let p = try db.transitionProposal(id: id, from: .proposed, to: .cancelled) else {
            throw ValidationError(String(localized: "Esa propuesta ya no está pendiente."))
        }
        return p
    }

    /// Cierra la posición de esa moneda a mercado y cancela sus órdenes de stop/take profit.
    public func close(id: String) async throws -> TradeProposal {
        guard var p = try db.proposal(id: id), p.status == .open else { throw ValidationError(String(localized: "Ese trade no está abierto.")) }
        let mandate = try db.mandate(agentId: p.agentId)
        guard let key = keys.privateKey(agentId: p.agentId, network: p.network), let address = mandate.address else {
            throw ValidationError(String(localized: "Conecta tu API wallet de Hyperliquid (\(p.network.rawValue)) en la página del agente."))
        }
        try await executor.close(network: p.network, privateKey: key, address: address, coin: p.coin)
        p.status = .closed
        try db.saveProposal(p)
        return p
    }

    private func send(id: String, auto: Bool) async throws -> TradeProposal {
        // Se reclama antes de cualquier espera: dos envíos (auto + manual, doble clic) nunca salen a la vez.
        guard var p = try db.claimProposal(id: id) else { throw ValidationError(String(localized: "Esa propuesta ya no está pendiente.")) }
        var delivering = false
        do {
            let mandate = try db.mandate(agentId: p.agentId)
            if auto && mandate.mode != .auto { throw ValidationError(String(localized: "El agente ya no está en modo automático.")) }
            guard p.network == mandate.network else {
                throw ValidationError(String(localized: "La propuesta es de \(p.network.rawValue) y el agente ahora opera en \(mandate.network.rawValue); pídele una nueva."))
            }
            guard let key = keys.privateKey(agentId: p.agentId, network: p.network), let address = mandate.address else {
                throw ValidationError(String(localized: "Conecta tu API wallet de Hyperliquid (\(p.network.rawValue)) en la página del agente."))
            }
            let snapshot = try await executor.snapshot(network: p.network, coin: p.coin, address: address)
            guard let account = snapshot.accountValue else { throw ValidationError(String(localized: "No se pudo leer el valor de tu cuenta en Hyperliquid.")) }
            // Esta propuesta ya cuenta como enviada hoy (executedAt): se descuenta para no contarla dos veces.
            let others = max(0, try db.tradesToday(agentId: p.agentId) - 1)
            let check = TradeRules.check(p.idea, mandate: mandate, accountValue: account, currentPrice: snapshot.price, tradesToday: others)
            guard check.ok else { throw ValidationError(String(localized: "Ya no cumple el mandato: \(check.problems.joined(separator: "; ")).")) }

            p.auto = auto
            p.riskUsd = check.riskUsd
            p.referencePrice = snapshot.price
            try db.saveProposal(p)
            delivering = true
            return try await deliver(p, key: key, address: address)
        } catch {
            if !delivering { _ = try? db.releaseProposal(id: id) } // no se llegó a enviar: vuelve a estar pendiente
            throw error
        }
    }

    /// Envía y registra el resultado. Si no llega respuesta, manda la posición real.
    private func deliver(_ proposal: TradeProposal, key: String, address: String) async throws -> TradeProposal {
        var p = proposal
        do {
            let outcome = try await executor.execute(network: p.network, privateKey: key, address: address, proposal: p)
            p.orderIds = outcome.orderIds
            p.filledSize = outcome.filledSize
            p.avgPrice = outcome.avgPrice
            p.error = outcome.error
            p.status = outcome.status == "failed" ? .failed : .open
            if outcome.status == "resting" { p.error = "Orden límite en el libro: el stop loss se activa cuando se llene." }
        } catch {
            let size = try? await executor.positionSize(network: p.network, address: address, coin: p.coin)
            if let size, size != 0 {
                p.status = .open
                p.filledSize = String(abs(size))
                p.error = "No llegó la confirmación del exchange, pero la posición existe. Verifica en Hyperliquid que tenga su stop loss."
            } else {
                p.status = .failed
                p.error = (size == nil ? "No se pudo confirmar el envío (revisa tus posiciones): " : "") + error.localizedDescription
            }
        }
        try db.saveProposal(p)
        return p
    }

    static func idea(from params: JSONValue) throws -> TradeIdea {
        func str(_ k: String) throws -> String {
            guard let v = params[k]?.stringValue else { throw ValidationError("Falta el parámetro \(k).") }
            return v
        }
        func dbl(_ k: String) throws -> Double {
            guard let v = params[k]?.doubleValue else { throw ValidationError("Falta el parámetro \(k).") }
            return v
        }
        guard let side = TradeSide(rawValue: try str("side")) else { throw ValidationError("side debe ser long o short.") }
        guard let entryType = EntryType(rawValue: try str("entry_type")) else { throw ValidationError("entry_type debe ser market o limit.") }
        guard let leverage = params["leverage"]?.intValue else { throw ValidationError("Falta el parámetro leverage.") }
        return TradeIdea(coin: try str("coin"), side: side, sizeUsd: try dbl("size_usd"), leverage: leverage, entryType: entryType,
                         entryPrice: params["entry_price"]?.doubleValue, stopLoss: try dbl("stop_loss"),
                         takeProfit: params["take_profit"]?.doubleValue, rationale: params["rationale"]?.stringValue ?? "")
    }
}

/// Claves de API wallet en el llavero de macOS, por agente y red.
public struct KeychainTradeKeys: TradeKeyStore {
    let store: CredentialStore
    public init(store: CredentialStore = CredentialStore()) { self.store = store }

    static func account(_ agentId: String, _ network: TradeNetwork) -> String { "hyperliquid.\(agentId).\(network.rawValue)" }

    public func privateKey(agentId: String, network: TradeNetwork) -> String? {
        (try? store.get(Self.account(agentId, network))) ?? nil
    }

    /// Clave privada de la API wallet (no la de la wallet principal): 0x + 64 hex.
    public func save(agentId: String, network: TradeNetwork, privateKey raw: String) throws {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let hex = key.hasPrefix("0x") ? String(key.dropFirst(2)) : key
        guard hex.count == 64, hex.allSatisfy(\.isHexDigit) else {
            throw ValidationError(String(localized: "La clave de la API wallet debe tener 64 caracteres hexadecimales (con o sin 0x)."))
        }
        try store.set(Self.account(agentId, network), value: "0x" + hex.lowercased())
    }

    public func remove(agentId: String, network: TradeNetwork) throws {
        try store.delete(Self.account(agentId, network))
    }
}
