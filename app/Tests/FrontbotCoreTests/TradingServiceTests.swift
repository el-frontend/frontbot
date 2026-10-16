import XCTest
@testable import FrontbotCore

final class FakeExecutor: TradeExecutor, @unchecked Sendable {
    var price = 60_000.0
    var accountValue: Double? = 1_000
    var outcome = TradeOutcome(status: "open", orderIds: [1], filledSize: "0.00833", avgPrice: "60010", error: nil)
    var executed: [(TradeNetwork, String, TradeProposal)] = []
    var closed: [String] = []
    var executeError: Error?
    var position = 0.0
    var snapshotDelay: Duration = .zero

    func positionSize(network: TradeNetwork, address: String, coin: String) async throws -> Double { position }

    func snapshot(network: TradeNetwork, coin: String, address: String?) async throws -> MarketSnapshot {
        if snapshotDelay > .zero { try await Task.sleep(for: snapshotDelay) }
        return MarketSnapshot(price: price, accountValue: address == nil ? nil : accountValue)
    }
    func execute(network: TradeNetwork, privateKey: String, address: String, proposal: TradeProposal) async throws -> TradeOutcome {
        if let executeError { throw executeError }
        executed.append((network, privateKey, proposal))
        return outcome
    }
    func close(network: TradeNetwork, privateKey: String, address: String, coin: String) async throws { closed.append(coin) }
}

struct FakeKeys: TradeKeyStore {
    var keys: [String: String] = [:]
    func privateKey(agentId: String, network: TradeNetwork) -> String? { keys["\(agentId).\(network.rawValue)"] }
}

final class TradingServiceTests: XCTestCase {
    var db: AppDatabase!
    var agent: Agent!
    var executor: FakeExecutor!
    var service: TradingService!

    override func setUpWithError() throws {
        db = try AppDatabase.inMemory()
        let ws = try db.ensureDefaultWorkspace()
        agent = try db.createAgent(workspaceId: ws.id, draft: AgentTemplate.cryptoTrader.draft, status: .active)
        var mandate = try db.mandate(agentId: agent.id)
        mandate.address = "0x" + String(repeating: "a", count: 40)
        try db.saveMandate(mandate)
        executor = FakeExecutor()
        service = TradingService(db: db, executor: executor, keys: FakeKeys(keys: ["\(agent.id).testnet": "0xkey"]))
    }

    func propose(_ extra: [String: JSONValue] = [:], account: JSONValue = 1_000) throws -> ProposalResult {
        var params: [String: JSONValue] = [
            "agent_id": .string(agent.id), "coin": "BTC", "side": "long", "size_usd": 500, "leverage": 3, "entry_type": "limit",
            "entry_price": 60_000, "stop_loss": 58_800, "take_profit": 63_000, "rationale": "Ruptura",
            "snapshot": ["price": 60_000, "account_value": account, "network": "testnet"],
        ]
        for (k, v) in extra { params[k] = v }
        return try service.propose(params: .object(params))
    }

    func testDefaultMandateIsConservative() throws {
        let m = try db.mandate(agentId: agent.id)
        XCTAssertEqual(m.network, .testnet)
        XCTAssertEqual(m.mode, .approval)
        XCTAssertEqual(m.maxRiskPct, 1)
    }

    func testValidProposalWaitsForTheUserInApprovalMode() throws {
        let r = try propose()
        XCTAssertEqual(r.proposal.status, .proposed)
        XCTAssertFalse(r.autoExecute)
        XCTAssertEqual(r.proposal.riskUsd, 10, accuracy: 0.01)
        XCTAssertEqual(r.json["status"], "proposed")
    }

    func testInvalidProposalIsStoredAsRejectedWithReasons() throws {
        let r = try propose(["stop_loss": 61_000])
        XCTAssertEqual(r.proposal.status, .rejected)
        XCTAssertTrue(r.proposal.error?.contains("stop loss") == true)
        XCTAssertNotNil(r.json["problems"]?.arrayValue?.first)
    }

    func testAgentsWithoutTradingCannotPropose() throws {
        let frontbot = try db.ensureDefaultAgent(workspaceId: try db.ensureDefaultWorkspace().id)
        XCTAssertThrowsError(try service.propose(params: ["agent_id": .string(frontbot.id), "coin": "BTC"])) { error in
            XCTAssertEqual((error as? ValidationError)?.message, "Este agente no tiene trading activado.")
        }
    }

