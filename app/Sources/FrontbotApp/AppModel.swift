import Foundation
import Observation
import FrontbotCore

struct ChatMessage: Identifiable, Equatable {
    enum Role { case user, agent, tool, error }
    let id = UUID()
    let role: Role
    var text: String
}

@MainActor @Observable
final class AppModel {
    var brands: [Brand] = []
    var selectedBrandId: String?
    var messages: [ChatMessage] = []
    var isRunning = false
    var errorMessage: String?
    var apiKeyPresent = false

    private let db: AppDatabase
    private let workspace: Workspace
    private let credentials = CredentialStore()
    private let client: AgentClient
    private var currentRunId: String?
    private var keyAccount: String { "\(workspace.id).\(CredentialStore.anthropicKey)" }

    init() throws {
        let paths = AppPaths.standard()
        db = try AppDatabase.open(at: paths.database)
        try db.failRunningRuns() // runs que quedaron "running" de una sesión anterior
        workspace = try db.ensureDefaultWorkspace()
        let key = try? credentials.get("\(workspace.id).\(CredentialStore.anthropicKey)")
        apiKeyPresent = !(key ?? "").isEmpty
        client = AgentClient(config: Self.makeConfig(apiKey: key), db: db, files: BrandFiles(paths: paths), workspaceId: workspace.id)
        brands = try db.brands(workspaceId: workspace.id)
        selectedBrandId = brands.first?.id
        Task { await listen() }
    }

    static func makeConfig(apiKey: String?) -> AgentConfig {
        let env = ProcessInfo.processInfo.environment
        return AgentConfig(
            nodePath: env["FRONTBOT_NODE"] ?? "/opt/homebrew/bin/node",
            scriptPath: env["FRONTBOT_AGENT_SCRIPT"] ?? "",
            apiKey: apiKey,
            model: env["FRONTBOT_MODEL"] ?? AgentConfig.defaultModel,
            fakeAgent: env["FRONTBOT_FAKE_AGENT"] == "1")
    }

    var selectedBrand: Brand? { brands.first { $0.id == selectedBrandId } }

    func createBrand(name: String, industry: String, networks: [Network]) {
        do {
            let brand = try db.createBrand(workspaceId: workspace.id, name: name, industry: industry, networks: networks)
            brands = try db.brands(workspaceId: workspace.id)
            selectedBrandId = brand.id
        } catch let e as ValidationError { errorMessage = e.message } catch { errorMessage = error.localizedDescription }
    }

    func send(prompt: String) {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunning else { return }
        messages.append(ChatMessage(role: .user, text: text))
        isRunning = true
        Task {
            do {
                currentRunId = try await client.run(prompt: text, brand: selectedBrand).id
            } catch {
                isRunning = false
                messages.append(ChatMessage(role: .error, text: error.localizedDescription))
            }
        }
    }

    func cancel() {
        guard let id = currentRunId else { return }
        Task { await client.cancel(runId: id) }
    }

    func saveApiKey(_ key: String) {
        do {
            try credentials.set(keyAccount, value: key.trimmingCharacters(in: .whitespacesAndNewlines))
            apiKeyPresent = true
            Task { await client.setConfig(Self.makeConfig(apiKey: key)) }
        } catch let e as ValidationError { errorMessage = e.message } catch { errorMessage = error.localizedDescription }
    }

    private func listen() async {
        for await update in await client.updates() {
            switch update {
            case .event(let runId, let type, let text) where runId == currentRunId:
                if type == "text" { messages.append(ChatMessage(role: .agent, text: text)) }
                if type == "tool_call" { messages.append(ChatMessage(role: .tool, text: "→ \(text)")) }
            case .finished(let run) where run.id == currentRunId:
                isRunning = false
                currentRunId = nil
                if run.status == .failed { messages.append(ChatMessage(role: .error, text: run.resultSummary ?? "Error")) }
                brands = (try? db.brands(workspaceId: workspace.id)) ?? brands
            default:
                break
            }
        }
    }
}
