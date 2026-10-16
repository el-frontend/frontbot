import XCTest
@testable import FrontbotCore

final class ScheduledTaskTests: XCTestCase {
    var db: AppDatabase!
    var agent: Agent!
    var handler: ToolHandler!
    let now = Date(timeIntervalSince1970: 1_792_000_000)

    override func setUpWithError() throws {
        db = try AppDatabase.inMemory()
        let ws = try db.ensureDefaultWorkspace()
        agent = try db.createAgent(workspaceId: ws.id, draft: AgentTemplate.cryptoTrader.draft, status: .active)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        handler = ToolHandler(db: db, files: BrandFiles(paths: AppPaths(root: root)), workspaceId: ws.id)
    }

    func draft(_ schedule: Schedule = .interval(minutes: 60)) -> TaskDraft {
        TaskDraft(name: "Revisión", instruction: "Revisa BTC", schedule: schedule)
    }

    func testUserTasksStartActiveWithTheirNextRun() throws {
        let task = try db.createTask(agentId: agent.id, draft: draft(), status: .active, createdBy: nil, now: now)
        XCTAssertEqual(task.status, .active)
        XCTAssertEqual(task.nextRunAt, now.addingTimeInterval(3_600))
        XCTAssertEqual(task.model, agent.model)
    }

    func testValidation() {
        XCTAssertThrowsError(try db.createTask(agentId: agent.id, draft: TaskDraft(name: " ", instruction: "x", schedule: .daily(TimeOfDay(9, 0))), status: .active, createdBy: nil, now: now))
        XCTAssertThrowsError(try db.createTask(agentId: agent.id, draft: TaskDraft(name: "a", instruction: "", schedule: .daily(TimeOfDay(9, 0))), status: .active, createdBy: nil, now: now))
        XCTAssertThrowsError(try db.createTask(agentId: agent.id, draft: draft(.interval(minutes: 1)), status: .active, createdBy: nil, now: now))
    }

    func testDraftsOnlyGetANextRunWhenTheUserActivatesThem() throws {
        let task = try db.createTask(agentId: agent.id, draft: draft(), status: .draft, createdBy: agent.id, now: now)
        XCTAssertNil(task.nextRunAt)
        XCTAssertTrue(try db.dueTasks(now: now.addingTimeInterval(86_400)).isEmpty)
        let active = try db.setTaskStatus(id: task.id, .active, now: now)
        XCTAssertEqual(active.nextRunAt, now.addingTimeInterval(3_600))
    }

    func testDueTasksAndCatchUpRunsOnlyOnce() throws {
        let task = try db.createTask(agentId: agent.id, draft: draft(), status: .active, createdBy: nil, now: now)
        XCTAssertTrue(try db.dueTasks(now: now).isEmpty)
        let later = now.addingTimeInterval(10 * 3_600) // el Mac estuvo dormido 10 h
        XCTAssertEqual(try db.dueTasks(now: later).map(\.id), [task.id])
        let run = try db.startTaskRun(taskId: task.id, now: later)
        XCTAssertEqual(run.status, .running)
        XCTAssertTrue(try db.dueTasks(now: later).isEmpty, "ya corre, y la próxima es en una hora")
        XCTAssertEqual(try db.task(id: task.id)?.nextRunAt, later.addingTimeInterval(3_600))
        XCTAssertTrue(try db.dueTasks(now: later.addingTimeInterval(3_700)).isEmpty, "una a la vez")
        try db.finishTaskRun(id: run.id, status: .done, summary: "ok", notified: false, conversationId: nil, costUsd: 0.01, now: later)
        XCTAssertEqual(try db.dueTasks(now: later.addingTimeInterval(3_700)).map(\.id), [task.id])
    }

    func testDailyLimitAndInactiveAgentsSkipTasks() throws {
        var d = draft(.interval(minutes: 15))
        d.maxRunsPerDay = 1
        let task = try db.createTask(agentId: agent.id, draft: d, status: .active, createdBy: nil, now: now)
        let run = try db.startTaskRun(taskId: task.id, now: now.addingTimeInterval(900))
        try db.finishTaskRun(id: run.id, status: .done, summary: nil, notified: false, conversationId: nil, costUsd: 0, now: now.addingTimeInterval(960))
        XCTAssertTrue(try db.dueTasks(now: now.addingTimeInterval(2_000)).isEmpty, "llegó al límite del día")

        let other = try db.createTask(agentId: agent.id, draft: draft(), status: .active, createdBy: nil, now: now)
        _ = try db.setTaskStatus(id: other.id, .paused, now: now)
        XCTAssertFalse(try db.dueTasks(now: now.addingTimeInterval(86_400 * 2)).contains { $0.id == other.id })
    }

