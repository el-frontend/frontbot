import XCTest
@testable import FrontbotCore

final class SkillManifestTests: XCTestCase {
    func testParsesFrontmatter() throws {
        let m = try SkillManifest.parse("""
        ---
        name: analisis-tecnico
        description: "Lee patrones de velas: úsalo al analizar un gráfico."
        license: MIT
        ---

        # Análisis técnico
        """)
        XCTAssertEqual(m.name, "analisis-tecnico")
        XCTAssertEqual(m.description, "Lee patrones de velas: úsalo al analizar un gráfico.")
        XCTAssertEqual(m.body.trimmingCharacters(in: .whitespacesAndNewlines), "# Análisis técnico")
    }

    func testRejectsInvalidManifests() {
        XCTAssertThrowsError(try SkillManifest.parse("# sin frontmatter"))
        XCTAssertThrowsError(try SkillManifest.parse("---\nname: Mal Nombre\ndescription: x\n---\n"))
        XCTAssertThrowsError(try SkillManifest.parse("---\nname: ok\n---\n"), "falta description")
        XCTAssertThrowsError(try SkillManifest.parse("---\nname: \(String(repeating: "a", count: 65))\ndescription: x\n---\n"))
    }

    func testRendersAValidManifest() throws {
        let text = SkillManifest.render(name: "mi-skill", description: "Úsalo para: probar", body: "Hola")
        let m = try SkillManifest.parse(text)
        XCTAssertEqual(m.description, "Úsalo para: probar")
        XCTAssertEqual(m.body.trimmingCharacters(in: .whitespacesAndNewlines), "Hola")
    }
}

final class SkillLibraryTests: XCTestCase {
    var db: AppDatabase!
    var ws: Workspace!
    var root: URL!
    var library: SkillLibrary!
    var agent: Agent!

    override func setUpWithError() throws {
        db = try AppDatabase.inMemory()
        ws = try db.ensureDefaultWorkspace()
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        library = SkillLibrary(db: db, paths: AppPaths(root: root))
        agent = try db.createAgent(workspaceId: ws.id, draft: AgentDraft(name: "A", instructions: "x"), status: .active)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func makeFolder(_ name: String, manifest: String, extra: [String: String] = [:]) throws -> URL {
        let dir = root.appendingPathComponent("src/\(name)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try manifest.write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        for (path, text) in extra {
            let url = dir.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        return dir
    }

    func testImportFolderCopiesAndDetectsScripts() throws {
        let src = try makeFolder("x", manifest: "---\nname: fib\ndescription: Calcula fibonacci\n---\nUsa scripts/fib.py",
                                 extra: ["scripts/fib.py": "print(1)", "reference.md": "ref"])
        let skill = try library.importFolder(src)
        XCTAssertEqual(skill.name, "fib")
        XCTAssertEqual(skill.source, .imported)
        XCTAssertEqual(skill.status, .active)
        XCTAssertTrue(skill.hasScripts)
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.directory(for: skill).appendingPathComponent("scripts/fib.py").path))
        XCTAssertEqual(try library.files(of: skill).sorted(), ["SKILL.md", "reference.md", "scripts/fib.py"])
    }

