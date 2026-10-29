import XCTest
@testable import FrontbotCore

final class AgentProviderTests: XCTestCase {
    func testProviderIdentifiersAndDefaultModels() {
        XCTAssertEqual(AgentProvider.allCases.map(\.rawValue), ["claude", "codex"])
        XCTAssertEqual(AgentProvider.defaultModel(for: .claude), "claude-sonnet-5-5")
        XCTAssertEqual(AgentProvider.defaultModel(for: .codex), "gpt-6-astra")
    }

    func testResolveKeepsKnownModelsAndFallsBackPerProvider() {
        XCTAssertEqual(AgentProvider.resolve("claude-opus-5-5", for: .claude), "claude-opus-5-5")
        XCTAssertEqual(AgentProvider.resolve("gpt-6-astra", for: .codex), "gpt-6-astra")
        XCTAssertEqual(AgentProvider.resolve("unknown-model", for: .claude), AgentProvider.defaultModel(for: .claude))
        XCTAssertEqual(AgentProvider.resolve("unknown-model", for: .codex), AgentProvider.defaultModel(for: .codex))
        XCTAssertEqual(AgentProvider.resolve("claude-sonnet-5-5", for: .codex), AgentProvider.defaultModel(for: .codex))
    }

    func testModelsAreProviderSpecific() {
        XCTAssertTrue(AgentProvider.models(for: .claude).contains { $0.id == "claude-sonnet-5-5" })
        XCTAssertFalse(AgentProvider.models(for: .codex).contains { $0.id.hasPrefix("claude-") })
        XCTAssertEqual(AgentProvider.models(for: .codex).map(\.id), [
            "gpt-6-astra", "gpt-6-sol", "gpt-6-luna", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5",
        ])
    }

    func testDraftDefaultsModelForSelectedProviderAndKeepsExplicitModel() {
        let codex = AgentDraft(name: "Codex", instructions: "x", provider: .codex)
        XCTAssertEqual(codex.model, AgentProvider.defaultModel(for: .codex))

        let explicit = AgentDraft(name: "Codex", instructions: "x", provider: .codex, model: "gpt-5.6-terra")
        XCTAssertEqual(explicit.model, "gpt-5.6-terra")
    }
}
