import XCTest
@testable import FrontbotCore

final class ImageJobsTests: XCTestCase {
    func testPendingImagesSurviveEditorClose() {
        var jobs = ImageJobs()
        XCTAssertTrue(jobs.begin(postId: "p1", runId: "r1", total: 3))
        XCTAssertFalse(jobs.begin(postId: "p1", runId: "r2", total: 1), "un solo trabajo por post")
        jobs.created(runId: "r1", assetId: "a1")
        jobs.created(runId: "r1", assetId: "a2")
        jobs.created(runId: "otro", assetId: "x")
        XCTAssertEqual(jobs.job(postId: "p1")?.done, 2)
        // El editor estaba cerrado: al reabrir se lleva las dos, en orden, una sola vez.
        XCTAssertEqual(jobs.take(postId: "p1"), ["a1", "a2"])
        XCTAssertEqual(jobs.take(postId: "p1"), [])
        XCTAssertEqual(jobs.job(postId: "p1")?.done, 2, "el progreso sigue contando lo ya creado")
    }

    func testFinishKeepsPendingUntilTaken() {
        var jobs = ImageJobs()
        _ = jobs.begin(postId: "p1", runId: "r1", total: 2)
        jobs.created(runId: "r1", assetId: "a1")
        jobs.finish(runId: "r1", error: "OpenAI no generó la imagen")
        XCTAssertEqual(jobs.job(postId: "p1")?.running, false)
        XCTAssertEqual(jobs.job(postId: "p1")?.error, "OpenAI no generó la imagen")
        XCTAssertTrue(jobs.begin(postId: "p1", runId: "r2", total: 1), "terminado, se puede crear otra vez")
        XCTAssertEqual(jobs.take(postId: "p1"), ["a1"], "lo creado antes no se pierde")
    }

    func testTakeRemovesFinishedJob() {
        var jobs = ImageJobs()
        _ = jobs.begin(postId: "p1", runId: "r1", total: 1)
        jobs.created(runId: "r1", assetId: "a1")
        jobs.finish(runId: "r1", error: nil)
        XCTAssertEqual(jobs.take(postId: "p1"), ["a1"])
        XCTAssertNil(jobs.job(postId: "p1"))
    }
}
