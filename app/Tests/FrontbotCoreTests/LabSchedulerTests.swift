import XCTest
@testable import FrontbotCore

final class LabSchedulerTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func topic(_ id: String, agent: String = "a", created: TimeInterval = 0, status: LabTopicStatus = .studying,
               after: Date? = nil) -> LabTopic {
        LabTopic(id: id, agentId: agent, question: "q", why: "", origin: .user, status: status, conclusion: nil, sessions: 0,
                 tokensUsed: 0, nextSessionAfter: after ?? now.addingTimeInterval(-10), consecutiveFailures: 0, pausedReason: nil,
                 createdAt: now.addingTimeInterval(created), updatedAt: now)
    }

    func agent(_ id: String = "a", status: AgentStatus = .active) -> Agent {
        Agent(id: id, workspaceId: "w", name: "A", icon: "star", description: "", instructions: "", model: "sonnet",
              browser: false, trading: false, status: status, isDefault: false, templateId: nil, createdAt: now, updatedAt: now)
    }

    func cand(_ t: LabTopic, agent a: Agent? = nil, enabled: Bool = true, used: Int = 0) -> LabCandidate {
        var s = AgentLabSettings.defaults(agentId: t.agentId)
        s.enabled = enabled
        return LabCandidate(topic: t, agent: a ?? agent(t.agentId), settings: s, usedToday: used)
    }

    func next(_ c: [LabCandidate], running: Bool = false, chat: Set<String> = []) -> LabCandidate? {
        LabScheduler.next(candidates: c, sessionRunning: running, agentsInChat: chat, now: now)
    }

    func testPicksOldestStudyingWithBudget() {
        let newer = cand(topic("new", created: -10)), older = cand(topic("old", created: -100))
        XCTAssertEqual(next([newer, older])?.topic.id, "old")
        XCTAssertEqual(next([cand(topic("old", created: -100), used: 490_000), newer])?.topic.id, "new")
        XCTAssertNil(next([cand(topic("p", status: .paused))]))
        XCTAssertNil(next([cand(topic("later", after: now.addingTimeInterval(5)))]))
    }

    func testSkipsWhenSessionRunning() {
        XCTAssertNil(next([cand(topic("t"))], running: true))
    }

    func testSkipsAgentInChatOrInactiveOrDisabled() {
        XCTAssertNil(next([cand(topic("t"))], chat: ["a"]))
        XCTAssertNil(next([cand(topic("t"), agent: agent(status: .draft))]))
        XCTAssertNil(next([cand(topic("t"), enabled: false)]))
    }

    func testBudgetIsMinOfSessionAndDailyRemaining() {
        let d = AgentLabSettings.defaults(agentId: "a")
        XCTAssertEqual(LabScheduler.budget(settings: d, usedToday: 0), 150_000)
        XCTAssertEqual(LabScheduler.budget(settings: d, usedToday: 400_000), 100_000)
        XCTAssertNil(LabScheduler.budget(settings: d, usedToday: 485_000))
    }

    func testContinueWaitsTwentyMinutes() {
        var t = topic("t")
        LabScheduler.apply(finished: .done, outcome: .continue, to: &t, now: now)
        XCTAssertEqual(t.nextSessionAfter, now.addingTimeInterval(1200))
        XCTAssertEqual(t.status, .studying)
    }

    func testOutcomesChangeStatus() {
        for (o, s) in [(LabOutcome.pause, LabTopicStatus.paused), (.resolve, .resolved), (.abandon, .abandoned)] {
            var t = topic("t")
            LabScheduler.apply(finished: .done, outcome: o, to: &t, now: now)
            XCTAssertEqual(t.status, s)
        }
    }

    func testFailureBackoffAndAutoPause() {
        var t = topic("t")
        LabScheduler.apply(finished: .failed, outcome: nil, to: &t, now: now)
        XCTAssertEqual(t.nextSessionAfter, now.addingTimeInterval(1200))
        LabScheduler.apply(finished: .failed, outcome: nil, to: &t, now: now)
        XCTAssertEqual(t.nextSessionAfter, now.addingTimeInterval(3600))
        XCTAssertEqual(t.status, .studying)
        LabScheduler.apply(finished: .failed, outcome: nil, to: &t, now: now)
        XCTAssertEqual(t.status, .paused)
        XCTAssertEqual(t.pausedReason, "Falló 3 veces seguidas")
        XCTAssertEqual(t.consecutiveFailures, 3)
    }

    func testDoneResetsFailures() {
        var t = topic("t")
        LabScheduler.apply(finished: .failed, outcome: nil, to: &t, now: now)
        LabScheduler.apply(finished: .done, outcome: .continue, to: &t, now: now)
        XCTAssertEqual(t.consecutiveFailures, 0)
    }

    func testCutDoesNotCountAsFailure() {
        var t = topic("t")
        t.consecutiveFailures = 1
        LabScheduler.apply(finished: .cut, outcome: nil, to: &t, now: now)
        XCTAssertEqual(t.consecutiveFailures, 1)
        XCTAssertEqual(t.nextSessionAfter, now.addingTimeInterval(1200))
        XCTAssertEqual(t.status, .studying)
    }
}
