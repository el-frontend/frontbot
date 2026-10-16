import XCTest
@testable import FrontbotCore

final class ScheduleTests: XCTestCase {
    var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Mexico_City")!
        return c
    }()

    func date(_ s: String) -> Date {
        let f = DateFormatter()
        f.calendar = cal
        f.timeZone = cal.timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: s)!
    }

    func testIntervalAddsMinutes() throws {
        let s = Schedule.interval(minutes: 240)
        XCTAssertEqual(s.next(after: date("2026-10-17 10:07"), calendar: cal), date("2026-10-17 14:07"))
    }

    func testIntervalInsideAWindowJumpsToTheNextOpening() {
        let s = Schedule.interval(minutes: 60, window: TimeWindow(start: TimeOfDay(8, 0), end: TimeOfDay(22, 0)))
        XCTAssertEqual(s.next(after: date("2026-10-17 10:30"), calendar: cal), date("2026-10-17 11:30"))
        XCTAssertEqual(s.next(after: date("2026-10-17 21:30"), calendar: cal), date("2026-10-18 08:00"), "22:30 cae fuera")
        XCTAssertEqual(s.next(after: date("2026-10-17 03:00"), calendar: cal), date("2026-10-17 08:00"))
    }

    func testDailyIsTodayIfStillAheadOtherwiseTomorrow() {
        let s = Schedule.daily(TimeOfDay(9, 0))
        XCTAssertEqual(s.next(after: date("2026-10-17 08:59"), calendar: cal), date("2026-10-17 09:00"))
        XCTAssertEqual(s.next(after: date("2026-10-17 09:00"), calendar: cal), date("2026-10-18 09:00"))
    }

    func testWeeklyPicksTheNextListedDay() {
        // 2026-10-17 es sábado. Lunes = 2, miércoles = 4 (Calendar.weekday).
        let s = Schedule.weekly(days: [2, 4], TimeOfDay(7, 30))
        XCTAssertEqual(s.next(after: date("2026-10-17 12:00"), calendar: cal), date("2026-10-19 07:30"))
        XCTAssertEqual(s.next(after: date("2026-10-19 07:30"), calendar: cal), date("2026-10-21 07:30"))
    }

    func testValidation() {
        XCTAssertThrowsError(try Schedule.interval(minutes: 5).validated())
        XCTAssertThrowsError(try Schedule.weekly(days: [], TimeOfDay(9, 0)).validated())
        XCTAssertThrowsError(try Schedule.weekly(days: [9], TimeOfDay(9, 0)).validated())
        XCTAssertThrowsError(try Schedule.daily(TimeOfDay(25, 0)).validated())
        XCTAssertThrowsError(try Schedule.interval(minutes: 60, window: TimeWindow(start: TimeOfDay(10, 0), end: TimeOfDay(10, 0))).validated())
        XCTAssertNoThrow(try Schedule.interval(minutes: 15).validated())
    }

    func testRoundTripsAsJSONAndDescribesItself() throws {
        let s = Schedule.weekly(days: [2, 6], TimeOfDay(18, 5))
        let data = try JSONEncoder().encode(s)
        XCTAssertEqual(try JSONDecoder().decode(Schedule.self, from: data), s)
        XCTAssertEqual(Schedule.interval(minutes: 240).summary, "cada 4 h")
        XCTAssertEqual(Schedule.interval(minutes: 90).summary, "cada 90 min")
        XCTAssertEqual(Schedule.daily(TimeOfDay(9, 0)).summary, "diaria a las 09:00")
        XCTAssertEqual(s.summary, "lun, vie a las 18:05")
    }

    func testParsesWhatAgentsSend() throws {
        XCTAssertEqual(try Schedule.parse(["kind": "interval", "every_minutes": 240]), .interval(minutes: 240))
        XCTAssertEqual(try Schedule.parse(["kind": "daily", "time": "09:30"]), .daily(TimeOfDay(9, 30)))
        XCTAssertEqual(try Schedule.parse(["kind": "weekly", "days": ["mon", "fri"], "time": "18:00"]), .weekly(days: [2, 6], TimeOfDay(18, 0)))
        XCTAssertEqual(try Schedule.parse(["kind": "interval", "every_minutes": 60, "window": ["start": "08:00", "end": "22:00"]]),
                       .interval(minutes: 60, window: TimeWindow(start: TimeOfDay(8, 0), end: TimeOfDay(22, 0))))
        XCTAssertThrowsError(try Schedule.parse(["kind": "cron"]))
    }
}
