import Foundation
import AppKit
import Observation
import FrontbotCore

struct ChatMessage: Identifiable, Equatable {
    typealias Role = ChatRole
    let id = UUID()
    let role: Role
    var text: String
}

@MainActor @Observable
final class AppModel {
    enum Section: Hashable { case agent(String), brand(String), calendar, chat, tasks, ideas }

    var section: Section = .chat
    var brands: [Brand] = []
    var selectedBrandId: String?
    var messages: [ChatMessage] = []
    var isRunning = false
    var errorMessage: String?
    var apiKeyPresent = false
    /// Agentes (Frontbot primero) y con cuál se habla en el chat.
    var agents: [Agent] = []
    var selectedAgentId = ""
    var selectedAgent: Agent? { agents.first { $0.id == selectedAgentId } }

    /// Modelo del agente del chat; elegirlo en el composer lo guarda en el agente.
    var selectedModel: String {
        get { selectedAgent?.model ?? AgentConfig.defaultModel }
        set {
            guard let agent = selectedAgent, agent.model != newValue else { return }
            var draft = AgentDraft(agent: agent)
            draft.model = newValue
            updateAgent(agent.id, draft: draft)
        }
    }
    /// Conversaciones recientes (barra lateral) y la abierta en el chat.
    var conversations: [Conversation] = []
    var currentConversationId: String?

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
    var notchExpanded = false
    var lastAgentReply: String?
    var hotKeyRegistered = true
    /// Reabre la ventana principal si el usuario la cerró (lo fija la vista con `openWindow`).
    var openMainWindowAction: (() -> Void)?
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
        let frontbot = try db.ensureDefaultAgent(workspaceId: workspace.id)
        try Self.migrateChatPreferences(db: db, frontbot: frontbot)
        agents = try db.agents(workspaceId: workspace.id)
        selectedAgentId = frontbot.id
        brands = try db.brands(workspaceId: workspace.id)
        selectedBrandId = brands.first?.id
        reloadContent()
        reloadConversations()
        if AgentLocator.locate(environment: ProcessInfo.processInfo.environment, resources: Bundle.main.resourceURL) == nil {
            errorMessage = AgentLocator.notFoundMessage
        }
        Task { await listen() }
    }

    /// Antes de los agentes, el modelo y el navegador eran ajustes globales: pasan a Frontbot una sola vez.
    private static func migrateChatPreferences(db: AppDatabase, frontbot: Agent) throws {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "useBrowser") != nil || defaults.string(forKey: "model") != nil else { return }
        var draft = AgentDraft(agent: frontbot)
        draft.browser = defaults.bool(forKey: "useBrowser") || frontbot.browser
        if let model = defaults.string(forKey: "model") { draft.model = AgentModel.resolve(model) }
        _ = try db.updateAgent(id: frontbot.id, draft: draft)
        defaults.removeObject(forKey: "useBrowser")
        defaults.removeObject(forKey: "model")
    }

    static func makeConfig(apiKey: String?) -> AgentConfig {
        let env = ProcessInfo.processInfo.environment
        let location = AgentLocator.locate(environment: env, resources: Bundle.main.resourceURL)
        return AgentConfig(
            nodePath: location?.node ?? "/usr/bin/false",
            scriptPath: location?.script ?? "",
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

    static let mainWindowId = "main"

    func showMainWindow(section: Section) {
        self.section = section
        NSApp.activate()
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix(Self.mainWindowId) == true }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openMainWindowAction?()
        }
    }

    func currentPost(_ id: String) -> Post? { posts.first { $0.id == id } }

    // MARK: Publicación asistida

    private var publishing: PublishingService { PublishingService(db: db, handoff: BrowserHandoff()) }

    func preparePublication(_ post: Post) {
        preparationMessage = nil
        perform { preparationMessage = try publishing.prepare(postId: post.id).1.message }
        reloadContent()
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

    /// Abre la red en el navegador del usuario, donde ya tiene la sesión iniciada.
    func openNetwork(_ network: Network) {
        NSWorkspace.shared.open(PublishingLinks.homeURL(network))
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

    // MARK: Agentes

    func reloadAgents() {
        agents = (try? db.agents(workspaceId: workspace.id)) ?? agents
        if selectedAgent == nil { selectedAgentId = agents.first?.id ?? "" }
    }

    @discardableResult
    func createAgent(_ draft: AgentDraft) -> Agent? {
        var created: Agent?
        perform { created = try db.createAgent(workspaceId: workspace.id, draft: draft, status: .active) }
        reloadAgents()
        if let created { section = .agent(created.id) }
        return created
    }

    @discardableResult
    func updateAgent(_ id: String, draft: AgentDraft) -> Bool {
        let ok = perform { _ = try db.updateAgent(id: id, draft: draft) }
        reloadAgents()
        return ok
    }

    func activateAgent(_ id: String) {
        perform { _ = try db.activateAgent(id: id) }
        reloadAgents()
    }

    /// Borra el agente y sus conversaciones (o descarta un borrador).
    func deleteAgent(_ id: String) {
        guard !(isRunning && selectedAgentId == id) else { return }
        guard perform({ try db.deleteAgent(id: id) }) else { return }
        if selectedAgentId == id { selectedAgentId = agents.first { $0.isDefault }?.id ?? "" ; messages = []; currentConversationId = nil }
        reloadAgents()
        reloadConversations()
        section = .chat
    }

    func agent(id: String?) -> Agent? { agents.first { $0.id == id } }

    // MARK: Chat

    func send(prompt: String) {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunning else { return }
        guard let agent = selectedAgent else { return }
        guard agent.status == .active else {
            errorMessage = "\(agent.name) es un borrador: actívalo en su página para hablar con él."
            return
        }
        let history = messages.compactMap { m -> ChatTurn? in
            switch m.role {
            case .user: ChatTurn(role: .user, text: m.text)
            case .agent: ChatTurn(role: .agent, text: m.text)
            case .tool, .error: nil
            }
        }
        if currentConversationId == nil {
            guard perform({
                currentConversationId = try db.createConversation(workspaceId: workspace.id, agentId: selectedAgentId, brandId: selectedBrandId, firstPrompt: text).id
            }) else { return }
        }
        record(.user, text)
        isRunning = true
        Task {
            do {
                let id = try await client.run(prompt: text, agent: agent, brand: selectedBrand, history: history, model: agent.model).id
                if let run = earlyFinished.removeValue(forKey: id) { finish(run) } else { currentRunId = id }
            } catch {
                isRunning = false
                record(.error, error.localizedDescription)
            }
        }
    }

    /// Nombre corto del modelo para el composer ("sonnet-5.5").
    var modelName: String { AgentModel.shortName(selectedModel) }

    /// Empieza una conversación nueva con el agente (por defecto, el del chat actual).
    func newConversation(agentId: String? = nil) {
        guard !isRunning else { return }
        if let agentId { selectedAgentId = agentId }
        messages = []
        currentConversationId = nil
        lastAgentReply = nil
        section = .chat
    }

    func openConversation(_ conversation: Conversation) {
        guard !isRunning else { return }
        section = .chat
        guard conversation.id != currentConversationId else { return }
        perform {
            messages = try db.messages(conversationId: conversation.id).map { ChatMessage(role: $0.role, text: $0.text) }
            currentConversationId = conversation.id
            if let agentId = conversation.agentId, agents.contains(where: { $0.id == agentId }) { selectedAgentId = agentId }
            lastAgentReply = messages.last { $0.role == .agent }?.text
            if let brandId = conversation.brandId, brands.contains(where: { $0.id == brandId }) { selectedBrandId = brandId }
        }
    }

    func deleteConversation(_ conversation: Conversation) {
        guard !(isRunning && conversation.id == currentConversationId) else { return }
        perform { try db.deleteConversation(id: conversation.id) }
        if conversation.id == currentConversationId { messages = []; currentConversationId = nil; lastAgentReply = nil }
        reloadConversations()
    }

    private func reloadConversations() {
        conversations = (try? db.conversations(workspaceId: workspace.id, limit: 15)) ?? conversations
    }

    /// Añade un mensaje al chat y lo guarda en la conversación abierta.
    private func record(_ role: ChatRole, _ text: String) {
        messages.append(ChatMessage(role: role, text: text))
        guard let id = currentConversationId else { return }
        do { try db.appendMessage(conversationId: id, role: role, text: text) } catch { errorMessage = error.localizedDescription }
        reloadConversations()
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
        if run.status == .failed { record(.error, run.resultSummary ?? "Error") }
        brands = (try? db.brands(workspaceId: workspace.id)) ?? brands
        reloadAgents()
        reloadContent()
    }

    private func listen() async {
        for await update in await client.updates() {
            switch update {
            case .event(let runId, let type, let text) where runId == currentRunId:
                if type == "text" {
                    record(.agent, text)
                    lastAgentReply = text
                }
                if type == "tool_call" {
                    record(.tool, "→ \(text)")
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

/// Entrega el post al navegador por defecto: el texto al portapapeles, las imágenes en el Finder.
struct BrowserHandoff: PublicationHandoff {
    func handOff(url: URL, body: String, mediaPaths: [String]) throws {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(body, forType: .string)
        if !mediaPaths.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(mediaPaths.map { URL(fileURLWithPath: $0) })
        }
        guard NSWorkspace.shared.open(url) else { throw ValidationError("No se pudo abrir el navegador.") }
    }
}