    func testApprovalRechecksWithFreshDataAndExecutes() async throws {
        let id = try propose().proposal.id
        let done = try await service.approve(id: id)
        XCTAssertEqual(done.status, .open)
        XCTAssertEqual(done.filledSize, "0.00833")
        XCTAssertEqual(executor.executed.first?.1, "0xkey")
        XCTAssertFalse(done.auto)
        XCTAssertEqual(try db.tradesToday(agentId: agent.id), 1)
    }

    func testApprovalFailsIfTheMarketMovedPastTheStop() async throws {
        let id = try propose(["entry_type": "market", "entry_price": .null, "stop_loss": 59_000, "size_usd": 300]).proposal.id
        executor.price = 58_900
        await XCTAssertThrowsAsync(try await service.approve(id: id))
        XCTAssertEqual(try db.proposal(id: id)?.status, .proposed, "sigue pendiente para que el agente proponga otra")
        XCTAssertTrue(executor.executed.isEmpty)
    }

    func testApprovalNeedsTheKey() async throws {
        service = TradingService(db: db, executor: executor, keys: FakeKeys())
        let id = try propose().proposal.id
        do { _ = try await service.approve(id: id); XCTFail() } catch let e as ValidationError {
            XCTAssertEqual(e.message, "Conecta tu API wallet de Hyperliquid (testnet) en la página del agente.")
        }
    }

    func testExchangeFailureMarksFailed() async throws {
        executor.outcome = TradeOutcome(status: "failed", orderIds: [], filledSize: nil, avgPrice: nil, error: "Insufficient margin")
        let id = try propose().proposal.id
        let done = try await service.approve(id: id)
        XCTAssertEqual(done.status, .failed)
        XCTAssertEqual(done.error, "Insufficient margin")
    }

    func testAutoModeExecutesOnlyWhatPasses() async throws {
        var m = try db.mandate(agentId: agent.id)
        m.mode = .auto
        try db.saveMandate(m)
        let ok = try propose()
        XCTAssertTrue(ok.autoExecute)
        let done = try await service.executeAuto(id: ok.proposal.id)
        XCTAssertTrue(done.auto)
        XCTAssertEqual(done.status, .open)
        XCTAssertFalse(try propose(["leverage": 10]).autoExecute)
    }

    func testPauseStopsEverything() async throws {
        let id = try propose().proposal.id
        try db.pauseAllTrading()
        XCTAssertTrue(try db.mandate(agentId: agent.id).paused)
        await XCTAssertThrowsAsync(try await service.approve(id: id))
    }

    func testRejectAndClose() async throws {
        let rejected = try service.reject(id: try propose().proposal.id)
        XCTAssertEqual(rejected.status, .cancelled)
        let open = try await service.approve(id: try propose().proposal.id)
        let closed = try await service.close(id: open.id)
        XCTAssertEqual(closed.status, .closed)
        XCTAssertEqual(executor.closed, ["BTC"])
    }

    func testAProposalCanOnlyBeSentOnceEvenIfAutoAndManualRace() async throws {
        executor.snapshotDelay = .milliseconds(200)
        let id = try propose().proposal.id
        let svc = service!
        async let first = try? svc.approve(id: id)
        async let second = try? svc.approve(id: id)
        let results = await [first, second]
        XCTAssertEqual(results.compactMap { $0 }.count, 1)
        XCTAssertEqual(executor.executed.count, 1)
    }

    func testRejectDoesNotOverrideASendInProgress() async throws {
        executor.snapshotDelay = .milliseconds(200)
        let id = try propose().proposal.id
        let svc = service!
        async let sent = try? svc.approve(id: id)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertThrowsError(try service.reject(id: id))
        _ = await sent
        XCTAssertEqual(try db.proposal(id: id)?.status, .open)
    }

    func testFailedPreconditionsReleaseTheProposal() async throws {
        let id = try propose().proposal.id
        executor.price = 58_000 // la entrada límite ya está por debajo del stop: no cumple
        try db.pauseAllTrading()
        await XCTAssertThrowsAsync(try await service.approve(id: id))
        let p = try XCTUnwrap(try db.proposal(id: id))
        XCTAssertEqual(p.status, .proposed)
        XCTAssertNil(p.executedAt)
        XCTAssertEqual(try db.tradesToday(agentId: agent.id), 0)
    }

