import XCTest
import GRDB
@testable import FrontbotCore

final class LabStoreTests: XCTestCase {
    var db: AppDatabase!
    var agent: Agent!
    let limitMessage = "Ya tienes 3 temas abiertos: pausa o abandona uno antes de abrir otro."

    override func setUpWithError() throws {
        db = try AppDatabase.inMemory()
        let ws = try db.ensureDefaultWorkspace()
        agent = try db.createAgent(workspaceId: ws.id, draft: AgentDraft(name: "A", instructions: "x"), status: .active)
    }

    func open(_ q: String = "¿por qué pierde en laterales?") throws -> LabTopic {
        try db.openTopic(agentId: agent.id, question: q, why: "porque sí", origin: .user, now: .dbNow())
    }

    func testOpenTopicRespectsMaxOpen() throws {
        let first = try open("uno")
        _ = try open("dos")
        _ = try open("tres")
        XCTAssertEqual(first.nextSessionAfter, first.createdAt)
        XCTAssertThrowsError(try open("cuatro")) { XCTAssertEqual(($0 as? ValidationError)?.message, self.limitMessage) }
        _ = try db.setTopicStatus(id: first.id, .abandoned, reason: nil, now: .dbNow())
        XCTAssertNoThrow(try open("cuatro"))
    }

    func testReopeningAboveTheLimitFailsAndResumeResetsState() throws {
        let a = try open("uno"); _ = try open("dos"); _ = try open("tres")
        let paused = try db.setTopicStatus(id: a.id, .paused, reason: "fallos", now: .dbNow())
        XCTAssertEqual(paused.pausedReason, "fallos")
        try db.writer.write { try $0.execute(sql: "UPDATE labTopic SET consecutiveFailures = 2 WHERE id = ?", arguments: [a.id]) }
        let resumed = try db.setTopicStatus(id: a.id, .studying, reason: nil, now: .dbNow())
        XCTAssertEqual(resumed.consecutiveFailures, 0)
        XCTAssertNil(resumed.pausedReason)

        _ = try db.setTopicStatus(id: a.id, .abandoned, reason: nil, now: .dbNow())
        _ = try open("cuatro")
        XCTAssertThrowsError(try db.setTopicStatus(id: a.id, .studying, reason: nil, now: .dbNow())) {
            XCTAssertEqual(($0 as? ValidationError)?.message, self.limitMessage)
        }
        XCTAssertEqual(try db.topics(agentId: agent.id).last?.id, a.id, "los cerrados van al final")
    }

    func testPausingAClosedTopicAboveTheLimitFails() throws {
        let a = try open("uno"); _ = try open("dos"); _ = try open("tres")
        _ = try db.setTopicStatus(id: a.id, .abandoned, reason: nil, now: .dbNow())
        _ = try open("cuatro")
        XCTAssertThrowsError(try db.setTopicStatus(id: a.id, .paused, reason: "x", now: .dbNow())) {
            XCTAssertEqual(($0 as? ValidationError)?.message, self.limitMessage)
        }
        XCTAssertEqual(try db.topic(id: a.id)?.status, .abandoned)
    }

    func testQuestionLengthValidated() throws {
        XCTAssertThrowsError(try open(String(repeating: "a", count: 301)))
        XCTAssertNoThrow(try open(String(repeating: "a", count: 300)))
    }

