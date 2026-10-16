import Foundation
import AppKit
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
    enum Section: Hashable { case brand(String), calendar, chat, tasks, ideas }

    var section: Section = .chat
    var brands: [Brand] = []
    var selectedBrandId: String?
    var messages: [ChatMessage] = []
    var isRunning = false
    var errorMessage: String?
    var apiKeyPresent = false

    var posts: [Post] = []
    var tasks: [TaskItem] = []
    var ideas: [BusinessIdea] = []
    var today: TodaySummary?
    var assets: [BrandAsset] = []
    var guide: String?
    var calendarScope: CalendarScope = .week
    var calendarDate = Date()
    var calendarNetwork: Network?
    var calendarBrandId: String?
    var preparingPostId: String?
    var notchExpanded = false
    var lastAgentReply: String?
    var hotKeyRegistered = true
    var preparationMessage: String?

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
        if AgentLocator.locate(environment: ProcessInfo.processInfo.environment, resources: Bundle.main.resourceURL) == nil {
            errorMessage = AgentLocator.notFoundMessage
        }
        Task { await listen() }
    }

    static func makeConfig(apiKey: String?) -> AgentConfig {
        let env = ProcessInfo.processInfo.environment
        let location = AgentLocator.locate(environment: env, resources: Bundle.main.resourceURL)
        return AgentConfig(
            nodePath: location?.node ?? "/usr/bin/false",
            scriptPath: location?.script ?? "",
            apiKey: apiKey,
            model: env["FRONTBOT_MODEL"] ?? AgentConfig.defaultModel,
            fakeAgent: env["FRONTBOT_FAKE_AGENT"] == "1",
            browserProfileDir: AppPaths.standard().browserProfile.path)
    }

    var selectedBrand: Brand? { brands.first { $0.id == selectedBrandId } }
    func brand(id: String) -> Brand? { brands.first { $0.id == id } }

    func select(brandId: String) {
        selectedBrandId = brandId
        section = .brand(brandId)
        reloadContent()
    }

    func reloadContent() {
        tasks = (try? db.tasks(workspaceId: workspace.id, on: nil)) ?? []
        ideas = (try? db.ideas(workspaceId: workspace.id)) ?? []
        today = try? db.todaySummary(workspaceId: workspace.id)
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

    func showMainWindow(section: Section) {
        self.section = section
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { !($0 is NSPanel) && $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
    }

    func currentPost(_ id: String) -> Post? { posts.first { $0.id == id } }

    // MARK: Publicación asistida

    private var publishing: PublishingService { PublishingService(db: db, preparer: client) }

    func preparePublication(_ post: Post) {
        preparingPostId = post.id
        preparationMessage = nil
        Task {
            defer { preparingPostId = nil }
            do {
                let (_, result) = try await publishing.prepare(postId: post.id)
                if result.mode == .manual {
                    // Modo manual: el texto al portapapeles y las imágenes en Finder.
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(post.body, forType: .string)
                    let files = post.media.compactMap { try? db.asset(id: $0)?.path }.map { URL(fileURLWithPath: $0) }
                    if !files.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(files) }
                }
                preparationMessage = result.message
            } catch let e as ValidationError {
                errorMessage = e.message
            } catch {
                errorMessage = error.localizedDescription
            }
            reloadContent()
        }
    }

    func confirmPublished(_ post: Post, url: String) {
        perform { _ = try publishing.confirmPublished(postId: post.id, url: url) }
        preparationMessage = nil
        reloadContent()
    }

    func confirmScheduled(_ post: Post) {
        perform { _ = try publishing.confirmScheduled(postId: post.id) }
        preparationMessage = nil
        reloadContent()
    }

    func cancelPreparation(_ post: Post) {
        perform { _ = try publishing.cancelPreparation(postId: post.id) }
        preparationMessage = nil
        reloadContent()
    }

    func openLogin(_ network: Network) {
        Task {
            do { try await client.openLogin(network: network) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func brandAssets(_ brandId: String) -> [BrandAsset] { (try? db.assets(brandId: brandId, kind: .image)) ?? [] }

    // MARK: Tareas e ideas

    func addTask(title: String, dueDate: Date?) {
        perform { _ = try db.createTask(workspaceId: workspace.id, title: title, dueDate: dueDate, brandId: nil) }
        reloadContent()
    }

    func setTaskDone(_ task: TaskItem, done: Bool) {
        perform { _ = try db.setTaskDone(id: task.id, done: done) }
        reloadContent()
    }

    func deleteTask(_ task: TaskItem) {
        perform { try db.deleteTask(id: task.id) }
        reloadContent()
    }

    func deleteIdea(_ idea: BusinessIdea) {
        perform {
            let removed = try db.deleteIdea(id: idea.id)
            if let path = removed?.reportPath { try? FileManager.default.removeItem(atPath: path) }
        }
        reloadContent()
    }

    func ideaReport(_ idea: BusinessIdea) -> String? {
        idea.reportPath.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
    }

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
                if type == "text" {
                    messages.append(ChatMessage(role: .agent, text: text))
                    lastAgentReply = text
                }
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
