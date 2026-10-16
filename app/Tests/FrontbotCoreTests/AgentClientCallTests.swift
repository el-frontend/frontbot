import XCTest
@testable import FrontbotCore

final class AgentClientCallTests: XCTestCase {
    func makeClient() throws -> AgentClient {
        let db = try AppDatabase.inMemory()
        let ws = try db.ensureDefaultWorkspace()
        let node = ProcessInfo.processInfo.environment["FRONTBOT_NODE"] ?? "/opt/homebrew/bin/node"
        let script = AgentClientTests.repoRoot.appendingPathComponent("agent/dist/main.js").path
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: node), "usa FRONTBOT_NODE=$(which node)")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let config = AgentConfig(nodePath: node, scriptPath: script, apiKey: nil, model: "m", fakeAgent: true)
        return AgentClient(config: config, db: db, files: BrandFiles(paths: AppPaths(root: root)), workspaceId: ws.id)
    }

    func testCallReturnsTheSidecarResult() async throws {
        let client = try makeClient()
        let result = try await client.call("market.snapshot", params: ["network": "testnet", "coin": "BTC", "address": "0x1"])
        XCTAssertEqual(result["price"], 60_000)
        XCTAssertEqual(result["account_value"], 1_000)
        await client.stop()
    }

    func testRemoteErrorsPropagate() async throws {
        let client = try makeClient()
        do {
            _ = try await client.call("market.snapshot", params: ["network": "testnet", "coin": "FALLA"])
            XCTFail("debió fallar")
        } catch let error as AgentClientError {
            XCTAssertEqual(error, .remote("Hyperliquid no responde"))
        }
        await client.stop()
    }

    func testUnknownMethod() async throws {
        let client = try makeClient()
        do {
            _ = try await client.call("no.existe", params: [:], timeout: .seconds(5))
            XCTFail("debió fallar")
        } catch let error as AgentClientError {
            XCTAssertEqual(error, .remote("Método desconocido: no.existe"))
        }
        await client.stop()
    }
}
