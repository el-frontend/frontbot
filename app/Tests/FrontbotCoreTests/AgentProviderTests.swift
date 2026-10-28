import XCTest
@testable import FrontbotCore

final class AgentProviderTests: XCTestCase {
    func testProviderIdentifiersAndDefaultModels() {
        XCTAssertEqual(AgentProvider.allCases.map(\.rawValue), ["claude", "codex"])
        XCTAssertEqual(AgentProvider.defaultModel(for: .claude), "claude-sonnet-5-5")
        XCTAssertEqual(AgentProvider.defaultModel(for: .codex), "gpt-5-codex")
    }

    func testResolveKeepsKnownModelsAndFallsBackPerProvider() {
        XCTAssertEqual(AgentProvider.resolve("claude-opus-5-5", for: .claude), "claude-opus-5-5")
        XCTAssertEqual(AgentProvider.resolve("gpt-5-codex", for: .codex), "gpt-5-codex")
        XCTAssertEqual(AgentProvider.resolve("unknown-model", for: .claude), AgentProvider.defaultModel(for: .claude))
        XCTAssertEqual(AgentProvider.resolve("unknown-model", for: .codex), AgentProvider.defaultModel(for: .codex))
        XCTAssertEqual(AgentProvider.resolve("claude-sonnet-5-5", for: .codex), AgentProvider.defaultModel(for: .codex))
    }

    func testModelsAreProviderSpecific() {
        XCTAssertTrue(AgentProvider.models(for: .claude).contains { $0.id == "claude-sonnet-5-5" })
        XCTAssertFalse(AgentProvider.models(for: .codex).contains { $0.id.hasPrefix("claude-") })
        XCTAssertTrue(AgentProvider.models(for: .codex).contains { $0.id == "gpt-5-codex" })
    }
}