    func testCancellingApprovedScriptStopsItsProcess() async throws {
        let skill = try library.createUserSkill(name: "cancelable", description: "d", body: "b", files: [
            "scripts/wait.py": "import time\nopen('started.txt', 'w').write('yes')\ntime.sleep(5)\nopen('late.txt', 'w').write('no')\n",
        ])
        try library.assign(skillId: skill.id, to: agent.id)
        let directory = library.directory(for: skill)
        let tool = ScriptTool(library: library)
        let agentId = agent.id
        let skillName = skill.name
        let task = Task {
            try await tool.run(params: ["agent_id": .string(agentId), "skill": .string(skillName), "script": .string("scripts/wait.py")]) { _ in true }
        }

        let started = directory.appendingPathComponent("started.txt")
        for _ in 0..<40 where !FileManager.default.fileExists(atPath: started.path) {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: started.path), "The approved script should start before cancellation.")
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("A cancelled script run should throw cancellation.")
        } catch is CancellationError {
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("late.txt").path))
    }

    func testImportStripsFrontmatterThatCouldWidenPermissions() throws {
        let src = try makeFolder("x", manifest: "---\nname: peligro\ndescription: d\nallowed-tools: Bash\nhooks:\n  PreToolUse: x\nmodel: opus\n---\nCuerpo intacto")
        let skill = try library.importFolder(src)
        let text = try library.manifestText(of: skill)
        XCTAssertFalse(text.contains("allowed-tools"))
        XCTAssertFalse(text.contains("hooks"))
        XCTAssertFalse(text.contains("model:"))
        XCTAssertTrue(text.contains("Cuerpo intacto"))
        XCTAssertEqual(try SkillManifest.parse(text).name, "peligro")
    }

    func testImportRejectsDuplicatesAndMissingManifest() throws {
        let src = try makeFolder("x", manifest: "---\nname: dup\ndescription: d\n---\n")
        _ = try library.importFolder(src)
        XCTAssertThrowsError(try library.importFolder(src)) { error in
            XCTAssertEqual((error as? ValidationError)?.message, "Ya existe un skill llamado dup.")
        }
        let empty = root.appendingPathComponent("src/empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        XCTAssertThrowsError(try library.importFolder(empty))
    }

    func testImportZipWithTopLevelFolder() throws {
        let src = try makeFolder("zipped", manifest: "---\nname: zipped\ndescription: d\n---\n")
        let zip = root.appendingPathComponent("s.zip")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--keepParent", src.path, zip.path]
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(try library.importZip(zip).name, "zipped")
    }

    func testAgentDraftsAreAssignedAndOnlyEditableByTheirAuthor() throws {
        let draft = try library.createDraft(agentId: agent.id, name: "estrategia-rsi", description: "Estrategia RSI",
                                            body: "Compra con RSI < 30", files: ["notas/backtest.md": "ok"])
        XCTAssertEqual(draft.status, .draft)
        XCTAssertEqual(draft.source, .agent)
        XCTAssertEqual(try library.skills(assignedTo: agent.id, activeOnly: false).map(\.id), [draft.id])
        XCTAssertTrue(try library.skills(assignedTo: agent.id, activeOnly: true).isEmpty, "un borrador no se carga")

        let other = try db.createAgent(workspaceId: ws.id, draft: AgentDraft(name: "B", instructions: "x"), status: .active)
        XCTAssertThrowsError(try library.updateDraft(agentId: other.id, name: "estrategia-rsi", description: nil, body: "x", files: nil))
        let updated = try library.updateDraft(agentId: agent.id, name: "estrategia-rsi", description: "RSI v2", body: "nuevo", files: nil)
        XCTAssertEqual(updated.description, "RSI v2")
        XCTAssertTrue(try library.manifestText(of: updated).contains("nuevo"))

        _ = try library.activate(id: draft.id)
        XCTAssertThrowsError(try library.updateDraft(agentId: agent.id, name: "estrategia-rsi", description: nil, body: "x", files: nil)) { error in
            XCTAssertEqual((error as? ValidationError)?.message, "estrategia-rsi ya está activo: solo el usuario puede cambiarlo.")
        }
        XCTAssertEqual(try library.skills(assignedTo: agent.id, activeOnly: true).count, 1)
    }

    func testDraftFilesCannotEscapeTheSkillFolder() {
        for bad in ["../fuera.md", "/etc/x", "a/../../b", "SKILL.md"] {
            XCTAssertThrowsError(try library.createDraft(agentId: agent.id, name: "n\(abs(bad.hashValue) % 1000)", description: "d", body: "b", files: [bad: "x"]), bad)
        }
    }

    func testAssignUnassignAndDelete() throws {
        let skill = try library.createUserSkill(name: "mio", description: "d", body: "b")
        try library.assign(skillId: skill.id, to: agent.id)
        try library.assign(skillId: skill.id, to: agent.id) // idempotente
        XCTAssertEqual(try library.skills(assignedTo: agent.id, activeOnly: true).count, 1)
        try library.unassign(skillId: skill.id, from: agent.id)
        XCTAssertTrue(try library.skills(assignedTo: agent.id, activeOnly: true).isEmpty)
        try library.assign(skillId: skill.id, to: agent.id)
        try library.delete(id: skill.id)
        XCTAssertTrue(try library.skills(assignedTo: agent.id, activeOnly: false).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.directory(for: skill).path))
    }

    func testCryptoTraderSeedSkillsAreInstalledOnceAndAssigned() throws {
        let trader = try db.createAgent(workspaceId: ws.id, draft: AgentTemplate.cryptoTrader.draft, status: .active)
        try library.installTemplateSkills(for: trader)
        try library.installTemplateSkills(for: trader)
        let names = try library.skills(assignedTo: trader.id, activeOnly: true).map(\.name).sorted()
        XCTAssertEqual(names, ["analisis-tecnico", "gestion-de-riesgo", "tradingview"])
    }

    func testSkillTools() throws {
        let handler = ToolHandler(db: db, files: BrandFiles(paths: AppPaths(root: root)), workspaceId: ws.id)
        let created = try handler.handle(method: "tool.skills_create_draft", params: [
            "agent_id": .string(agent.id), "name": "rsi", "description": "Estrategia RSI", "body": "texto",
        ])
        XCTAssertEqual(created["status"], "draft")
        let list = try handler.handle(method: "tool.skills_list", params: ["agent_id": .string(agent.id)])
        let first = try XCTUnwrap(list["skills"]?.arrayValue?.first)
        XCTAssertEqual(first["name"], "rsi")
        XCTAssertEqual(first["assigned"], true)
        XCTAssertEqual(first["status"], "draft")
    }
}
