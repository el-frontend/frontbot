import XCTest
import GRDB
@testable import FrontbotCore

final class LabToolHandlerTests: XCTestCase {
    var db: AppDatabase!
    var agent: Agent!
    var other: Agent!
    var paths: AppPaths!
    var handler: LabToolHandler!
    let notStudy = "Esta herramienta solo funciona dentro de una sesión de estudio."

    override func setUpWithError() throws {
        db = try AppDatabase.inMemory()
        let ws = try db.ensureDefaultWorkspace()
        agent = try db.createAgent(workspaceId: ws.id, draft: AgentDraft(name: "A", instructions: "x"), status: .active)
        other = try db.createAgent(workspaceId: ws.id, draft: AgentDraft(name: "B", instructions: "x"), status: .active)
        paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        handler = LabToolHandler(db: db, paths: paths)
    }

    func call(_ method: String, _ params: [String: JSONValue]) throws -> JSONValue {
        try handler.handle(method: method, params: .object(params))
    }

    func study() throws -> (LabTopic, LabSession, [String: JSONValue]) {
        let t = try db.openTopic(agentId: agent.id, question: "q", why: "w", origin: .user, now: .dbNow())
        let s = try db.startLabSession(topicId: t.id, now: .dbNow())
        return (t, s, ["agent_id": .string(agent.id), "topic_id": .string(t.id), "session_id": .string(s.id)])
    }

    func testOpenTopicFromChatNeedsNoSession() throws {
        let r = try call("tool.lab_open_topic", ["agent_id": .string(agent.id), "question": "¿algo?", "why": "porque"])
        let id = try XCTUnwrap(r["topic_id"]?.stringValue)
        let topic = try XCTUnwrap(try db.topic(id: id))
        XCTAssertEqual(topic.origin, .agent)
        XCTAssertEqual(topic.agentId, agent.id)
        let list = try call("tool.lab_list_topics", ["agent_id": .string(agent.id)])
        XCTAssertEqual(list["topics"]?.arrayValue?.count, 1)
    }

    func testStudyToolsRequireRunningSession() throws {
        let t = try db.openTopic(agentId: agent.id, question: "q", why: "w", origin: .user, now: .dbNow())
        let base: [String: JSONValue] = ["agent_id": .string(agent.id), "topic_id": .string(t.id), "kind": "note", "text": "hola"]
        XCTAssertThrowsError(try call("tool.lab_note", base)) { XCTAssertEqual(($0 as? ValidationError)?.message, self.notStudy) }
        let s = try db.startLabSession(topicId: t.id, now: .dbNow())
        _ = try db.finishLabSession(id: s.id, status: .done, outcome: .continue, summary: nil, conclusion: nil, tokens: 1, models: [], now: .dbNow())
        var done = base; done["session_id"] = .string(s.id)
        XCTAssertThrowsError(try call("tool.lab_note", done)) { XCTAssertEqual(($0 as? ValidationError)?.message, self.notStudy) }
    }

    func testStudyToolRejectsSessionOfAnotherAgentOrTopic() throws {
        let (t, s, ids) = try study()
        var foreign = ids; foreign["agent_id"] = .string(other.id)
        foreign["kind"] = "note"; foreign["text"] = "x"
        XCTAssertThrowsError(try call("tool.lab_note", foreign)) { XCTAssertEqual(($0 as? ValidationError)?.message, self.notStudy) }
        let t2 = try db.openTopic(agentId: agent.id, question: "q2", why: "w", origin: .user, now: .dbNow())
        var wrongTopic = ids; wrongTopic["topic_id"] = .string(t2.id); wrongTopic["kind"] = "note"; wrongTopic["text"] = "x"
        XCTAssertThrowsError(try call("tool.lab_note", wrongTopic)) { XCTAssertEqual(($0 as? ValidationError)?.message, self.notStudy) }
        XCTAssertEqual(t.id, s.topicId)
    }

    func testNoteAndReadNotebook() throws {
        let (t, _, ids) = try study()
        var p = ids
        p["kind"] = "result"; p["text"] = "funciona"; p["evidence"] = "strong"; p["sources"] = ["https://a.com"]
        _ = try call("tool.lab_note", p)
        let r = try call("tool.lab_read_notebook", ["agent_id": .string(agent.id), "topic_id": .string(t.id)])
        let e = try XCTUnwrap(r["entries"]?.arrayValue?.first)
        XCTAssertEqual(e["kind"]?.stringValue, "result")
        XCTAssertEqual(e["text"]?.stringValue, "funciona")
        XCTAssertEqual(e["evidence"]?.stringValue, "strong")
        XCTAssertEqual(e["sources"]?.arrayValue?.compactMap(\.stringValue), ["https://a.com"])
        XCTAssertNotNil(e["date"]?.stringValue)
        var bad = ids; bad["kind"] = "nope"; bad["text"] = "x"
        XCTAssertThrowsError(try call("tool.lab_note", bad))
    }

    func testReadNotebookRejectsOtherAgentsTopic() throws {
        let t = try db.openTopic(agentId: other.id, question: "q", why: "w", origin: .user, now: .dbNow())
        XCTAssertThrowsError(try call("tool.lab_read_notebook", ["agent_id": .string(agent.id), "topic_id": .string(t.id)]))
        XCTAssertThrowsError(try call("tool.lab_resume_topic", ["agent_id": .string(agent.id), "topic_id": .string(t.id)]))
    }

