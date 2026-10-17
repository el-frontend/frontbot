import XCTest
@testable import FrontbotCore

final class LabSandboxTests: XCTestCase {
    var db: AppDatabase!
    var paths: AppPaths!
    var root: URL!
    var agent: Agent!
    var other: Agent!

    override func setUpWithError() throws {
        db = try AppDatabase.inMemory()
        let ws = try db.ensureDefaultWorkspace()
        // Dentro de la carpeta personal, como los datos reales: así la sandbox la veta salvo lo que se le concede.
        root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".frontbot-labtest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        paths = AppPaths(root: root)
        agent = try db.createAgent(workspaceId: ws.id, draft: AgentDraft(name: "A", instructions: "x"), status: .active)
        other = try db.createAgent(workspaceId: ws.id, draft: AgentDraft(name: "B", instructions: "x"), status: .active)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func sandbox() -> LabSandbox { LabSandbox(paths: paths, db: db) }
    func workspace() -> LabWorkspace { LabWorkspace(paths: paths, db: db, agentId: agent.id, topicId: "t1") }
    func run(_ script: String, args: [String] = []) throws -> ScriptSandbox.Result {
        try sandbox().run(agentId: agent.id, topicId: "t1", script: script, args: args)
    }

    func testScriptReadsDatasetAndWritesTopic() throws {
        let dir = paths.datasetDir("d")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "1,2,3".write(to: dir.appendingPathComponent("a.csv"), atomically: true, encoding: .utf8)
        try workspace().write("lee.py", content: """
        data = open("../../../../datasets/d/a.csv").read()
        open("out.txt", "w").write(data + "!")
        print("ok")
        """)
        let result = try run("lee.py")
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(try workspace().read("out.txt").text, "1,2,3!")
    }

    func testCanWriteSharedAndReadAssignedSkillScript() throws {
        let library = SkillLibrary(db: db, paths: paths)
        let skill = try library.createUserSkill(name: "calc", description: "d", body: "b", files: ["scripts/hola.py": "print('desde skill')"])
        try library.assign(skillId: skill.id, to: agent.id)
        let result = try run("skill:calc/scripts/hola.py")
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "desde skill", result.stderr)
        try workspace().write("s.py", content: "open('../../shared/s.txt', 'w').write('x')")
        XCTAssertEqual(try run("s.py").exitCode, 0)
        XCTAssertEqual(try workspace().read("shared/s.txt").text, "x")
    }

    func testCannotWriteOutsideTopicOrShared() throws {
        let dir = paths.datasetDir("d")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try workspace().write("mal.py", content: "open('../../../../datasets/d/nuevo.txt', 'w').write('x')")
        XCTAssertNotEqual(try run("mal.py").exitCode, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("nuevo.txt").path))
        try workspace().write("mal2.py", content: "open('../../raiz.txt', 'w').write('x')")
        XCTAssertNotEqual(try run("mal2.py").exitCode, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.labDir(agent.id).appendingPathComponent("raiz.txt").path))
    }

    func testNoNetwork() throws {
        try workspace().write("red.py", content: """
        import socket
        s = socket.socket(); s.settimeout(3)
        try:
            s.connect(("1.1.1.1", 80)); print("PERMITIDO")
        except Exception:
            print("bloqueado")
        """)
        let result = try run("red.py")
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "bloqueado", result.stderr)
    }

    func testCannotReadOtherAgentsLabOrHome() throws {
        let theirs = paths.labTopicDir(other.id, "t9")
        try FileManager.default.createDirectory(at: theirs, withIntermediateDirectories: true)
        try "secreto".write(to: theirs.appendingPathComponent("s.txt"), atomically: true, encoding: .utf8)
        try workspace().write("espia.py", content: """
        import sys
        try:
            print(open(sys.argv[1]).read())
        except Exception:
            print("bloqueado")
        """)
        let result = try run("espia.py", args: [theirs.appendingPathComponent("s.txt").path])
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "bloqueado", result.stderr)
        let home = try run("espia.py", args: [NSHomeDirectory() + "/.zshrc"])
        XCTAssertEqual(home.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "bloqueado", home.stderr)
    }

    func testRejectsScriptsOutsideTheLab() throws {
        XCTAssertThrowsError(try run("../../x.py"))
        XCTAssertThrowsError(try run("/usr/bin/true"))
        XCTAssertThrowsError(try run("no-existe.py"))
        XCTAssertThrowsError(try run("dataset:d/a.py"))
    }
}
