import XCTest
@testable import FrontbotCore

final class TodaySummaryTests: XCTestCase {
    var db: AppDatabase!
    var ws: Workspace!
    var brand: Brand!
    var cal: Calendar!
    var now: Date!

    override func setUpWithError() throws {
        db = try AppDatabase.inMemory()
        ws = try db.ensureDefaultWorkspace()
        brand = try db.createBrand(workspaceId: ws.id, name: "B", industry: "", networks: [.instagram, .linkedin])
        cal = Calendar.current
        now = cal.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
    }

    func day(_ offset: Int, hour: Int = 10) -> Date {
        cal.date(bySettingHour: hour, minute: 0, second: 0, of: cal.date(byAdding: .day, value: offset, to: now)!)!
    }

    func testBuckets() throws {
        let overdue = try db.createTask(workspaceId: ws.id, title: "ayer", dueDate: day(-1), brandId: nil)
        let today = try db.createTask(workspaceId: ws.id, title: "hoy", dueDate: day(0), brandId: nil)
        let later = try db.createTask(workspaceId: ws.id, title: "mañana", dueDate: day(1), brandId: nil)
        let someday = try db.createTask(workspaceId: ws.id, title: "algún día", dueDate: nil, brandId: nil)
        let done = try db.setTaskDone(id: try db.createTask(workspaceId: ws.id, title: "hecha", dueDate: day(-3), brandId: nil).id, done: true)
        let groups = TaskGrouping.group([later, done, someday, today, overdue], now: now, calendar: cal)
        XCTAssertEqual(groups.map(\.0), [.overdue, .today, .upcoming, .someday, .done])
        XCTAssertEqual(groups.map { $0.1.map(\.title) }, [["ayer"], ["hoy"], ["mañana"], ["algún día"], ["hecha"]])
    }

    func testSetTaskDoneTogglesAndDelete() throws {
        let t = try db.createTask(workspaceId: ws.id, title: "x", dueDate: nil, brandId: nil)
        XCTAssertTrue(try db.setTaskDone(id: t.id, done: true).done)
        XCTAssertFalse(try db.setTaskDone(id: t.id, done: false).done)
        try db.deleteTask(id: t.id)
        XCTAssertEqual(try db.tasks(workspaceId: ws.id, on: nil), [])
    }

    func testIdeasSortedByScoreAndDelete() throws {
        let low = try db.createIdea(workspaceId: ws.id, title: "baja", summary: "", sources: [], score: 2)
        _ = try db.createIdea(workspaceId: ws.id, title: "alta", summary: "", sources: [], score: 5)
        XCTAssertEqual(try db.ideas(workspaceId: ws.id).map(\.title), ["alta", "baja"])
        XCTAssertEqual(try db.deleteIdea(id: low.id)?.title, "baja")
        XCTAssertEqual(try db.ideas(workspaceId: ws.id).map(\.title), ["alta"])
    }

    func testTodaySummary() throws {
        _ = try db.createTask(workspaceId: ws.id, title: "ayer", dueDate: day(-1), brandId: nil)
        _ = try db.createTask(workspaceId: ws.id, title: "hoy", dueDate: day(0), brandId: nil)
        _ = try db.createTask(workspaceId: ws.id, title: "mañana", dueDate: day(1), brandId: nil)
        _ = try db.createDraft(brandId: brand.id, network: .linkedin, body: "borrador", media: [], scheduledFor: day(0, hour: 18))
        let approved = try db.createDraft(brandId: brand.id, network: .linkedin, body: "aprobado", media: [], scheduledFor: day(0, hour: 9))
        _ = try db.transitionPost(id: approved.id, to: .approved, actor: .user)
        let archived = try db.createDraft(brandId: brand.id, network: .linkedin, body: "archivado", media: [], scheduledFor: day(0))
        _ = try db.transitionPost(id: archived.id, to: .archived, actor: .user)
        // Otro workspace: no debe contar.
        let other = Workspace(id: UUID().uuidString, name: "otro", createdAt: Date())
        try db.writer.write { try other.insert($0) }
        let foreign = try db.createBrand(workspaceId: other.id, name: "F", industry: "", networks: [.linkedin])
        _ = try db.createDraft(brandId: foreign.id, network: .linkedin, body: "ajeno", media: [], scheduledFor: day(0))

        let s = try db.todaySummary(workspaceId: ws.id, now: now, calendar: cal)
        XCTAssertEqual(s.tasks.map(\.title), ["ayer", "hoy"])
        XCTAssertEqual(s.draftsToReview, 1)
        XCTAssertEqual(s.readyToPublish, 1)
        XCTAssertEqual(s.postsToday.map(\.body), ["aprobado", "borrador"])
    }
}