    func testResumeTopic() throws {
        let t = try db.openTopic(agentId: agent.id, question: "q", why: "w", origin: .user, now: .dbNow())
        _ = try db.setTopicStatus(id: t.id, .paused, reason: "x", now: .dbNow())
        _ = try call("tool.lab_resume_topic", ["agent_id": .string(agent.id), "topic_id": .string(t.id)])
        XCTAssertEqual(try db.topic(id: t.id)?.status, .studying)
    }

    func testEndSessionResolveRequiresConclusion() throws {
        let (t, s, ids) = try study()
        var p = ids; p["outcome"] = "resolve"; p["summary"] = "fin"
        XCTAssertThrowsError(try call("tool.lab_end_session", p))
        p["conclusion"] = "Concluyo esto"
        _ = try call("tool.lab_end_session", p)
        let saved = try db.writer.read { try LabSession.fetchOne($0, key: s.id) }
        XCTAssertEqual(saved?.status, .running) // el cierre real llega con agent.done
        XCTAssertEqual(saved?.outcome, .resolve)
        XCTAssertEqual(saved?.summary, "fin")
        XCTAssertEqual(try db.topic(id: t.id)?.conclusion, "Concluyo esto")
        XCTAssertEqual(try db.topic(id: t.id)?.status, .studying)
    }

    func testProposeSkillMarksTopicResolved() throws {
        let (t, _, ids) = try study()
        var p = ids
        p["kind"] = "new"; p["skill_name"] = "reglas-laterales"; p["description"] = "Cuándo evitar laterales"
        p["body"] = "# Reglas\n\nNo operar en laterales."; p["evidence_summary"] = "30 pruebas"
        let r = try call("tool.lab_propose_skill", p)
        XCTAssertNotNil(r["proposal_id"]?.stringValue)
        XCTAssertEqual(try db.topic(id: t.id)?.status, .resolved)
        XCTAssertEqual(SkillVersions(library: SkillLibrary(db: db, paths: paths)).pendingProposals(agentId: agent.id).count, 1)
    }

    func testWriteFileUsesTopicWorkspace() throws {
        let (t, _, ids) = try study()
        var w = ids; w["path"] = "notas.md"; w["content"] = "hola"
        _ = try call("tool.lab_write_file", w)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.labTopicDir(agent.id, t.id).appendingPathComponent("notas.md").path))
        var r = ids; r["path"] = "notas.md"
        XCTAssertEqual(try call("tool.lab_read_file", r)["content"]?.stringValue, "hola")
        let l = try call("tool.lab_list_files", ids)
        XCTAssertTrue(l["files"]?.arrayValue?.compactMap(\.stringValue).contains("notas.md") == true)
        var esc = ids; esc["path"] = "../x.md"; esc["content"] = "no"
        XCTAssertThrowsError(try call("tool.lab_write_file", esc))
    }

    func testListDatasetsEmpty() throws {
        let r = try call("tool.lab_list_datasets", ["agent_id": .string(agent.id)])
        XCTAssertEqual(r["datasets"]?.arrayValue?.count, 0)
    }

    func testStudyPromptPayloadTrimsAndCapsOld() throws {
        let t = try db.openTopic(agentId: agent.id, question: "Q", why: "W", origin: .user, now: .dbNow())
        var entries: [LabEntry] = []
        for i in 0..<35 {
            let kind: LabEntryKind = i == 0 ? .conclusion : (i == 1 ? .hypothesis : .note)
            entries.append(LabEntry(id: Int64(i), topicId: t.id, sessionId: nil, kind: kind,
                                    text: i == 0 ? String(repeating: "a", count: 500) : "e\(i)", evidence: nil, sources: [], model: nil, createdAt: .dbNow()))
        }
        let notes = [LabEntry(id: 99, topicId: t.id, sessionId: nil, kind: .model_note, text: "nota", evidence: nil, sources: [], model: nil, createdAt: .dbNow())]
        let p = StudyPrompt.payload(topic: t, entries: entries, modelNotes: notes, datasets: [], files: ["a.py"])
        XCTAssertEqual(p["entries"]?.arrayValue?.count, 30)
        let earlier = try XCTUnwrap(p["earlier"]?.arrayValue)
        XCTAssertEqual(earlier.count, 1) // solo conclusion/result de las 5 anteriores
        XCTAssertEqual(earlier[0]["text"]?.stringValue?.count, 300)
        XCTAssertEqual(p["model_notes"]?.arrayValue?.count, 1)
        XCTAssertEqual(p["files"]?.arrayValue?.compactMap(\.stringValue), ["a.py"])
    }

    func testAsyncToolsRequireRunningSession() async throws {
        let t = try db.openTopic(agentId: agent.id, question: "q", why: "w", origin: .user, now: .dbNow())
        let params: JSONValue = ["agent_id": .string(agent.id), "topic_id": .string(t.id), "session_id": "nope", "script": "a.py"]
        do { _ = try await handler.handleAsync(method: "tool.lab_run", params: params); XCTFail("debió fallar") }
        catch { XCTAssertEqual((error as? ValidationError)?.message, notStudy) }
    }
}
