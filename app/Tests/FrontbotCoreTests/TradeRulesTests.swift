import XCTest
@testable import FrontbotCore

final class TradeRulesTests: XCTestCase {
    let mandate = TradingMandate.default(agentId: "a")   // testnet, aprobación, 1 %, 3x, BTC/ETH, 3/día

    func idea(coin: String = "BTC", side: TradeSide = .long, sizeUsd: Double = 500, leverage: Int = 3,
              entryType: EntryType = .limit, entry: Double? = 60_000, stop: Double = 58_800, tp: Double? = 63_000) -> TradeIdea {
        TradeIdea(coin: coin, side: side, sizeUsd: sizeUsd, leverage: leverage, entryType: entryType, entryPrice: entry,
                  stopLoss: stop, takeProfit: tp, rationale: "Ruptura con retesteo")
    }

    func check(_ i: TradeIdea, account: Double = 1_000, price: Double = 60_000, today: Int = 0, mandate m: TradingMandate? = nil) -> TradeCheck {
        TradeRules.check(i, mandate: m ?? mandate, accountValue: account, currentPrice: price, tradesToday: today)
    }

    func testAValidLongPassesAndComputesRisk() {
        let r = check(idea())
        XCTAssertEqual(r.problems, [])
        XCTAssertEqual(r.entry, 60_000)
        XCTAssertEqual(r.riskUsd, 10, accuracy: 0.001) // 500 × 2 %
    }

    func testMarketOrdersUseTheCurrentPrice() {
        let r = check(idea(sizeUsd: 300, entryType: .market, entry: nil, stop: 59_000, tp: nil), price: 61_000)
        XCTAssertEqual(r.entry, 61_000)
        XCTAssertEqual(r.problems, [])
    }

    func testRejections() {
        let cases: [(String, TradeCheck)] = [
            ("el stop loss debe estar por debajo de la entrada", check(idea(stop: 60_500))),
            ("el stop loss debe estar por encima de la entrada", check(idea(side: .short, stop: 59_000, tp: 57_000))),
            ("el take profit debe estar por encima de la entrada", check(idea(tp: 59_500))),
            ("apalancamiento 5x supera el máximo del mandato (3x)", check(idea(leverage: 5))),
            ("SOL no está entre las monedas del mandato", check(idea(coin: "SOL"))),
            ("riesgo de 20.00 USD supera el 1% de la cuenta (10.00 USD)", check(idea(sizeUsd: 1_000))),
            ("ya se hicieron 3 trades hoy (máximo 3)", check(idea(), today: 3)),
            ("una orden límite necesita precio de entrada", check(idea(entry: nil))),
            ("el margen (334.00 USD) supera el valor de la cuenta", check(idea(sizeUsd: 1_002, leverage: 3, stop: 59_999), account: 300)),
        ]
        for (expected, result) in cases {
            XCTAssertTrue(result.problems.contains { $0.contains(expected) }, "esperaba «\(expected)», obtuvo \(result.problems)")
        }
    }

    func testPausedTradingRejectsEverything() {
        var m = mandate
        m.paused = true
        XCTAssertTrue(check(idea(), mandate: m).problems.contains("el trading está pausado"))
    }

    func testLowercaseCoinsAreNormalized() {
        XCTAssertEqual(check(idea(coin: "btc")).problems, [])
    }

    func testRiskToleranceAllowsRounding() {
        // 10.05 USD de riesgo con 10 permitido: tolerancia del 1 % para redondeos de tamaño.
        XCTAssertEqual(check(idea(sizeUsd: 502.5)).problems, [])
    }
}