    func testEntriesInOrderWithEvidence() throws {
        let t = try open()
        _ = try db.addEntry(topicId: t.id, sessionId: nil, kind: .hypothesis, text: "h", evidence: nil, sources: [], model: nil)
        let e = try db.addEntry(topicId: t.id, sessionId: nil, kind: .conclusion, text: "c", evidence: .medium, sources: ["https://x"], model: "sonnet")
        let all = try db.entries(topicId: t.id)
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all.last, e)
        XCTAssertEqual(all.last?.evidence, .medium)
        XCTAssertEqual(all.last?.sources, ["https://x"])
        XCTAssertEqual(all.first?.kind, .hypothesis)
    }

    func testFailRunningSessionsCutsWithoutFailure() throws {
        let t = try open()
        let s = try db.startLabSession(topicId: t.id, now: .dbNow())
        XCTAssertEqual(try db.runningLabSession()?.id, s.id)
        XCTAssertEqual(try db.failRunningLabSessions(), 1)
        let status = try db.writer.read { try LabSession.fetchOne($0, key: s.id)?.status }
        XCTAssertEqual(status, .cut)
        XCTAssertEqual(try db.topic(id: t.id)?.consecutiveFailures, 0)
        XCTAssertNil(try db.runningLabSession())
    }

    func testFinishSessionRecordsFieldsAndTopicTotals() throws {
        let t = try open()
        let s = try db.startLabSession(topicId: t.id, now: .dbNow())
        let topic = try db.finishLabSession(id: s.id, status: .done, outcome: .resolve, summary: "listo", conclusion: "C",
                                            tokens: 1234, models: [LabModelUsage(model: "sonnet", tokens: 1234)], now: .dbNow())
        XCTAssertEqual(topic.sessions, 1)
        XCTAssertEqual(topic.tokensUsed, 1234)
        XCTAssertEqual(topic.conclusion, "C")
        let saved = try db.writer.read { try LabSession.fetchOne($0, key: s.id) }
        XCTAssertEqual(saved?.status, .done)
        XCTAssertEqual(saved?.outcome, .resolve)
        XCTAssertEqual(saved?.models, [LabModelUsage(model: "sonnet", tokens: 1234)])
        XCTAssertNotNil(saved?.finishedAt)
    }

    func testTokensUsedByLocalDay() throws {
        let t = try open()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Madrid")!
        let today = cal.date(from: DateComponents(year: 2026, month: 10, day: 17))!
        let late = cal.date(bySettingHour: 23, minute: 50, second: 0, of: today)!
        let early = cal.date(byAdding: .minute, value: 20, to: cal.date(byAdding: .day, value: 1, to: today)!)!
        for (start, tokens) in [(late, 40000), (early, 10000)] {
            let s = try db.startLabSession(topicId: t.id, now: start)
            _ = try db.finishLabSession(id: s.id, status: .done, outcome: .continue, summary: nil, conclusion: nil, tokens: tokens, models: [], now: start)
        }
        let tomorrow = cal.date(byAdding: .day, value: 1, to: today)!
        XCTAssertEqual(try db.labTokensUsed(agentId: agent.id, day: today, calendar: cal), 40000)
        XCTAssertEqual(try db.labTokensUsed(agentId: agent.id, day: tomorrow, calendar: cal), 10000)
        XCTAssertEqual(try db.labTokensUsed(agentId: agent.id, from: today, to: tomorrow), 40000)
    }

    func testSettingsDefaultsAndSave() throws {
        var s = try db.labSettings(agentId: agent.id)
        XCTAssertEqual(s, AgentLabSettings.defaults(agentId: agent.id))
        XCTAssertEqual(s.sessionTokenCap, 150000); XCTAssertEqual(s.dailyTokenCap, 500000)
        XCTAssertEqual(s.maxOpenTopics, 3); XCTAssertTrue(s.enabled); XCTAssertFalse(s.allowOpus)
        s.maxOpenTopics = 1
        try db.saveLabSettings(s)
        XCTAssertEqual(try db.labSettings(agentId: agent.id).maxOpenTopics, 1)
        _ = try open("uno")
        XCTAssertThrowsError(try open("dos")) { XCTAssertEqual(($0 as? ValidationError)?.message, "Ya tienes 1 temas abiertos: pausa o abandona uno antes de abrir otro.") }
    }

    func testSkillVersionDefaultsToOne() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = SkillLibrary(db: db, paths: AppPaths(root: root))
        XCTAssertEqual(try library.createUserSkill(name: "mio", description: "d", body: "b").version, 1)
    }

    func testDeletingAgentCascades() throws {
        let t = try open()
        let s = try db.startLabSession(topicId: t.id, now: .dbNow())
        _ = try db.addEntry(topicId: t.id, sessionId: s.id, kind: .note, text: "n", evidence: nil, sources: [], model: nil)
        try db.deleteAgent(id: agent.id)
        try db.writer.read { d in
            XCTAssertEqual(try LabTopic.fetchCount(d), 0)
            XCTAssertEqual(try LabSession.fetchCount(d), 0)
            XCTAssertEqual(try LabEntry.fetchCount(d), 0)
        }
    }
}
