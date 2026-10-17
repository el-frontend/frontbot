import XCTest
@testable import FrontbotCore

final class ScriptSandboxTests: XCTestCase {
    var skillDir: URL!

    override func setUpWithError() throws {
        skillDir = FileManager.default.temporaryDirectory.appendingPathComponent("skill-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: skillDir.appendingPathComponent("scripts"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: skillDir) }

    func script(_ name: String, _ text: String) throws {
        try text.write(to: skillDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func testResolvesOnlyScriptsInsideTheSkill() throws {
        try script("scripts/ok.py", "print(1)")
        XCTAssertTrue(try ScriptSandbox.resolve(script: "scripts/ok.py", in: skillDir).interpreter.hasSuffix("python3"))
        XCTAssertThrowsError(try ScriptSandbox.resolve(script: "../x.py", in: skillDir))
        XCTAssertThrowsError(try ScriptSandbox.resolve(script: "/usr/bin/true", in: skillDir))
        XCTAssertThrowsError(try ScriptSandbox.resolve(script: "scripts/no-existe.py", in: skillDir))
        try script("notas.txt", "x")
        XCTAssertThrowsError(try ScriptSandbox.resolve(script: "notas.txt", in: skillDir)) { error in
            XCTAssertEqual((error as? ValidationError)?.message, "Tipo de script no soportado: notas.txt (usa .py, .sh o .js).")
        }
    }

    func testRunsFromTheSkillRootSoRelativeDataPathsWork() throws {
        // Como en los skills de Anthropic: scripts/x.py lee data/... relativo a la raíz del skill.
        try FileManager.default.createDirectory(at: skillDir.appendingPathComponent("data/1h"), withIntermediateDirectories: true)
        try script("data/1h/BTC.csv", "1,2,3")
        try script("scripts/lee.py", "print(open('data/1h/BTC.csv').read())")
        let result = try ScriptSandbox().run(script: "scripts/lee.py", args: [], in: skillDir)
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "1,2,3")
    }

    func testRunsWithArgumentsAndCanWriteInsideTheSkill() throws {
        try script("scripts/eco.py", """
        import sys, os
        open(os.path.join(os.path.dirname(__file__), "salida.txt"), "w").write("ok")
        print("args:", " ".join(sys.argv[1:]))
        """)
        let result = try ScriptSandbox().run(script: "scripts/eco.py", args: ["BTC", "4h"], in: skillDir)
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "args: BTC 4h")
        XCTAssertTrue(FileManager.default.fileExists(atPath: skillDir.appendingPathComponent("scripts/salida.txt").path))
    }

    func testHasNoNetworkAndCannotTouchTheHomeFolder() throws {
        try script("scripts/escape.py", """
        import os, sys, urllib.request
        home = sys.argv[1]  # HOME dentro de la sandbox apunta al temporal: se pasa la carpeta personal real
        for label, fn in [("home", lambda: open(os.path.join(home, ".zshrc")).read()),
                          ("write", lambda: open(os.path.join(home, "frontbot-escape-test.txt"), "w").write("x")),
                          ("net", lambda: urllib.request.urlopen("http://example.com", timeout=5))]:
            try:
                fn(); print(label, "PERMITIDO")
            except Exception:
                print(label, "bloqueado")
        """)
        let result = try ScriptSandbox().run(script: "scripts/escape.py", args: [NSHomeDirectory()], in: skillDir)
        XCTAssertEqual(result.stdout.components(separatedBy: "\n").filter { !$0.isEmpty }, ["home bloqueado", "write bloqueado", "net bloqueado"], result.stderr)
    }

    func testCannotReadTheClipboardOrSendAppleEvents() throws {
        // Solo binarios que, si no estuvieran bloqueados, no abren nada (no se prueba `open` para no lanzar el navegador).
        try script("scripts/escape.sh", """
        /usr/bin/pbpaste >/dev/null 2>&1 && echo "pbpaste PERMITIDO" || echo "pbpaste bloqueado"
        /usr/bin/osascript -e 'return 1' >/dev/null 2>&1 && echo "osascript PERMITIDO" || echo "osascript bloqueado"
        cp /usr/bin/pbpaste "$TMPDIR/p" && "$TMPDIR/p" >/dev/null 2>&1 && echo "copia pbpaste PERMITIDO" || echo "copia pbpaste bloqueado"
        cp /usr/bin/osascript "$TMPDIR/o" && "$TMPDIR/o" -e 'return 1' >/dev/null 2>&1 && echo "copia osascript PERMITIDO" || echo "copia osascript bloqueado"
        """)
        let result = try ScriptSandbox().run(script: "scripts/escape.sh", args: [], in: skillDir)
        XCTAssertEqual(result.stdout.components(separatedBy: "\n").filter { !$0.isEmpty }, ["pbpaste bloqueado", "osascript bloqueado", "copia pbpaste bloqueado", "copia osascript bloqueado"], result.stderr)
    }

    func testBackgroundChildrenCannotHangTheRun() throws {
        try script("scripts/fork.sh", "(sleep 30 &)\necho listo")
        let start = Date()
        let result = try ScriptSandbox(timeout: 3).run(script: "scripts/fork.sh", args: [], in: skillDir)
        XCTAssertLessThan(Date().timeIntervalSince(start), 8)
        XCTAssertTrue(result.stdout.contains("listo"))
    }

    func testTimeoutKillsTheWholeProcessGroup() throws {
        try script("scripts/hijos.sh", "sleep 40 &\nsleep 40")
        let start = Date()
        let result = try ScriptSandbox(timeout: 1).run(script: "scripts/hijos.sh", args: [], in: skillDir)
        XCTAssertTrue(result.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(start), 6)
    }

    func testRunsJavaScriptWithTheBundledNode() throws {
        let node = ProcessInfo.processInfo.environment["FRONTBOT_NODE"] ?? "/opt/homebrew/bin/node"
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: node), "sin node")
        try script("scripts/hola.js", "console.log('hola desde node')")
        let result = try ScriptSandbox(nodePath: node).run(script: "scripts/hola.js", args: [], in: skillDir)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "hola desde node", result.stderr)
    }

    func testTimesOutAndTruncatesOutput() throws {
        try script("scripts/lento.sh", "sleep 10")
        let slow = try ScriptSandbox(timeout: 1).run(script: "scripts/lento.sh", args: [], in: skillDir)
        XCTAssertTrue(slow.timedOut)
        try script("scripts/mucho.py", "print('x' * 50000)")
        let big = try ScriptSandbox().run(script: "scripts/mucho.py", args: [], in: skillDir)
        XCTAssertLessThanOrEqual(big.stdout.utf8.count, ScriptSandbox.outputLimit + 40)
        XCTAssertTrue(big.stdout.hasSuffix("…[salida recortada]"))
    }
}

