import Foundation
import GRDB

public enum TradeNetwork: String, Codable, Sendable, CaseIterable { case testnet, mainnet }
public enum TradeMode: String, Codable, Sendable { case approval, auto }
public enum TradeSide: String, Codable, Sendable { case long, short }
public enum EntryType: String, Codable, Sendable { case market, limit }
public enum TradeStatus: String, Codable, Sendable {
    case proposed, rejected, sending, open, failed, closed, cancelled
}

/// Límites de un agente con trading. Los valida la app, no el agente.
public struct TradingMandate: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    public var agentId: String
    public var network: TradeNetwork
    public var mode: TradeMode
    public var maxRiskPct: Double
    public var maxLeverage: Int
    public var coins: [String]
    public var maxTradesPerDay: Int
    public var paused: Bool
    /// Dirección de la wallet principal (pública); la clave de la API wallet va en el llavero.
    public var address: String?
    public var updatedAt: Date

    public static func `default`(agentId: String) -> TradingMandate {
        TradingMandate(agentId: agentId, network: .testnet, mode: .approval, maxRiskPct: 1, maxLeverage: 3,
                       coins: ["BTC", "ETH"], maxTradesPerDay: 3, paused: false, address: nil, updatedAt: .dbNow())
    }
}

/// Lo que propone el agente con `trade_propose`.
public struct TradeIdea: Equatable, Sendable {
    public var coin: String
    public var side: TradeSide
    public var sizeUsd: Double
    public var leverage: Int
    public var entryType: EntryType
    public var entryPrice: Double?
    public var stopLoss: Double
    public var takeProfit: Double?
    public var rationale: String

    public init(coin: String, side: TradeSide, sizeUsd: Double, leverage: Int, entryType: EntryType, entryPrice: Double?,
                stopLoss: Double, takeProfit: Double?, rationale: String) {
        self.coin = coin; self.side = side; self.sizeUsd = sizeUsd; self.leverage = leverage; self.entryType = entryType
        self.entryPrice = entryPrice; self.stopLoss = stopLoss; self.takeProfit = takeProfit; self.rationale = rationale
    }
}

public struct TradeCheck: Equatable, Sendable {
    public let entry: Double
    public let riskUsd: Double
    public let problems: [String]
    public var ok: Bool { problems.isEmpty }
}

/// Reglas de riesgo que la app exige antes de enviar cualquier orden (también en modo automático).
public enum TradeRules {
    /// Margen para redondeos del tamaño al tick del exchange.
    static let riskTolerance = 1.01

    /// Deslizamiento máximo de una entrada a mercado (fracción del precio): 10 % de la distancia al stop, tope 0,5 %.
    /// El sidecar usa el mismo límite en la orden IOC, así el riesgo real nunca supera el validado.
    public static func marketSlippage(entry: Double, stop: Double) -> Double {
        guard entry > 0 else { return 0 }
        return min(0.005, 0.1 * abs(entry - stop) / entry)
    }

    public static func check(_ idea: TradeIdea, mandate: TradingMandate, accountValue: Double, currentPrice: Double, tradesToday: Int) -> TradeCheck {
        var problems: [String] = []
        let coin = idea.coin.uppercased()
        if mandate.paused { problems.append("el trading está pausado") }
        if !mandate.coins.map({ $0.uppercased() }).contains(coin) { problems.append("\(coin) no está entre las monedas del mandato") }
        if idea.leverage < 1 { problems.append("el apalancamiento debe ser al menos 1x") }
        if idea.leverage > mandate.maxLeverage {
            problems.append("apalancamiento \(idea.leverage)x supera el máximo del mandato (\(mandate.maxLeverage)x)")
        }
        if idea.sizeUsd <= 0 { problems.append("el tamaño debe ser mayor que cero") }
        if idea.rationale.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { problems.append("falta el razonamiento del trade") }

        let entry: Double
        switch idea.entryType {
        case .market: entry = currentPrice
        case .limit:
            entry = idea.entryPrice ?? 0
            if (idea.entryPrice ?? 0) <= 0 { problems.append("una orden límite necesita precio de entrada") }
        }
        guard entry > 0 else { return TradeCheck(entry: 0, riskUsd: 0, problems: problems.isEmpty ? ["no hay precio de referencia"] : problems) }

        if idea.stopLoss <= 0 { problems.append("falta el stop loss") }
        switch idea.side {
        case .long:
            if idea.stopLoss >= entry { problems.append("el stop loss debe estar por debajo de la entrada en un long") }
            if let tp = idea.takeProfit, tp <= entry { problems.append("el take profit debe estar por encima de la entrada en un long") }
        case .short:
            if idea.stopLoss <= entry { problems.append("el stop loss debe estar por encima de la entrada en un short") }
            if let tp = idea.takeProfit, tp >= entry { problems.append("el take profit debe estar por debajo de la entrada en un short") }
        }

        let slippage = idea.entryType == .market ? marketSlippage(entry: entry, stop: idea.stopLoss) : 0
        let riskUsd = idea.sizeUsd * (abs(entry - idea.stopLoss) / entry + slippage)
        let maxRisk = accountValue * mandate.maxRiskPct / 100
        if riskUsd > maxRisk * riskTolerance {
            problems.append(String(format: "riesgo de %.2f USD supera el %@%% de la cuenta (%.2f USD)",
                                   riskUsd, Self.trim(mandate.maxRiskPct), maxRisk))
        }
        let margin = idea.sizeUsd / Double(max(idea.leverage, 1))
        if margin > accountValue { problems.append(String(format: "el margen (%.2f USD) supera el valor de la cuenta", margin)) }
        if tradesToday >= mandate.maxTradesPerDay {
            problems.append("ya se hicieron \(tradesToday) trades hoy (máximo \(mandate.maxTradesPerDay))")
        }
        return TradeCheck(entry: entry, riskUsd: riskUsd, problems: problems)
    }

    static func trim(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(value)
    }
}

/// Un trade propuesto por un agente y lo que pasó con él.
public struct TradeProposal: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable {
    public var id: String
    public var agentId: String
    public var network: TradeNetwork
    public var coin: String
    public var side: TradeSide
    public var sizeUsd: Double
    public var leverage: Int
    public var entryType: EntryType
    public var entryPrice: Double?
    public var stopLoss: Double
    public var takeProfit: Double?
    public var rationale: String
    public var riskUsd: Double
    public var referencePrice: Double
    public var status: TradeStatus
    public var auto: Bool
    public var orderIds: [Int]
    public var filledSize: String?
    public var avgPrice: String?
    public var error: String?
    public var executedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public var idea: TradeIdea {
        TradeIdea(coin: coin, side: side, sizeUsd: sizeUsd, leverage: leverage, entryType: entryType, entryPrice: entryPrice,
                  stopLoss: stopLoss, takeProfit: takeProfit, rationale: rationale)
    }
}
