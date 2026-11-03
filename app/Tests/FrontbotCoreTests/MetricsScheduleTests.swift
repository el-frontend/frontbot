import XCTest
@testable import FrontbotCore

final class MetricsScheduleTests: XCTestCase {
    let t = Date(timeIntervalSince1970: 1_800_000_000)

    func at(_ hours: Double) -> Date { t.addingTimeInterval(hours * 3600) }

    func meta(_ readings: [MetricsCheckpoint] = [], skipped: [MetricsCheckpoint] = [], published: Bool = true) -> PostMetadata {
        PostMetadata(publishedAt: published ? t : nil,
                     metrics: readings.map { MetricsReading(checkpoint: $0, readAt: t, reach: nil, views: nil, likes: nil, reposts: nil, sourceUrl: nil, note: nil) },
                     skipped: skipped)
    }

    func assertDue(_ m: PostMetadata, _ hours: Double, _ checkpoint: MetricsCheckpoint?, skip: [MetricsCheckpoint] = [],
                   file: StaticString = #filePath, line: UInt = #line) {
        let due = MetricsSchedule.due(m, now: at(hours))
        XCTAssertEqual(due?.checkpoint, checkpoint, file: file, line: line)
        if checkpoint != nil { XCTAssertEqual(due?.skip, skip, file: file, line: line) }
    }

    func testNothingBefore24h() { assertDue(meta(), 23 + 59.0 / 60, nil) }
    func testFirstCheckpoint() { assertDue(meta(), 25, .h24) }
    func testAlreadyReadIsNotDue() { assertDue(meta([.h24]), 30, nil) }
    func testPostponedStaysDueUntilNext() { assertDue(meta(), 47, .h24) }
    func testAppClosedThreeDays() { assertDue(meta(), 73, .h72, skip: [.h24, .h48]) }
    func testSkippedIsNotDue() { assertDue(meta([.h48], skipped: [.h24]), 60, nil) }
    func testManualDoesNotCount() { assertDue(meta([.manual]), 25, .h24) }
    func testNoPublishedAt() { assertDue(meta(published: false), 100, nil) }

    func testCanStart() {
        XCTAssertTrue(MetricsSchedule.canStart(activeRuns: 0, provider: .claude))
        XCTAssertFalse(MetricsSchedule.canStart(activeRuns: 1, provider: .claude))
        XCTAssertFalse(MetricsSchedule.canStart(activeRuns: 0, provider: .codex))
    }
}

extension MetricsScheduleTests {
    /// La de 72 h no se reintenta para siempre: 24 h después de su momento se da por saltada.
    func testLastCheckpointExpiresAfterWindow() {
        assertDue(meta(), 95, .h72, skip: [.h24, .h48])
        assertDue(meta(), 97, nil)
        XCTAssertEqual(MetricsSchedule.stale(meta(), now: at(97)), [.h24, .h48, .h72])
        XCTAssertEqual(MetricsSchedule.stale(meta([.h24, .h48]), now: at(97)), [.h72])
        XCTAssertEqual(MetricsSchedule.stale(meta(), now: at(30)), [])
    }

    /// Un intento que no guardó nada (sin Chrome, detenido, error) espera una hora y hay como mucho 4 por momento.
    func testAttemptsBackOffAndCap() {
        var attempts = MetricsAttempts()
        XCTAssertTrue(attempts.allows(postId: "p", .h24, now: at(25)))
        attempts.failed(postId: "p", .h24, at: at(25))
        XCTAssertFalse(attempts.allows(postId: "p", .h24, now: at(25.5)))
        XCTAssertTrue(attempts.allows(postId: "p", .h24, now: at(26)))
        XCTAssertTrue(attempts.allows(postId: "p", .h48, now: at(25.5)), "otro momento no hereda la espera")
        XCTAssertTrue(attempts.allows(postId: "q", .h24, now: at(25.5)), "otro post tampoco")
        for h in [26.0, 27, 28] { attempts.failed(postId: "p", .h24, at: at(h)) }
        XCTAssertFalse(attempts.allows(postId: "p", .h24, now: at(40)), "4 intentos y se deja")
    }
}
