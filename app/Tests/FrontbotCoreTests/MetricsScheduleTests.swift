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
