import XCTest
@testable import FrontbotCore

final class AgentLocatorTests: XCTestCase {
    let res = URL(fileURLWithPath: "/Applications/Frontbot.app/Contents/Resources")
    let bundled = AgentLocation(node: "/Applications/Frontbot.app/Contents/Resources/node/bin/node",
                                script: "/Applications/Frontbot.app/Contents/Resources/agent/dist/main.js")

    func testEnvironmentWins() {
        let env = ["FRONTBOT_NODE": "/n", "FRONTBOT_AGENT_SCRIPT": "/s.js"]
        XCTAssertEqual(AgentLocator.locate(environment: env, resources: res, exists: { _ in true }), AgentLocation(node: "/n", script: "/s.js"))
    }

    func testBundleWhenNoEnvironment() {
        XCTAssertEqual(AgentLocator.locate(environment: [:], resources: res, exists: { _ in true }), bundled)
    }

    func testEnvironmentPointingToMissingFilesFallsBackToBundle() {
        let env = ["FRONTBOT_NODE": "/n", "FRONTBOT_AGENT_SCRIPT": "/s.js"]
        XCTAssertEqual(AgentLocator.locate(environment: env, resources: res, exists: { $0.hasPrefix("/Applications") }), bundled)
    }

    func testNothingFound() {
        XCTAssertNil(AgentLocator.locate(environment: [:], resources: res, exists: { _ in false }))
        XCTAssertNil(AgentLocator.locate(environment: [:], resources: nil, exists: { _ in true }))
    }
}
