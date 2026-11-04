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
        // API ∪ suscripción: `resolve` conserva los modelos de las dos formas de ejecutar Codex.
        XCTAssertEqual(AgentProvider.models(for: .codex).map(\.id), [
            "gpt-6-astra", "gpt-6.1-sol", "gpt-6.1-terra", "gpt-6-luna", "gpt-6-sol", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna",
        ])
    }

    func testResolveKeepsSessionModels() {
        XCTAssertEqual(AgentProvider.resolve("gpt-6-sol", for: .codex), "gpt-6-sol")
        XCTAssertEqual(AgentProvider.resolve("gpt-6.1-terra", for: .codex), "gpt-6.1-terra")
    }

    func testPickerModelsFollowSession() {
        let connected = CodexStatus(installed: true, compatible: true, version: "0.158.0", email: "a@b.c", plan: "pro", models: ["gpt-6-sol"])
        XCTAssertEqual(AgentProvider.pickerModels(for: .codex, codex: connected).map(\.id), ["gpt-6-sol"])
        let everyModel = CodexStatus(installed: true, compatible: true, version: "0.158.0", email: "a@b.c", plan: "pro", models: [])
        XCTAssertEqual(AgentProvider.pickerModels(for: .codex, codex: everyModel).map(\.id), AgentProvider.codexSessionModels.map(\.id))
        XCTAssertEqual(AgentProvider.pickerModels(for: .codex, codex: nil).map(\.id), ["gpt-6-astra", "gpt-6.1-sol", "gpt-6.1-terra", "gpt-6-luna"])
        XCTAssertEqual(AgentProvider.pickerModels(for: .claude, codex: connected).map(\.id), AgentProvider.models(for: .claude).map(\.id))
    }

    func testCapabilities() {
        XCTAssertEqual(AgentCapabilities.of(provider: .codex, codexConnected: false), AgentCapabilities(web: false, browser: false, workdir: false, lab: false))
        XCTAssertEqual(AgentCapabilities.of(provider: .codex, codexConnected: true), AgentCapabilities.of(provider: .claude, codexConnected: false))
        XCTAssertEqual(AgentCapabilities.of(provider: .claude, codexConnected: false), AgentCapabilities(web: true, browser: true, workdir: true, lab: true))
    }

    func testDraftDefaultsModelForSelectedProviderAndKeepsExplicitModel() {
        let codex = AgentDraft(name: "Codex", instructions: "x", provider: .codex)
        XCTAssertEqual(codex.model, AgentProvider.defaultModel(for: .codex))

        let explicit = AgentDraft(name: "Codex", instructions: "x", provider: .codex, model: "gpt-6.1-terra")
        XCTAssertEqual(explicit.model, "gpt-6.1-terra")
    }
}