    func testSkippingMovesTheNextRunWithoutRunning() throws {
        let task = try db.createTask(agentId: agent.id, draft: draft(), status: .active, createdBy: nil, now: now)
        let later = now.addingTimeInterval(5 * 3_600)
        try db.skipTask(id: task.id, now: later)
        XCTAssertEqual(try db.task(id: task.id)?.nextRunAt, later.addingTimeInterval(3_600))
        XCTAssertTrue(try db.taskRuns(taskId: task.id).isEmpty)
    }

    func testHasRunningRun() throws {
        let task = try db.createTask(agentId: agent.id, draft: draft(), status: .active, createdBy: nil, now: now)
        XCTAssertFalse(try db.hasRunningRun(taskId: task.id))
        _ = try db.startTaskRun(taskId: task.id, now: now)
        XCTAssertTrue(try db.hasRunningRun(taskId: task.id))
    }

    func testInterruptedRunsAreClosedOnLaunch() throws {
        let task = try db.createTask(agentId: agent.id, draft: draft(), status: .active, createdBy: nil, now: now)
        let run = try db.startTaskRun(taskId: task.id, now: now)
        XCTAssertEqual(try db.failRunningTaskRuns(), 1)
        XCTAssertEqual(try db.taskRuns(taskId: task.id).first { $0.id == run.id }?.status, .failed)
    }

    func testScheduleTools() throws {
        let created = try handler.handle(method: "tool.schedule_create_draft", params: [
            "agent_id": .string(agent.id), "name": "Mercado 4h", "instruction": "Revisa BTC y ETH",
            "schedule": ["kind": "interval", "every_minutes": 240],
        ])
        XCTAssertEqual(created["status"], "draft")
        let list = try handler.handle(method: "tool.schedule_list", params: ["agent_id": .string(agent.id)])
        XCTAssertEqual(list["tasks"]?.arrayValue?.first?["schedule"], "cada 4 h")
        let id = try XCTUnwrap(created["task_id"]?.stringValue)
        _ = try handler.handle(method: "tool.schedule_update_draft", params: [
            "agent_id": .string(agent.id), "task_id": .string(id), "schedule": ["kind": "daily", "time": "09:00"],
        ])
        XCTAssertEqual(try db.task(id: id)?.schedule, .daily(TimeOfDay(9, 0)))

        _ = try db.setTaskStatus(id: id, .active, now: now)
        XCTAssertThrowsError(try handler.handle(method: "tool.schedule_update_draft", params: ["agent_id": .string(agent.id), "task_id": .string(id), "name": "x"])) { error in
            XCTAssertEqual((error as? ValidationError)?.message, "Esa tarea ya está activa: solo el usuario puede cambiarla.")
        }
    }

    func testCryptoTraderTemplateSuggestsADraftTask() throws {
        let tasks = try db.installTemplateTasks(for: agent, now: now)
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks.first?.status, .draft)
        XCTAssertEqual(tasks.first?.schedule, .interval(minutes: 240))
        XCTAssertTrue(try db.installTemplateTasks(for: agent, now: now).isEmpty, "no se duplica")
    }
}

final class ScheduledRunTests: XCTestCase {
    func testScheduledRunCanNotifyAndFinishes() async throws {
        let db = try AppDatabase.inMemory()
        let ws = try db.ensureDefaultWorkspace()
        let node = ProcessInfo.processInfo.environment["FRONTBOT_NODE"] ?? "/opt/homebrew/bin/node"
        let script = AgentClientTests.repoRoot.appendingPathComponent("agent/dist/main.js").path
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: node), "usa FRONTBOT_NODE=$(which node)")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let client = AgentClient(config: AgentConfig(nodePath: node, scriptPath: script, apiKey: nil, model: "m", fakeAgent: true),
                                 db: db, files: BrandFiles(paths: AppPaths(root: root)), workspaceId: ws.id)
        let agent = try db.ensureDefaultAgent(workspaceId: ws.id)
        let task = try db.createTask(agentId: agent.id, draft: TaskDraft(name: "Prueba", instruction: "revisa y avisar", schedule: .daily(TimeOfDay(9, 0))),
                                     status: .active, createdBy: nil)
        let stream = await client.updates()
        let run = try await client.run(prompt: task.instruction, agent: agent, brand: nil, model: task.model, task: task)
        var notified: (String, String)?
        var finished: AgentRun?
        for await update in stream {
            if case .notify(let id, let title, let message) = update, id == run.id { notified = (title, message) }
            if case .finished(let r) = update, r.id == run.id { finished = r; break }
        }
        XCTAssertEqual(notified?.0, "Aviso de prueba")
        XCTAssertEqual(notified?.1, "revisa y avisar")
        XCTAssertEqual(finished?.resultSummary, "Tarea hecha: Prueba")
        await client.stop()
    }
}

