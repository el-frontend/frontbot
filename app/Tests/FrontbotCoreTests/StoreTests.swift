import XCTest
@testable import FrontbotCore

final class StoreTests: XCTestCase {
    var db: AppDatabase!
    var ws: Workspace!

    override func setUpWithError() throws {
        db = try AppDatabase.inMemory()
        ws = try db.ensureDefaultWorkspace()
    }

    func testEnsureDefaultWorkspaceIsIdempotent() throws {
        let again = try db.ensureDefaultWorkspace()
        XCTAssertEqual(again.id, ws.id)
    }

    func testCreateAndListBrands() throws {
        let brand = try db.createBrand(workspaceId: ws.id, name: "Café Sol", industry: "Cafetería", networks: [.instagram, .linkedin])
        XCTAssertEqual(try db.brands(workspaceId: ws.id), [brand])
        XCTAssertEqual(try db.brand(id: brand.id)?.networks, [.instagram, .linkedin])
    }

    func testDeleteBrandRemovesItsContentAndUnlinksTheRest() throws {
        let brand = try db.createBrand(workspaceId: ws.id, name: "Café Sol", industry: "", networks: [.instagram])
        let other = try db.createBrand(workspaceId: ws.id, name: "Otra", industry: "", networks: [.instagram])
        _ = try db.createDraft(brandId: brand.id, network: .instagram, body: "Hola", media: [], scheduledFor: nil)
        let kept = try db.createDraft(brandId: other.id, network: .instagram, body: "Sigo", media: [], scheduledFor: nil)
        let task = try db.createTask(workspaceId: ws.id, title: "Fotos", dueDate: nil, brandId: brand.id)
        let agent = try db.ensureDefaultAgent(workspaceId: ws.id)
        let chat = try db.createConversation(workspaceId: ws.id, agentId: agent.id, brandId: brand.id, firstPrompt: "hola")

        try db.deleteBrand(id: brand.id)

        XCTAssertEqual(try db.brands(workspaceId: ws.id), [other])
        XCTAssertEqual(try db.posts(brandId: nil, status: nil), [kept])
        XCTAssertNil(try db.tasks(workspaceId: ws.id, on: nil).first { $0.id == task.id }?.brandId)
        XCTAssertNil(try db.conversations(workspaceId: ws.id, limit: 10).first { $0.id == chat.id }?.brandId)
    }

    func testBrandWithAPostBeingPreparedCannotBeDeleted() throws {
        let brand = try db.createBrand(workspaceId: ws.id, name: "B", industry: "", networks: [.instagram])
        var post = try db.createDraft(brandId: brand.id, network: .instagram, body: "Hola", media: [], scheduledFor: nil)
        post.status = .preparing
        try db.writer.write { try post.update($0) }
        XCTAssertThrowsError(try db.deleteBrand(id: brand.id)) { error in
            XCTAssertEqual((error as? ValidationError)?.message, "B tiene un post preparándose en el navegador: termina o cancela antes de borrarla.")
        }
    }

    func testBrandDeletionNeedsTheExactName() {
        let brand = Brand(id: "x", workspaceId: ws.id, name: "Café Sol", industry: "", networks: [.instagram], createdAt: Date())
        XCTAssertTrue(brand.deletionConfirmed(by: "Café Sol"))
        XCTAssertTrue(brand.deletionConfirmed(by: "  Café Sol "))
        XCTAssertFalse(brand.deletionConfirmed(by: "café sol"))
        XCTAssertFalse(brand.deletionConfirmed(by: "Café"))
        XCTAssertFalse(brand.deletionConfirmed(by: ""))
    }

    func testBrandNameIsRequired() {
        XCTAssertThrowsError(try db.createBrand(workspaceId: ws.id, name: "  ", industry: "", networks: [.instagram]))
    }

    func testCreateDraftValidatesBody() throws {
        let brand = try db.createBrand(workspaceId: ws.id, name: "B", industry: "", networks: [.instagram])
        XCTAssertThrowsError(try db.createDraft(brandId: brand.id, network: .instagram, body: String(repeating: "x", count: 2201), media: [], scheduledFor: nil))
        let post = try db.createDraft(brandId: brand.id, network: .instagram, body: "Hola ☕️", media: [], scheduledFor: nil)
        XCTAssertEqual(post.status, .draft)
    }

