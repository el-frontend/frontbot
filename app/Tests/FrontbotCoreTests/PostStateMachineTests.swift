import XCTest
@testable import FrontbotCore

final class PostStateMachineTests: XCTestCase {
    func testUserFlowHappyPath() {
        XCTAssertTrue(PostStateMachine.canTransition(from: .draft, to: .approved, actor: .user))
        XCTAssertTrue(PostStateMachine.canTransition(from: .approved, to: .preparing, actor: .user))
        XCTAssertTrue(PostStateMachine.canTransition(from: .preparing, to: .published, actor: .user))
        XCTAssertTrue(PostStateMachine.canTransition(from: .preparing, to: .scheduled, actor: .user))
        XCTAssertTrue(PostStateMachine.canTransition(from: .scheduled, to: .published, actor: .user))
        XCTAssertTrue(PostStateMachine.canTransition(from: .preparing, to: .approved, actor: .user))
    }

    func testUserCanArchiveFromAnyState() {
        for status in PostStatus.allCases where status != .archived {
            XCTAssertTrue(PostStateMachine.canTransition(from: status, to: .archived, actor: .user), "\(status)")
        }
    }

    func testUserCannotSkipSteps() {
        XCTAssertFalse(PostStateMachine.canTransition(from: .draft, to: .published, actor: .user))
        XCTAssertFalse(PostStateMachine.canTransition(from: .draft, to: .preparing, actor: .user))
        XCTAssertFalse(PostStateMachine.canTransition(from: .published, to: .draft, actor: .user))
    }

    func testAgentCannotMovePostsAtAll() {
        for from in PostStatus.allCases {
            for to in PostStatus.allCases where to != from {
                XCTAssertFalse(PostStateMachine.canTransition(from: from, to: to, actor: .agent), "\(from)->\(to)")
            }
        }
    }

    func testCheckTransitionThrowsReadableError() {
        XCTAssertThrowsError(try PostStateMachine.checkTransition(from: .draft, to: .published, actor: .user)) { error in
            XCTAssertEqual((error as? ValidationError)?.message, "No se puede pasar un post de draft a published.")
        }
    }
}
