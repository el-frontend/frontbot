import XCTest
@testable import FrontbotCore

final class ContentCalendarTests: XCTestCase {
    var cal: Calendar!
    var content: ContentCalendar!

    override func setUp() {
        cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Mexico_City")!
        cal.firstWeekday = 2
        content = ContentCalendar(calendar: cal)
    }

    func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 9, _ min: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    func post(_ at: Date?, brand: String = "b1", network: Network = .instagram, status: PostStatus = .draft) -> Post {
        Post(id: UUID().uuidString, brandId: brand, network: network, body: "x", media: [], status: status,
             scheduledFor: at, publishedUrl: nil, createdAt: Date(), updatedAt: Date())
    }

    func testWeekStartsOnMonday() {
        // Miércoles 14 de octubre de 2026 → semana lunes 12 a domingo 18.
        let days = content.days(.week, containing: date(2026, 10, 14), posts: [], brandId: nil, network: nil)
        XCTAssertEqual(days.count, 7)
        XCTAssertEqual(days.first?.date, cal.startOfDay(for: date(2026, 10, 12)))
        XCTAssertEqual(days.last?.date, cal.startOfDay(for: date(2026, 10, 18)))
    }

    func testSundayLateNightStaysInThatWeek() {
        let late = post(date(2026, 10, 18, 23, 30))
        let days = content.days(.week, containing: date(2026, 10, 14), posts: [late], brandId: nil, network: nil)
        XCTAssertEqual(days.last?.posts, [late])
        let next = content.days(.week, containing: date(2026, 10, 19), posts: [late], brandId: nil, network: nil)
        XCTAssertTrue(next.allSatisfy { $0.posts.isEmpty })
    }

    func testMonthGridCoversWholeWeeksAndMarksOutOfScope() {
        // Octubre 2026: 1 = jueves, 31 = sábado → del lunes 28 sep al domingo 1 nov = 35 días.
        let days = content.days(.month, containing: date(2026, 10, 14), posts: [], brandId: nil, network: nil)
        XCTAssertEqual(days.count, 35)
        XCTAssertEqual(days.first?.date, cal.startOfDay(for: date(2026, 9, 28)))
        XCTAssertFalse(days.first!.inScope)
        XCTAssertTrue(days[3].inScope) // 1 de octubre
        XCTAssertFalse(days.last!.inScope)
    }

    func testFiltersAndExcludesArchived() {
        let ig = post(date(2026, 10, 14), brand: "b1", network: .instagram)
        let li = post(date(2026, 10, 14, 10), brand: "b1", network: .linkedin)
        let other = post(date(2026, 10, 14), brand: "b2")
        let archived = post(date(2026, 10, 14), status: .archived)
        let days = content.days(.week, containing: date(2026, 10, 14), posts: [li, ig, other, archived], brandId: "b1", network: nil)
        XCTAssertEqual(days[2].posts, [ig, li]) // ordenados por hora
        let onlyLi = content.days(.week, containing: date(2026, 10, 14), posts: [li, ig], brandId: nil, network: .linkedin)
        XCTAssertEqual(onlyLi[2].posts, [li])
    }

    func testUnscheduled() {
        let a = post(nil)
        let b = post(date(2026, 10, 14))
        let c = post(nil, status: .archived)
        XCTAssertEqual(content.unscheduled([a, b, c], brandId: nil, network: nil), [a])
    }

    func testShift() {
        XCTAssertEqual(cal.component(.day, from: content.shift(date(2026, 10, 14), scope: .week, by: 1)), 21)
        XCTAssertEqual(cal.component(.month, from: content.shift(date(2026, 10, 31), scope: .month, by: 1)), 11)
    }
}
