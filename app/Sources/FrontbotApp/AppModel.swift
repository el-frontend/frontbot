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
    enum Section: Hashable { case brand(String), calendar, chat }

    var section: Section = .chat
    var brands: [Brand] = []
    var selectedBrandId: String?
    var messages: [ChatMessage] = []
    var isRunning = false
    var errorMessage: String?
    var apiKeyPresent = false

    var posts: [Post] = []
    var assets: [BrandAsset] = []
    var guide: String?
    var calendarScope: CalendarScope = .week
    var calendarDate = Date()
    var calendarNetwork: Network?
    var calendarBrandId: String?

    private let db: AppDatabase
    private let paths: AppPaths
    private let workspace: Workspace
    private let credentials = CredentialStore()
    private let client: AgentClient
    private var currentRunId: String?
    /// Runs que terminaron antes de que `run()` devolviera su id (no deben perderse).
    private var earlyFinished: [String: AgentRun] = [:]
    private var keyAccount: String { "\(workspace.id).\(CredentialStore.anthropicKey)" }

    init() throws {
        paths = AppPaths.standard()
        db = try AppDatabase.open(at: paths.database)
        try db.failRunningRuns() // runs que quedaron "running" de una sesión anterior
        workspace = try db.ensureDefaultWorkspace()
        let key = try? credentials.get("\(workspace.id).\(CredentialStore.anthropicKey)")
        apiKeyPresent = CredentialStore.normalizedApiKey(key) != nil
        client = AgentClient(config: Self.makeConfig(apiKey: key), db: db, files: BrandFiles(paths: paths), workspaceId: workspace.id)
        brands = try db.brands(workspaceId: workspace.id)
        selectedBrandId = brands.first?.id
        reloadContent()
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
    func brand(id: String) -> Brand? { brands.first { $0.id == id } }

    func select(brandId: String) {
        selectedBrandId = brandId
        section = .brand(brandId)
        reloadContent()
    }

    func reloadContent() {
        posts = (try? db.posts(brandId: nil, status: nil)) ?? []
        if let id = selectedBrandId {
            assets = (try? db.assets(brandId: id, kind: .image)) ?? []
            guide = try? BrandFiles(paths: paths).readGuide(brandId: id)
        } else {
            assets = []
            guide = nil
        }
    }

    // MARK: Marcas

    func createBrand(name: String, industry: String, networks: [Network]) {
        perform {
            let brand = try db.createBrand(workspaceId: workspace.id, name: name, industry: industry, networks: networks)
            brands = try db.brands(workspaceId: workspace.id)
            select(brandId: brand.id)
        }
    }

    func importImages(_ urls: [URL]) {
        guard let id = selectedBrandId else { return }
        let importer = AssetImporter(db: db, paths: paths)
        var failures: [String] = []
        for url in urls {
            do { _ = try importer.importImage(from: url, brandId: id) }
            catch let e as ValidationError { failures.append("\(url.lastPathComponent): \(e.message)") }
            catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        errorMessage = failures.isEmpty ? nil : failures.joined(separator: "\n")
        reloadContent()
    }

    func saveGuide(_ markdown: String) {
        guard let id = selectedBrandId else { return }
        perform { try BrandFiles(paths: paths).writeGuide(brandId: id, markdown: markdown) }
        reloadContent()
    }

    func startInterview() {
        guard let brand = selectedBrand else { return }
        messages = []
        section = .chat
        send(prompt: GuideSources.interviewPrompt(brandName: brand.name))
    }

    func guideFromPDF(_ url: URL) {
        guard let brand = selectedBrand else { return }
        perform {
            _ = try AssetImporter(db: db, paths: paths).importGuidePDF(from: url, brandId: brand.id)
            let text = try GuideSources.text(fromPDF: url)
            messages = []
            section = .chat
            send(prompt: GuideSources.pdfPrompt(brandName: brand.name, pdfText: text))
        }
    }

    // MARK: Posts

    @discardableResult
    func updatePost(_ post: Post, body: String, media: [String], scheduledFor: Date?) -> Bool {
        let ok = perform { _ = try db.updatePostByUser(id: post.id, body: body, media: media, scheduledFor: .some(scheduledFor)) }
        reloadContent()
        return ok
    }

    func approve(_ post: Post) {
        perform { _ = try db.transitionPost(id: post.id, to: .approved, actor: .user) }
        reloadContent()
    }

    func archive(_ post: Post) {
        perform { _ = try db.transitionPost(id: post.id, to: .archived, actor: .user) }
        reloadContent()
    }

    func brandAssets(_ brandId: String) -> [BrandAsset] { (try? db.assets(brandId: brandId, kind: .image)) ?? [] }

    // MARK: Chat

    func send(prompt: String) {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunning else { return }
        let history = messages.compactMap { m -> ChatTurn? in
            switch m.role {
            case .user: ChatTurn(role: .user, text: m.text)
            case .agent: ChatTurn(role: .agent, text: m.text)
            case .tool, .error: nil
            }
        }
        messages.append(ChatMessage(role: .user, text: text))
        isRunning = true
        Task {
            do {
                let id = try await client.run(prompt: text, brand: selectedBrand, history: history).id
                if let run = earlyFinished.removeValue(forKey: id) { finish(run) } else { currentRunId = id }
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

    @discardableResult
    func saveApiKey(_ key: String) -> Bool {
        guard let key = CredentialStore.normalizedApiKey(key) else {
            errorMessage = "La API key está vacía."
            return false
        }
        let ok = perform { try credentials.set(keyAccount, value: key) }
        if ok {
            apiKeyPresent = true
            Task { await client.setConfig(Self.makeConfig(apiKey: key)) }
        }
        return ok
    }

    @discardableResult
    private func perform(_ work: () throws -> Void) -> Bool {
        do {
            try work()
            errorMessage = nil
            return true
        } catch let e as ValidationError {
            errorMessage = e.message
        } catch {
            errorMessage = error.localizedDescription
        }
        return false
    }

    private func finish(_ run: AgentRun) {
        isRunning = false
        currentRunId = nil
        if run.status == .failed { messages.append(ChatMessage(role: .error, text: run.resultSummary ?? "Error")) }
        brands = (try? db.brands(workspaceId: workspace.id)) ?? brands
        reloadContent()
    }

    private func listen() async {
        for await update in await client.updates() {
            switch update {
            case .event(let runId, let type, let text) where runId == currentRunId:
                if type == "text" { messages.append(ChatMessage(role: .agent, text: text)) }
                if type == "tool_call" {
                    messages.append(ChatMessage(role: .tool, text: "→ \(text)"))
                    reloadContent()
                }
            case .finished(let run) where run.id == currentRunId:
                finish(run)
            case .finished(let run) where isRunning && currentRunId == nil:
                earlyFinished[run.id] = run
            default:
                break
            }
        }
    }
}
