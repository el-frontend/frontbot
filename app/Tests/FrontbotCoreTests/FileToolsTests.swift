import XCTest
@testable import FrontbotCore

final class FileToolsTests: XCTestCase {
    var db: AppDatabase!
    var paths: AppPaths!
    var handler: ToolHandler!
    var agent: Agent!
    var base: URL!
    var folder: URL!

    override func setUpWithError() throws {
        db = try AppDatabase.inMemory()
        let ws = try db.ensureDefaultWorkspace()
        base = URL(fileURLWithPath: ScriptSandbox.realPath(FileManager.default.temporaryDirectory)).appendingPathComponent(UUID().uuidString)
        folder = base.appendingPathComponent("marcas")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        paths = AppPaths(root: base.appendingPathComponent("Frontbot"))
        handler = ToolHandler(db: db, files: BrandFiles(paths: paths), workspaceId: ws.id)
        agent = try db.createAgent(workspaceId: ws.id, draft: AgentDraft(name: "Redactor", instructions: "x"), status: .active)
        try db.addFolder(agentId: agent.id, path: folder.path)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: base) }

    func testListAndReadInsideTheAgentsFolders() throws {
        try "hola".write(to: folder.appendingPathComponent("nota.md"), atomically: true, encoding: .utf8)
        let listing = try handler.handle(method: "tool.files_list", params: ["agent_id": .string(agent.id), "path": .string(folder.path)])
        XCTAssertEqual(listing["entries"]?.arrayValue?.first?["name"], "nota.md")
        XCTAssertEqual(listing["entries"]?.arrayValue?.first?["type"], "file")
        let read = try handler.handle(method: "tool.files_read", params: ["agent_id": .string(agent.id), "path": .string(folder.path + "/nota.md")])
        XCTAssertEqual(read["content"], "hola")
        XCTAssertEqual(read["truncated"], false)
    }

    func testFoldersListsWhatTheAgentCanUse() throws {
        let result = try handler.handle(method: "tool.files_folders", params: ["agent_id": .string(agent.id)])
        XCTAssertEqual(result["folders"], .array([.string(folder.path)]))
    }

    func testOtherAgentsCannotUseTheseFolders() throws {
        let frontbot = try db.ensureDefaultAgent(workspaceId: agent.workspaceId)
        XCTAssertThrowsError(try handler.handle(method: "tool.files_list", params: ["agent_id": .string(frontbot.id), "path": .string(folder.path)]))
    }

    func testWriteNeedsApproval() async throws {
        let tool = FileWriteTool(db: db, paths: paths)
        let target = folder.appendingPathComponent("post.md").path
        let params: JSONValue = ["agent_id": .string(agent.id), "path": .string(target), "content": "# Post"]

        await XCTAssertThrowsErrorAsync(try await tool.run(params: params) { _ in false })
        XCTAssertFalse(FileManager.default.fileExists(atPath: target))

        nonisolated(unsafe) var seen: FileWriteRequest?
        let result = try await tool.run(params: params) { request in seen = request; return true }
        XCTAssertEqual(seen, FileWriteRequest(agentName: "Redactor", path: target, content: "# Post", replaces: false, previousSize: nil))
        XCTAssertEqual(result["written"], .string(target))
        XCTAssertEqual(try String(contentsOfFile: target, encoding: .utf8), "# Post")
    }

    func testInvalidWritesAreRejectedBeforeAskingTheUser() async throws {
        let tool = FileWriteTool(db: db, paths: paths)
        nonisolated(unsafe) var asked = false
        let outside: JSONValue = ["agent_id": .string(agent.id), "path": .string(base.appendingPathComponent("x.md").path), "content": "x"]
        await XCTAssertThrowsErrorAsync(try await tool.run(params: outside) { _ in asked = true; return true })
        XCTAssertFalse(asked)
    }
}

func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
    do {
        _ = try await expression()
        XCTFail("se esperaba un error", file: file, line: line)
    } catch {}
}

/// Con el sidecar real (agente falso): la escritura pasa por la aprobación y no existe en tareas programadas.
final class FileWriteThroughSidecarTests: XCTestCase {
    func testChatWritesAfterApprovalAndScheduledRunsCannot() async throws {
        let db = try AppDatabase.inMemory()
        let ws = try db.ensureDefaultWorkspace()
        let node = ProcessInfo.processInfo.environment["FRONTBOT_NODE"] ?? "/opt/homebrew/bin/node"
        let script = AgentClientTests.repoRoot.appendingPathComponent("agent/dist/main.js").path
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: node), "usa FRONTBOT_NODE=$(which node)")
        let base = URL(fileURLWithPath: ScriptSandbox.realPath(FileManager.default.temporaryDirectory)).appendingPathComponent(UUID().uuidString)
        let folder = base.appendingPathComponent("marcas")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let client = AgentClient(config: AgentConfig(nodePath: node, scriptPath: script, apiKey: nil, model: "m", fakeAgent: true),
                                 db: db, files: BrandFiles(paths: AppPaths(root: base.appendingPathComponent("Frontbot"))), workspaceId: ws.id)
        let agent = try db.ensureDefaultAgent(workspaceId: ws.id)
        try db.addFolder(agentId: agent.id, path: folder.path)
        let asked = Counter()
        await client.setFileWriteApprover { _ in await asked.increment(); return true }

        func summary(_ run: () async throws -> AgentRun) async throws -> String? {
            let stream = await client.updates()
            let id = try await run().id
            for await update in stream { if case .finished(let r) = update, r.id == id { return r.resultSummary } }
            return nil
        }

        let task = try db.createTask(agentId: agent.id, draft: TaskDraft(name: "Prueba", instruction: "escribir", schedule: .daily(TimeOfDay(9, 0))),
                                     status: .active, createdBy: nil)
        let scheduled = try await summary { try await client.run(prompt: "escribir", agent: agent, brand: nil, task: task) }
        XCTAssertTrue(scheduled?.hasPrefix("No escrito") == true, scheduled ?? "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("fake.txt").path))
        let askedInScheduled = await asked.value
        XCTAssertEqual(askedInScheduled, 0, "en una tarea programada ni se pregunta")

        let chat = try await summary { try await client.run(prompt: "escribir", agent: agent, brand: nil) }
        XCTAssertEqual(chat, "Escrito")
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("fake.txt"), encoding: .utf8), "hola")
        let askedInChat = await asked.value
        XCTAssertEqual(askedInChat, 1)
        await client.stop()
    }
}

private actor Counter {
    var value = 0
    func increment() { value += 1 }
}