final class ScriptToolTests: XCTestCase {
    var db: AppDatabase!
    var library: SkillLibrary!
    var agent: Agent!
    var root: URL!

    override func setUpWithError() throws {
        db = try AppDatabase.inMemory()
        let ws = try db.ensureDefaultWorkspace()
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        library = SkillLibrary(db: db, paths: AppPaths(root: root))
        agent = try db.createAgent(workspaceId: ws.id, draft: AgentDraft(name: "A", instructions: "x"), status: .active)
        let skill = try library.createUserSkill(name: "calc", description: "d", body: "b", files: ["scripts/suma.py": "import sys\nprint(int(sys.argv[1]) + int(sys.argv[2]))"])
        try library.assign(skillId: skill.id, to: agent.id)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func params(_ skill: String = "calc", _ script: String = "scripts/suma.py") -> JSONValue {
        ["agent_id": .string(agent.id), "skill": .string(skill), "script": .string(script), "args": ["2", "3"]]
    }

    func testRunsAfterApprovalShowingTheExactCommand() async throws {
        nonisolated(unsafe) var seen: ScriptRequest?
        let result = try await ScriptTool(library: library).run(params: params()) { request in seen = request; return true }
        XCTAssertEqual(result["stdout"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), "5")
        XCTAssertEqual(result["exit_code"], 0)
        XCTAssertEqual(seen?.agentName, "A")
        XCTAssertEqual(seen?.skillName, "calc")
        XCTAssertEqual(seen?.command, "scripts/suma.py 2 3")
    }

    func testDeniedByTheUser() async throws {
        do {
            _ = try await ScriptTool(library: library).run(params: params()) { _ in false }
            XCTFail("debió fallar")
        } catch let e as ValidationError {
            XCTAssertEqual(e.message, "El usuario denegó la ejecución del script.")
        }
    }

    func testOnlyActiveSkillsAssignedToTheAgentAndNoApprovalForInvalidScripts() async throws {
        nonisolated(unsafe) var asked = false
        let tool = ScriptTool(library: library)
        let approve: @Sendable (ScriptRequest) async -> Bool = { _ in asked = true; return true }
        await XCTAssertThrowsAsync(try await tool.run(params: self.params("otro"), approve: approve))
        await XCTAssertThrowsAsync(try await tool.run(params: self.params("calc", "../x.py"), approve: approve))
        let draft = try library.createDraft(agentId: agent.id, name: "borrador", description: "d", body: "b", files: ["s.py": "print(1)"])
        await XCTAssertThrowsAsync(try await tool.run(params: self.params(draft.name, "s.py"), approve: approve))
        XCTAssertFalse(asked, "no se molesta al usuario con peticiones inválidas")
    }
}

func XCTAssertThrowsAsync<T>(_ expression: @autoclosure () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
    do { _ = try await expression(); XCTFail("debió lanzar un error", file: file, line: line) } catch {}
}