    func testAutoSendRequiresAutoModeAtSendTime() async throws {
        let id = try propose().proposal.id // modo aprobación
        await XCTAssertThrowsAsync(try await service.executeAuto(id: id))
        XCTAssertTrue(executor.executed.isEmpty)
    }

    func testProposalFromAnotherNetworkIsRejected() throws {
        var params: [String: JSONValue] = [
            "agent_id": .string(agent.id), "coin": "BTC", "side": "long", "size_usd": 500, "leverage": 3, "entry_type": "limit",
            "entry_price": 60_000, "stop_loss": 58_800, "rationale": "r",
            "snapshot": ["price": 60_000, "account_value": 1_000, "network": "mainnet"],
        ]
        params["take_profit"] = 63_000
        let r = try service.propose(params: .object(params))
        XCTAssertEqual(r.proposal.status, .rejected)
        XCTAssertTrue(r.proposal.error?.contains("red") == true)
    }

    func testWhenTheExchangeDoesNotAnswerTheRealPositionDecides() async throws {
        executor.executeError = AgentClientError.timeout
        executor.position = 0.00833
        let open = try await service.approve(id: try propose().proposal.id)
        XCTAssertEqual(open.status, .open)
        XCTAssertTrue(open.error?.contains("stop loss") == true)
        executor.position = 0
        let failed = try await service.approve(id: try propose().proposal.id)
        XCTAssertEqual(failed.status, .failed)
    }

    func testAgentsWithOpenTradesCannotBeDeleted() async throws {
        _ = try await service.approve(id: try propose().proposal.id)
        XCTAssertThrowsError(try db.deleteAgent(id: agent.id)) { error in
            XCTAssertEqual((error as? ValidationError)?.message, "Crypto Trader tiene trades abiertos: ciérralos antes de borrarlo.")
        }
    }

    func testUnfinishedSendsAreFlaggedOnLaunch() throws {
        var p = try propose().proposal
        p.status = .sending
        try db.saveProposal(p)
        XCTAssertEqual(try db.flagInterruptedSends(), 1)
        XCTAssertEqual(try db.proposal(id: p.id)?.status, .failed)
    }
}

/// De punta a punta con el sidecar (agente y trader falsos): proponer → aprobar → enviar.
final class TradingFlowTests: XCTestCase {
    func testProposeThenApproveThroughTheSidecar() async throws {
        let db = try AppDatabase.inMemory()
        let ws = try db.ensureDefaultWorkspace()
        let node = ProcessInfo.processInfo.environment["FRONTBOT_NODE"] ?? "/opt/homebrew/bin/node"
        let script = AgentClientTests.repoRoot.appendingPathComponent("agent/dist/main.js").path
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: node), "usa FRONTBOT_NODE=$(which node)")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let client = AgentClient(config: AgentConfig(nodePath: node, scriptPath: script, apiKey: nil, model: "m", fakeAgent: true),
                                 db: db, files: BrandFiles(paths: AppPaths(root: root)), workspaceId: ws.id)
        let trader = try db.createAgent(workspaceId: ws.id, draft: AgentTemplate.cryptoTrader.draft, status: .active)
        var mandate = try db.mandate(agentId: trader.id)
        mandate.address = "0x" + String(repeating: "b", count: 40)
        try db.saveMandate(mandate)
        await client.setTradeKeys(FakeKeys(keys: ["\(trader.id).testnet": "0xkey"]))

        let stream = await client.updates()
        let run = try await client.run(prompt: "proponer trade", agent: trader, brand: nil)
        var proposal: TradeProposal?
        var texts: [String] = []
        for await update in stream {
            if case .tradesChanged(let p) = update { proposal = p }
            if case .event(let id, "text", let t) = update, id == run.id { texts.append(t) }
            if case .finished(let r) = update, r.id == run.id { break }
        }
        XCTAssertTrue(texts.contains("Propuesta: proposed"), "\(texts)")
        let pending = try XCTUnwrap(proposal)
        XCTAssertEqual(pending.status, .proposed)

        let done = try await client.trading.approve(id: pending.id)
        XCTAssertEqual(done.status, .open)
        XCTAssertEqual(done.filledSize, "0.0075")
        await client.stop()
    }
}
