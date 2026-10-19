import XCTest
@testable import FrontbotCore

final class WorkdirTests: XCTestCase {
    var home: String!
    var data: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        for dir in ["work", ".ssh", "Library", "Documents/proyecto"] {
            try FileManager.default.createDirectory(at: base.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        home = AgentFiles.realPath(base.path)
        data = URL(fileURLWithPath: home + "/Library/Application Support/Frontbot")
    }

    func testRejectsHomeRootAndProtectedAncestors() {
        for path in [home!, "/", home + "/Library", home + "/.ssh", home + "/nope"] {
            XCTAssertThrowsError(try Workdir.validated(path, home: home, protected: [data]), path)
        }
    }

    func testValidatedReturnsRealPathThroughSymlinks() throws {
        try FileManager.default.createSymbolicLink(atPath: home + "/link", withDestinationPath: home + "/work")
        XCTAssertEqual(try Workdir.validated(home + "/link", home: home, protected: [data]), home + "/work")
    }

    func testErrorMessages() {
        XCTAssertThrowsError(try Workdir.validated(home, home: home, protected: [])) {
            XCTAssertEqual(($0 as? ValidationError)?.message, "Elige una carpeta concreta, no toda tu carpeta personal.")
        }
        XCTAssertThrowsError(try Workdir.validated(home + "/.ssh", home: home, protected: [])) {
            XCTAssertEqual(($0 as? ValidationError)?.message, "Esa carpeta contiene datos protegidos (claves, llaveros o datos de Frontbot).")
        }
    }

    func testIsBroad() {
        XCTAssertTrue(Workdir.isBroad(home + "/Documents", home: home))
        XCTAssertFalse(Workdir.isBroad(home + "/Documents/proyecto", home: home))
    }

    func testAlwaysDeniedMatchesSidecarList() {
        XCTAssertEqual(Workdir.alwaysDenied(home: "/h"), ["/h/.ssh", "/h/.aws", "/h/.gnupg", "/h/Library/Keychains",
                       "/h/Library/Application Support/Frontbot", "/h/Library/Application Support/Google/Chrome"])
    }

    func testValidatedDomain() throws {
        XCTAssertEqual(try Workdir.validatedDomain("*.Example.com "), "*.example.com")
        for bad in ["*", "https://x.com", "x.com/a", "x.com:80", "localhost"] {
            XCTAssertThrowsError(try Workdir.validatedDomain(bad), bad)
        }
    }

    func testNetworkDomainsRoundTrip() throws {
        let db = try AppDatabase.inMemory()
        let ws = try db.ensureDefaultWorkspace()
        let agent = try db.ensureDefaultAgent(workspaceId: ws.id)
        XCTAssertNil(agent.networkDomains)
        try db.setNetworkDomains(agentId: agent.id, ["a.com", "*.b.com"])
        XCTAssertEqual(try db.agent(id: agent.id)?.networkDomains, ["a.com", "*.b.com"])
        try db.setNetworkDomains(agentId: agent.id, nil)
        XCTAssertNil(try db.agent(id: agent.id)?.networkDomains)
    }

    func testConversationWorkdirRoundTrip() throws {
        let db = try AppDatabase.inMemory()
        let ws = try db.ensureDefaultWorkspace()
        let agent = try db.ensureDefaultAgent(workspaceId: ws.id)
        let c = try db.createConversation(workspaceId: ws.id, agentId: agent.id, brandId: nil, firstPrompt: "hola")
        XCTAssertNil(c.workdir)
        XCTAssertEqual(c.readDirs, [])
        try db.setWorkdir(conversationId: c.id, path: home + "/work")
        try db.setReadDirs(conversationId: c.id, [home + "/Documents"])
        let back = try db.conversations(workspaceId: ws.id, limit: 5).first
        XCTAssertEqual(back?.workdir, home + "/work")
        XCTAssertEqual(back?.readDirs, [home + "/Documents"])
    }

    // MARK: AgentClient

    func makeClient() throws -> (AgentClient, AppDatabase, Workspace, Agent) {
        let db = try AppDatabase.inMemory()
        let ws = try db.ensureDefaultWorkspace()
        let agent = try db.ensureDefaultAgent(workspaceId: ws.id)
        let node = ProcessInfo.processInfo.environment["FRONTBOT_NODE"] ?? "/opt/homebrew/bin/node"
        let script = AgentClientTests.repoRoot.appendingPathComponent("agent/dist/main.js").path
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: node), "Usa FRONTBOT_NODE=$(which node)")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: script), "Compila el sidecar: cd agent && npm run build")
        let config = AgentConfig(nodePath: node, scriptPath: script, apiKey: nil, model: AgentConfig.defaultModel, fakeAgent: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (AgentClient(config: config, db: db, files: BrandFiles(paths: AppPaths(root: root)), workspaceId: ws.id), db, ws, agent)
    }

    func testRunWithDeletedWorkdirFailsAndLeavesNoRunningRun() async throws {
        let (client, db, ws, agent) = try makeClient()
        var c = try db.createConversation(workspaceId: ws.id, agentId: agent.id, brandId: nil, firstPrompt: "hola")
        c.workdir = home + "/borrada"
        do {
            _ = try await client.run(prompt: "hola", agent: agent, brand: nil, workdir: c)
            XCTFail("debía lanzar")
        } catch let error as ValidationError {
            XCTAssertEqual(error.message, "La carpeta \(home!)/borrada ya no existe: elige otra o quítala.")
        }
        XCTAssertFalse(try db.runs(workspaceId: ws.id).contains { $0.status == .running })
        await client.stop()
    }

    func testApproveForUnknownRunDeniesWithoutCallingApprover() async throws {
        let (client, _, _, _) = try makeClient()
        let called = Called()
        await client.setWorkdirApprover { _ in await called.mark(); return true }
        let line = try RPCMessage.request(id: 7, method: "workdir.approve", params: ["run_id": "nada", "kind": "unsandboxed", "command": "ls"]).encodedLine()
        await client.receive(line, generation: 0)
        let was = await called.value
        XCTAssertFalse(was)
        await client.stop()
    }
}

private actor Called {
    var value = false
    func mark() { value = true }
}