final class ScheduledRunLogTests: XCTestCase {
    var db: AppDatabase!
    var ws: Workspace!
    var agent: Agent!
    var task: ScheduledTask!

    override func setUpWithError() throws {
        db = try AppDatabase.inMemory()
        ws = try db.ensureDefaultWorkspace()
        agent = try db.ensureDefaultAgent(workspaceId: ws.id)
        task = try db.createTask(agentId: agent.id, draft: TaskDraft(name: "Mercado", instruction: "Revisa", schedule: .daily(TimeOfDay(9, 0))),
                                 status: .active, createdBy: nil)
    }

    func agentRun(_ status: RunStatus, _ summary: String) -> AgentRun {
        AgentRun(id: "r", workspaceId: ws.id, brandId: nil, prompt: "p", status: status, resultSummary: summary,
                 inputTokens: 0, outputTokens: 0, costUsd: 0.02, logPath: nil, createdAt: Date())
    }

    func testQuietRunsOnlyLeaveHistory() throws {
        let tr = try db.startTaskRun(taskId: task.id)
        var log = ScheduledRunLog(taskRunId: tr.id, task: task, startedAt: tr.startedAt)
        log.record(.agent, "Nada relevante")
        let result = try db.completeScheduledRun(log, run: agentRun(.done, "Sin setups"), workspaceId: ws.id, proposalsCreated: 0)
        XCTAssertNil(result.conversationId)
        let saved = try XCTUnwrap(try db.taskRuns(taskId: task.id).first)
        XCTAssertEqual(saved.status, .done)
        XCTAssertEqual(saved.summary, "Sin setups")
        XCTAssertFalse(saved.notified)
        XCTAssertEqual(saved.costUsd, 0.02)
    }

    func testNotifiedRunsBecomeConversations() throws {
        let tr = try db.startTaskRun(taskId: task.id)
        var log = ScheduledRunLog(taskRunId: tr.id, task: task, startedAt: tr.startedAt)
        log.record(.tool, "→ market_price")
        log.record(.agent, "Hay setup en BTC")
        log.notification = ("Setup en BTC", "Long en 60k")
        let result = try db.completeScheduledRun(log, run: agentRun(.done, "Propuse avisar"), workspaceId: ws.id, proposalsCreated: 0)
        let conversationId = try XCTUnwrap(result.conversationId)
        XCTAssertTrue(result.surfaced)
        let conversation = try XCTUnwrap(try db.conversations(workspaceId: ws.id, limit: 5).first { $0.id == conversationId })
        XCTAssertEqual(conversation.title, "🕒 Mercado")
        XCTAssertEqual(conversation.agentId, agent.id)
        XCTAssertEqual(try db.messages(conversationId: conversationId).map(\.role), [.user, .tool, .agent])
        XCTAssertTrue(try db.taskRuns(taskId: task.id).first?.notified == true)
    }

    func testTradeProposalsAlsoSurfaceTheRun() throws {
        let tr = try db.startTaskRun(taskId: task.id)
        let log = ScheduledRunLog(taskRunId: tr.id, task: task, startedAt: tr.startedAt)
        XCTAssertNotNil(try db.completeScheduledRun(log, run: agentRun(.done, "ok"), workspaceId: ws.id, proposalsCreated: 1).conversationId)
    }

    func testFailuresAreRecorded() throws {
        let tr = try db.startTaskRun(taskId: task.id)
        let log = ScheduledRunLog(taskRunId: tr.id, task: task, startedAt: tr.startedAt)
        _ = try db.completeScheduledRun(log, run: agentRun(.failed, "rate limit"), workspaceId: ws.id, proposalsCreated: 0)
        XCTAssertEqual(try db.taskRuns(taskId: task.id).first?.status, .failed)
        XCTAssertEqual(try db.taskRuns(taskId: task.id).first?.summary, "rate limit")
    }
}

