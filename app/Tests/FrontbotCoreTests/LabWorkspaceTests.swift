import XCTest
@testable import FrontbotCore

final class LabWorkspaceTests: XCTestCase {
    var db: AppDatabase!
    var paths: AppPaths!
    var root: URL!
    var agent: Agent!

    override func setUpWithError() throws {
        db = try AppDatabase.inMemory()
        let ws = try db.ensureDefaultWorkspace()
        root = URL(fileURLWithPath: ScriptSandbox.realPath(FileManager.default.temporaryDirectory)).appendingPathComponent("lab-\(UUID().uuidString)")
        paths = AppPaths(root: root)
        agent = try db.createAgent(workspaceId: ws.id, draft: AgentDraft(name: "A", instructions: "x"), status: .active)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func workspace(max: Int = 200_000_000) -> LabWorkspace {
        LabWorkspace(paths: paths, db: db, agentId: agent.id, topicId: "t1", maxAgentBytes: max)
    }

    func testWriteAndReadInsideTopic() throws {
        let lab = workspace()
        try lab.write("notas/a.md", content: "hola")
        XCTAssertEqual(try lab.read("notas/a.md").text, "hola")
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.labTopicDir(agent.id, "t1").appendingPathComponent("notas/a.md").path))
        try lab.write("shared/m.txt", content: "común")
        XCTAssertEqual(try lab.read("shared/m.txt").text, "común")
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.labSharedDir(agent.id).appendingPathComponent("m.txt").path))
        XCTAssertTrue(try lab.list(nil).contains("notas/"))
        XCTAssertEqual(try lab.list("notas"), ["notas/a.md"])
    }

    func testRejectsDotDotAbsoluteAndBackslash() throws {
        let lab = workspace()
        for bad in ["../x", "/etc/passwd", "a\\b"] {
            XCTAssertThrowsError(try lab.write(bad, content: "x"), bad) { error in
                XCTAssertEqual((error as? ValidationError)?.message, "Ruta fuera de tu laboratorio: \(bad).")
            }
            XCTAssertThrowsError(try lab.read(bad), bad)
        }
        XCTAssertThrowsError(try lab.write("shared/../../x", content: "x"))
    }

    func testRejectsSymlinkEscaping() throws {
        let lab = workspace()
        let outside = root.appendingPathComponent("fuera")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "secreto".write(to: outside.appendingPathComponent("x"), atomically: true, encoding: .utf8)
        let topic = paths.labTopicDir(agent.id, "t1")
        try FileManager.default.createDirectory(at: topic, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: topic.appendingPathComponent("out"), withDestinationURL: outside)
        XCTAssertThrowsError(try lab.read("out/x"))
        XCTAssertThrowsError(try lab.write("out/y", content: "x"))
        XCTAssertThrowsError(try lab.write("out/x", content: "x"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("y").path))
        // Un enlace dentro del tema que apunta a shared/ tampoco vale: sale de su raíz.
        try FileManager.default.createDirectory(at: paths.labSharedDir(agent.id), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: topic.appendingPathComponent("sh"), withDestinationURL: paths.labSharedDir(agent.id))
        XCTAssertThrowsError(try lab.write("sh/y", content: "x"))
    }

    func testSkillPrefixOnlyForAssignedSkills() throws {
        let library = SkillLibrary(db: db, paths: paths)
        let mine = try library.createUserSkill(name: "mio", description: "d", body: "b", files: ["data/a.txt": "uno"])
        _ = try library.createUserSkill(name: "ajeno", description: "d", body: "b", files: ["data/a.txt": "dos"])
        try library.assign(skillId: mine.id, to: agent.id)
        let lab = workspace()
        XCTAssertEqual(try lab.read("skill:mio/data/a.txt").text, "uno")
        XCTAssertThrowsError(try lab.read("skill:ajeno/data/a.txt"))
        XCTAssertThrowsError(try lab.write("skill:mio/data/a.txt", content: "x"))
    }

    func testDatasetsAreReadOnly() throws {
        let dir = paths.datasetDir("d")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "a,b".write(to: dir.appendingPathComponent("a.csv"), atomically: true, encoding: .utf8)
        let lab = workspace()
        XCTAssertEqual(try lab.read("dataset:d/a.csv").text, "a,b")
        XCTAssertThrowsError(try lab.write("dataset:d/a.csv", content: "x"))
        XCTAssertThrowsError(try lab.read("dataset:../a.csv"))
    }

    func testReadIsCappedAt512KB() throws {
        let lab = workspace()
        try lab.write("grande.txt", content: String(repeating: "a", count: 600_000))
        let result = try lab.read("grande.txt")
        XCTAssertTrue(result.truncated)
        XCTAssertEqual(result.text.utf8.count, 512_000)
    }

    func testPerFileAndPerAgentLimits() throws {
        let lab = workspace(max: 1000)
        XCTAssertThrowsError(try workspace().write("x.txt", content: String(repeating: "a", count: 1_000_001)))
        try lab.write("a.txt", content: String(repeating: "a", count: 600))
        XCTAssertThrowsError(try lab.write("b.txt", content: String(repeating: "b", count: 500)))
        // Reescribir el mismo archivo no cuenta dos veces.
        try lab.write("a.txt", content: String(repeating: "c", count: 900))
        // El tope es por agente: shared/ también cuenta.
        XCTAssertThrowsError(try lab.write("shared/z.txt", content: String(repeating: "d", count: 200)))
    }
}
