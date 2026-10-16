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
        let config = AgentConfig(nodePath: node, scriptPath: script, apiKey: nil, model: "m", fakeAgent: true, browserProfileDir: root.path)
        return AgentClient(config: config, db: db, files: BrandFiles(paths: AppPaths(root: root)), workspaceId: ws.id)
    }

    func testPreparePublicationWithoutApiKey() async throws {
        let client = try makeClient()
        let result = try await client.preparePublication(network: .linkedin, body: "hola", mediaPaths: [])
        XCTAssertEqual(result, PreparationResult(mode: .composer, message: "(prueba) compositor listo", url: "https://www.linkedin.com/feed/"))
        await client.stop()
    }

    func testRemoteErrorsPropagate() async throws {
        let client = try makeClient()
        do {
            _ = try await client.preparePublication(network: .linkedin, body: "falla", mediaPaths: [])
            XCTFail("debió fallar")
        } catch let error as AgentClientError {
            XCTAssertEqual(error, .remote("Chrome no está disponible"))
            XCTAssertEqual(error.localizedDescription, "Chrome no está disponible")
        }
        await client.stop()
    }

    func testUnknownMethodReturnsRemoteError() async throws {
        let client = try makeClient()
        do {
            _ = try await client.call("no.existe", params: [:], timeout: .seconds(5))
            XCTFail("debió fallar")
        } catch let error as AgentClientError {
            XCTAssertEqual(error, .remote("Método desconocido: no.existe"))
        }
        await client.stop()
    }

    func testCallTimesOut() async throws {
        let client = try makeClient()
        let params: JSONValue = ["network": "linkedin", "body": "lento", "media": [], "profile_dir": "/tmp/x"]
        do {
            _ = try await client.call("publish.prepare", params: params, timeout: .milliseconds(300))
            XCTFail("debió fallar")
        } catch let error as AgentClientError {
            XCTAssertEqual(error, .timeout)
            XCTAssertEqual(error.localizedDescription, "El agente no respondió a tiempo.")
        }
        await client.stop()
    }

    func testPendingCallFailsWhenSidecarStops() async throws {
        let client = try makeClient()
        let params: JSONValue = ["network": "linkedin", "body": "lento", "media": [], "profile_dir": "/tmp/x"]
        async let pending = client.call("publish.prepare", params: params, timeout: .seconds(30))
        try await Task.sleep(for: .milliseconds(500)) // la llamada ya está en vuelo
        await client.stop()
        do {
            _ = try await pending
            XCTFail("debió fallar")
        } catch let error as AgentClientError {
            XCTAssertEqual(error, .remote("El agente se detuvo inesperadamente."))
        }
    }
}