    func testCreateDraftRejectsNetworkNotEnabledForBrand() throws {
        let brand = try db.createBrand(workspaceId: ws.id, name: "B", industry: "", networks: [.instagram])
        XCTAssertThrowsError(try db.createDraft(brandId: brand.id, network: .linkedin, body: "Hola", media: [], scheduledFor: nil)) { error in
            XCTAssertEqual((error as? ValidationError)?.message, "La marca B no tiene linkedin configurado.")
        }
    }

    func testCreateDraftRejectsUnknownBrand() {
        XCTAssertThrowsError(try db.createDraft(brandId: "nope", network: .instagram, body: "Hola", media: [], scheduledFor: nil)) { error in
            XCTAssertEqual((error as? ValidationError)?.message, "No existe marca con id nope.")
        }
    }

    func testUpdateDraftFailsWhenPostIsApproved() throws {
        let brand = try db.createBrand(workspaceId: ws.id, name: "B", industry: "", networks: [.instagram])
        let post = try db.createDraft(brandId: brand.id, network: .instagram, body: "v1", media: [], scheduledFor: nil)
        _ = try db.transitionPost(id: post.id, to: .approved, actor: .user)
        XCTAssertThrowsError(try db.updateDraft(id: post.id, body: "v2", media: nil, scheduledFor: nil)) { error in
            XCTAssertEqual((error as? ValidationError)?.message, "Solo se pueden editar posts en borrador; este está en approved.")
        }
        XCTAssertEqual(try db.posts(brandId: brand.id, status: nil).first?.body, "v1")
    }

    func testAgentCannotTransitionPost() throws {
        let brand = try db.createBrand(workspaceId: ws.id, name: "B", industry: "", networks: [.instagram])
        let post = try db.createDraft(brandId: brand.id, network: .instagram, body: "v1", media: [], scheduledFor: nil)
        XCTAssertThrowsError(try db.transitionPost(id: post.id, to: .approved, actor: .agent))
    }

    func testTasksForDayAndComplete() throws {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let tomorrow = cal.date(byAdding: .day, value: 1, to: today)!
        let t1 = try db.createTask(workspaceId: ws.id, title: "Grabar reel", dueDate: today.addingTimeInterval(3600), brandId: nil)
        _ = try db.createTask(workspaceId: ws.id, title: "Mañana", dueDate: tomorrow.addingTimeInterval(60), brandId: nil)
        XCTAssertEqual(try db.tasks(workspaceId: ws.id, on: today).map(\.title), ["Grabar reel"])
        XCTAssertTrue(try db.completeTask(id: t1.id).done)
    }

    func testIdeaScoreMustBe1To5() throws {
        XCTAssertThrowsError(try db.createIdea(workspaceId: ws.id, title: "X", summary: "Y", sources: [], score: 6))
        let idea = try db.createIdea(workspaceId: ws.id, title: "X", summary: "Y", sources: ["https://a.com"], score: 4)
        XCTAssertEqual(idea.sources, ["https://a.com"])
    }

    func testRunsLifecycleAndCrashRecovery() throws {
        let run = try db.startRun(workspaceId: ws.id, brandId: nil, prompt: "hola")
        XCTAssertEqual(run.status, .running)
        XCTAssertEqual(try db.failRunningRuns(), 1)
        XCTAssertEqual(try db.runs(workspaceId: ws.id).first?.status, .failed)
        let run2 = try db.startRun(workspaceId: ws.id, brandId: nil, prompt: "otra")
        let done = try db.finishRun(id: run2.id, status: .done, summary: "ok", inputTokens: 10, outputTokens: 5, costUsd: 0.01)
        XCTAssertEqual(done.costUsd, 0.01)
    }

    func testRunPersistsAnUnavailableProviderCostSeparatelyFromZero() throws {
        let run = try db.startRun(workspaceId: ws.id, brandId: nil, prompt: "hola")
        let done = try db.finishRun(id: run.id, status: .done, summary: "ok", inputTokens: 1, outputTokens: 2, costUsd: nil)
        XCTAssertEqual(done.costUsd, 0)
        XCTAssertFalse(done.costAvailable)
    }
}
