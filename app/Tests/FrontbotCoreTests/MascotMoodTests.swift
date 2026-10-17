import XCTest
@testable import FrontbotCore

final class MascotMoodTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    func testIdleUntilSomethingHappens() {
        let mood = MascotMood()
        XCTAssertEqual(mood.state(at: t0, listening: false), .idle)
        XCTAssertEqual(mood.state(at: t0, listening: true), .listening)
    }

    func testThinkingThenTalkingWhileTextArrives() {
        var mood = MascotMood()
        mood.runStarted(at: at(0))
        XCTAssertEqual(mood.state(at: at(0.5), listening: true), .thinking, "el run manda sobre escuchar")
        mood.agentSpoke(at: at(1))
        XCTAssertEqual(mood.state(at: at(2), listening: false), .talking)
        XCTAssertEqual(mood.state(at: at(1 + MascotMood.talkingHold + 0.1), listening: false), .thinking, "sin texto nuevo vuelve a pensar")
    }

    func testHappyThenIdleAfterSuccess() {
        var mood = MascotMood()
        mood.runStarted(at: at(0))
        mood.runFinished(ok: true, at: at(5))
        XCTAssertEqual(mood.state(at: at(5.5), listening: true), .happy, "la reacción manda sobre escuchar")
        XCTAssertEqual(mood.state(at: at(5 + MascotMood.reactionDuration + 0.1), listening: false), .idle)
        XCTAssertEqual(mood.state(at: at(5 + MascotMood.reactionDuration + 0.1), listening: true), .listening)
    }

    func testSadThenIdleAfterFailureOrCancel() {
        var mood = MascotMood()
        mood.runStarted(at: at(0))
        mood.agentSpoke(at: at(1))
        mood.runFinished(ok: false, at: at(1.2))
        XCTAssertEqual(mood.state(at: at(1.3), listening: false), .sad, "nunca se queda hablando ni pensando")
        XCTAssertEqual(mood.state(at: at(1.2 + MascotMood.reactionDuration + 0.1), listening: false), .idle)
    }

    func testRunThatFailsToStartStillEndsSad() {
        var mood = MascotMood()
        mood.runStarted(at: at(0))
        mood.runFinished(ok: false, at: at(0)) // send() falla antes de que el agente arranque
        XCTAssertEqual(mood.state(at: at(0.1), listening: false), .sad)
    }

    func testNewRunClearsThePreviousReaction() {
        var mood = MascotMood()
        mood.runFinished(ok: true, at: at(0))
        mood.runStarted(at: at(0.5))
        XCTAssertEqual(mood.state(at: at(0.6), listening: false), .thinking)
    }
}
