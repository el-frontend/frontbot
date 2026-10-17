import XCTest
@testable import FrontbotCore

final class AgentFilesTests: XCTestCase {
    var base: URL!
    var folder: URL!
    var appData: URL!
    var files: AgentFiles!

    override func setUpWithError() throws {
        base = URL(fileURLWithPath: ScriptSandbox.realPath(FileManager.default.temporaryDirectory))
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        folder = base.appendingPathComponent("marcas", isDirectory: true)
        appData = base.appendingPathComponent("Frontbot", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: appData, withIntermediateDirectories: true)
        files = AgentFiles(folders: [folder.path], protected: [appData])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    func testReadsAndListsInsideTheFolder() throws {
        try "hola ☕️".write(to: folder.appendingPathComponent("nota.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("fotos"), withIntermediateDirectories: true)
        XCTAssertEqual(try files.read(folder.appendingPathComponent("nota.md").path).text, "hola ☕️")
        let entries = try files.list(folder.path).entries
        XCTAssertEqual(entries.map(\.name), ["fotos", "nota.md"])
        XCTAssertEqual(entries.map(\.kind), [.directory, .file])
    }

    func testRejectsPathsOutsideTheFolders() throws {
        try "secreto".write(to: base.appendingPathComponent("fuera.txt"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try files.read(base.appendingPathComponent("fuera.txt").path))
        XCTAssertThrowsError(try files.read(folder.path + "/../fuera.txt"), "`..` no sale de la carpeta")
        XCTAssertThrowsError(try files.list("/etc"))
        XCTAssertThrowsError(try files.read("nota.md"), "las rutas relativas no valen")
    }

    func testSymlinksCannotEscapeTheFolder() throws {
        try "secreto".write(to: base.appendingPathComponent("fuera.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("atajo"), withDestinationURL: base)
        XCTAssertThrowsError(try files.read(folder.appendingPathComponent("atajo/fuera.txt").path))
        XCTAssertThrowsError(try files.prepareWrite(folder.appendingPathComponent("atajo/nuevo.txt").path, content: "x"))
    }

    func testDanglingSymlinkCannotBeWrittenThrough() throws {
        let outside = base.appendingPathComponent("aun-no-existe.txt")
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("roto.txt"), withDestinationURL: outside)
        XCTAssertThrowsError(try files.prepareWrite(folder.appendingPathComponent("roto.txt").path, content: "x"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path))
    }

    func testFoldersToAuthorizeAreValidated() throws {
        XCTAssertEqual(try AgentFiles.validatedFolder(folder.path, protected: [appData]), folder.path)
        XCTAssertThrowsError(try AgentFiles.validatedFolder(appData.appendingPathComponent("skills").path, protected: [appData]))
        XCTAssertThrowsError(try AgentFiles.validatedFolder(base.appendingPathComponent("nada").path, protected: [appData]))
        try "x".write(to: folder.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try AgentFiles.validatedFolder(folder.appendingPathComponent("a.txt").path, protected: [appData]))
    }

    func testFolderPrefixIsNotEnough() throws {
        let sibling = base.appendingPathComponent("marcas-privadas", isDirectory: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        try "x".write(to: sibling.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try files.read(sibling.appendingPathComponent("a.txt").path))
    }

    func testAppDataIsAlwaysOffLimits() throws {
        let wide = AgentFiles(folders: [base.path], protected: [appData])
        try "db".write(to: appData.appendingPathComponent("frontbot.sqlite"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try wide.read(appData.appendingPathComponent("frontbot.sqlite").path))
        XCTAssertThrowsError(try wide.prepareWrite(appData.appendingPathComponent("x.md").path, content: "x"))
        XCTAssertFalse(try wide.list(base.path).entries.contains { $0.name == "Frontbot" }, "ni siquiera aparece al listar")
    }

    func testAppDataCannotBeReachedWithDifferentCase() throws {
        // APFS no distingue mayúsculas: "FRONTBOT" es la misma carpeta que "Frontbot".
        let wide = AgentFiles(folders: [base.path], protected: [appData])
        try "db".write(to: appData.appendingPathComponent("frontbot.sqlite"), atomically: true, encoding: .utf8)
        let shouted = base.appendingPathComponent("FRONTBOT")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: shouted.path), "el volumen distingue mayúsculas")
        XCTAssertThrowsError(try wide.read(shouted.appendingPathComponent("frontbot.sqlite").path))
        XCTAssertThrowsError(try wide.prepareWrite(shouted.appendingPathComponent("nuevo.md").path, content: "x"))
        XCTAssertThrowsError(try wide.list(shouted.path))
        XCTAssertThrowsError(try AgentFiles.validatedFolder(shouted.appendingPathComponent("skills").path, protected: [appData]))
    }

    func testAuthorizedFolderMatchesRegardlessOfCase() throws {
        try "hola".write(to: folder.appendingPathComponent("nota.md"), atomically: true, encoding: .utf8)
        let upper = base.appendingPathComponent("MARCAS/nota.md")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: upper.path), "el volumen distingue mayúsculas")
        XCTAssertEqual(try files.read(upper.path).text, "hola")
    }

    func testWriteIsPreparedThenCommitted() throws {
        let target = folder.appendingPathComponent("borradores/post.md")
        let write = try files.prepareWrite(target.path, content: "# Post")
        XCTAssertFalse(write.replaces)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path), "preparar no escribe nada")
        try files.commit(write)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "# Post")

        let again = try files.prepareWrite(target.path, content: "# Post v2")
        XCTAssertTrue(again.replaces)
        XCTAssertEqual(again.previousSize, 6)
    }

    func testRefusesBinaryAndHugeFiles() throws {
        try Data([0x50, 0x00, 0x4B]).write(to: folder.appendingPathComponent("foto.png"))
        XCTAssertThrowsError(try files.read(folder.appendingPathComponent("foto.png").path))
        XCTAssertThrowsError(try files.prepareWrite(folder.appendingPathComponent("big.txt").path,
                                                    content: String(repeating: "x", count: AgentFiles.maxWriteBytes + 1)))
        XCTAssertThrowsError(try files.prepareWrite(folder.path, content: "x"), "no se escribe encima de una carpeta")
    }

    func testLongFilesAreTruncated() throws {
        try String(repeating: "a", count: AgentFiles.maxReadBytes + 10).write(to: folder.appendingPathComponent("largo.txt"), atomically: true, encoding: .utf8)
        let result = try files.read(folder.appendingPathComponent("largo.txt").path)
        XCTAssertTrue(result.truncated)
        XCTAssertEqual(result.text.utf8.count, AgentFiles.maxReadBytes)
    }

    func testTildeIsExpanded() throws {
        let home = AgentFiles(folders: [NSHomeDirectory()], protected: [])
        XCTAssertEqual(try home.resolve("~").path, ScriptSandbox.realPath(URL(fileURLWithPath: NSHomeDirectory())))
    }
}
