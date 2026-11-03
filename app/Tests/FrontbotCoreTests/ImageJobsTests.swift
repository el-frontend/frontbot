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

extension ImageJobsTests {
    /// Dos clics seguidos en Crear: el segundo no arranca otro run mientras el primero se lanza.
    func testReserveBlocksSecondStartBeforeRunId() {
        var jobs = ImageJobs()
        XCTAssertTrue(jobs.reserve(postId: "p1", total: 2))
        XCTAssertFalse(jobs.reserve(postId: "p1", total: 2))
        XCTAssertEqual(jobs.job(postId: "p1")?.running, true)
        jobs.attach(postId: "p1", runId: "r1")
        jobs.created(runId: "r1", assetId: "a1")
        XCTAssertEqual(jobs.job(postId: "p1")?.done, 1)
    }

    func testFailedStartReleasesReservation() {
        var jobs = ImageJobs()
        _ = jobs.reserve(postId: "p1", total: 2)
        jobs.failStart(postId: "p1", error: "sin red")
        XCTAssertEqual(jobs.job(postId: "p1")?.running, false)
        XCTAssertEqual(jobs.job(postId: "p1")?.error, "sin red")
        XCTAssertTrue(jobs.reserve(postId: "p1", total: 1))
    }

    /// El agente terminó "bien" pero OpenAI falló: el usuario ve por qué faltan imágenes.
    func testToolErrorShownWhenFewerImagesThanAsked() {
        var jobs = ImageJobs()
        _ = jobs.begin(postId: "p1", runId: "r1", total: 3)
        jobs.created(runId: "r1", assetId: "a1")
        jobs.toolFailed(runId: "r1", message: "OpenAI no generó la imagen: Rate limit")
        jobs.finish(runId: "r1", error: nil)
        XCTAssertEqual(jobs.job(postId: "p1")?.error, "OpenAI no generó la imagen: Rate limit")
    }

    func testFewerImagesWithoutToolErrorStillExplains() {
        var jobs = ImageJobs()
        _ = jobs.begin(postId: "p1", runId: "r1", total: 3)
        jobs.created(runId: "r1", assetId: "a1")
        jobs.finish(runId: "r1", error: nil)
        XCTAssertNotNil(jobs.job(postId: "p1")?.error)
    }

    /// Detener a propósito no es un fallo.
    func testStopIsNotAnError() {
        var jobs = ImageJobs()
        _ = jobs.begin(postId: "p1", runId: "r1", total: 3)
        jobs.created(runId: "r1", assetId: "a1")
        jobs.stop(postId: "p1")
        jobs.finish(runId: "r1", error: "Cancelado")
        XCTAssertNil(jobs.job(postId: "p1")?.error)
        XCTAssertEqual(jobs.take(postId: "p1"), ["a1"])
    }
}
