import Foundation
import AppKit
import Observation
import UserNotifications
import ServiceManagement
import FrontbotCore

struct ChatMessage: Identifiable, Equatable {
    typealias Role = ChatRole
    let id = UUID()
    let role: Role
    var text: String
}

@MainActor @Observable
final class AppModel {
    enum Section: Hashable { case agent(String), brand(String), calendar, chat, tasks, ideas, skills, trades, schedules }

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
    /// Estado de la mascota (las vistas lo leen con la hora actual).
    var mascot = MascotMood()
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
    /// Conversación, agente y marca del run del chat: puedes abrir otros chats mientras responde.
    private struct ActiveRun { let conversationId: String; let agentId: String; let brandId: String? }
    private var activeRun: ActiveRun?
    var runningConversationId: String? { activeRun?.conversationId }
    /// El agente está respondiendo en la conversación que tienes abierta.
    var isRunningHere: Bool { isRunning && activeRun != nil && activeRun?.conversationId == currentConversationId }
    /// Runs que terminaron antes de que `run()` devolviera su id (no deben perderse).
    private var earlyFinished: [String: AgentRun] = [:]
    private var keyAccount: String { "\(workspace.id).\(CredentialStore.anthropicKey)" }

    init() throws {
        paths = AppPaths.standard()
        db = try AppDatabase.open(at: paths.database)
        try db.failRunningRuns() // runs que quedaron "running" de una sesión anterior
        try db.flagInterruptedSends() // órdenes que quedaron a medio enviar
        try db.failRunningTaskRuns() // ejecuciones programadas que quedaron a medias
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
        reloadSkills()
        if AgentLocator.locate(environment: ProcessInfo.processInfo.environment, resources: Bundle.main.resourceURL) == nil {
            errorMessage = AgentLocator.notFoundMessage
        }
        Task { await listen() }
        reloadProposals()
        reloadTasks()
        startScheduler()
        Task { [weak self] in
            await self?.client.setTradeKeys(KeychainTradeKeys())
            await self?.client.setScriptApprover { [weak self] request in await self?.askScriptApproval(request) ?? false }
            await self?.client.setFileWriteApprover { [weak self] request in await self?.askFileWriteApproval(request) ?? false }
        }
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

    /// Borra la marca, sus posts, imágenes y guía. Las tareas y conversaciones se quedan, sin marca.
    @discardableResult
    func deleteBrand(_ brand: Brand) -> Bool {
        if isRunning && activeRun?.brandId == brand.id {
            errorMessage = "El agente está trabajando con \(brand.name): espera a que termine para borrarla."
            return false
        }
        guard perform({ try db.deleteBrand(id: brand.id) }) else { return false }
        // La marca ya no está en la base: si fallan los archivos, solo quedan huérfanos en disco.
        try? BrandFiles(paths: paths).deleteBrand(brandId: brand.id)
        brands = (try? db.brands(workspaceId: workspace.id)) ?? brands.filter { $0.id != brand.id }
        if selectedBrandId == brand.id { selectedBrandId = brands.first?.id }
        if section == .brand(brand.id) { section = .chat }
        reloadContent()
        reloadConversations()
        return true
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

    // MARK: Skills

    var skills: [Skill] = []
    var skillDraftCount: Int { skills.filter { $0.status == .draft }.count }
    private var library: SkillLibrary { SkillLibrary(db: db, paths: paths) }

    func reloadSkills() { skills = (try? library.all()) ?? skills }

    func skillsAssigned(to agentId: String) -> [Skill] {
        _ = skills
        return (try? library.skills(assignedTo: agentId, activeOnly: false)) ?? []
    }

    func skillFiles(_ skill: Skill) -> [String] { (try? library.files(of: skill)) ?? [] }
    func skillManifest(_ skill: Skill) -> String { (try? library.manifestText(of: skill)) ?? "" }
    func skillDirectory(_ skill: Skill) -> URL { library.directory(for: skill) }
    func agentsUsing(_ skill: Skill) -> [Agent] {
        let ids = Set((try? library.agentIds(using: skill.id)) ?? [])
        return agents.filter { ids.contains($0.id) }
    }

    /// Carpeta con SKILL.md o .zip (estándar de Anthropic).
    @discardableResult
    func importSkill(from url: URL) -> Skill? {
        var imported: Skill?
        perform { imported = url.pathExtension.lowercased() == "zip" ? try library.importZip(url) : try library.importFolder(url) }
        reloadSkills()
        return imported
    }

    @discardableResult
    func createSkill(name: String, description: String, body: String) -> Skill? {
        var created: Skill?
        perform { created = try library.createUserSkill(name: name, description: description, body: body) }
        reloadSkills()
        return created
    }

    @discardableResult
    func saveSkillManifest(_ skill: Skill, text: String) -> Bool {
        let ok = perform { _ = try library.saveManifest(id: skill.id, text: text) }
        reloadSkills()
        return ok
    }

    func activateSkill(_ skill: Skill) {
        perform { _ = try library.activate(id: skill.id) }
        reloadSkills()
    }

    func deleteSkill(_ skill: Skill) {
        perform { try library.delete(id: skill.id) }
        reloadSkills()
    }

    func setSkill(_ skill: Skill, assigned: Bool, to agentId: String) {
        perform { assigned ? try library.assign(skillId: skill.id, to: agentId) : try library.unassign(skillId: skill.id, from: agentId) }
        reloadSkills()
    }

    // MARK: Tareas programadas

    var scheduledTasks: [ScheduledTask] = []
    var taskDraftCount: Int { scheduledTasks.filter { $0.status == .draft }.count }
    /// Ejecuciones programadas en curso, por id de run del agente.
    private var scheduledRuns: [String: ScheduledRunLog] = [:]
    /// Eventos de runs que aún no están registrados (llegan antes de que `run()` devuelva el id).
    private var orphanUpdates: [String: [AgentUpdate]] = [:]
    private var schedulerTimer: Timer?
    /// Tareas que están arrancando (entre startTaskRun y que el run tenga id): evita dobles ejecuciones.
    private var startingTaskIds: Set<String> = []
    /// Una ejecución programada que no termina en este plazo se cancela.
    static let scheduledRunDeadline: Duration = .seconds(15 * 60)
    let notifications = NotificationRouter()

    func reloadTasks() { scheduledTasks = (try? db.tasks()) ?? scheduledTasks }

    func tasks(agentId: String) -> [ScheduledTask] { scheduledTasks.filter { $0.agentId == agentId } }

    func taskRuns(_ task: ScheduledTask) -> [TaskRun] {
        _ = scheduledTasks
        return (try? db.taskRuns(taskId: task.id)) ?? []
    }

    func isTaskRunning(_ task: ScheduledTask) -> Bool {
        startingTaskIds.contains(task.id) || scheduledRuns.values.contains { $0.task.id == task.id }
            || ((try? db.hasRunningRun(taskId: task.id)) ?? false)
    }

    func cancelTaskRun(_ task: ScheduledTask) {
        guard let runId = scheduledRuns.first(where: { $0.value.task.id == task.id })?.key else { return }
        Task { await client.cancel(runId: runId) }
    }

    /// La próxima ejecución entre todas las tareas activas (para el notch).
    var nextScheduled: (task: ScheduledTask, agent: Agent)? {
        scheduledTasks.filter { $0.status == .active && $0.nextRunAt != nil }
            .min { $0.nextRunAt! < $1.nextRunAt! }
            .flatMap { t in agent(id: t.agentId).map { (t, $0) } }
    }

    @discardableResult
    func createTask(agentId: String, draft: TaskDraft) -> Bool {
        let ok = perform { _ = try db.createTask(agentId: agentId, draft: draft, status: .active, createdBy: nil) }
        reloadTasks()
        return ok
    }

    @discardableResult
    func updateTask(_ task: ScheduledTask, draft: TaskDraft) -> Bool {
        let ok = perform { _ = try db.updateTask(id: task.id, draft: draft) }
        reloadTasks()
        return ok
    }

    func setTaskStatus(_ task: ScheduledTask, _ status: TaskStatus) {
        perform { _ = try db.setTaskStatus(id: task.id, status) }
        reloadTasks()
    }

    func deleteTask(_ task: ScheduledTask) {
        perform { try db.deleteTask(scheduledTaskId: task.id) }
        reloadTasks()
    }

    func runTaskNow(_ task: ScheduledTask) {
        guard !isTaskRunning(task) else { return }
        start(task, manual: true)
    }

    private func startScheduler() {
        notifications.model = self
        UNUserNotificationCenter.current().delegate = notifications
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in } // macOS lo pregunta una vez
        schedulerTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickScheduler() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.tickScheduler() }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5)) // deja arrancar la app antes de lo atrasado
            tickScheduler()
        }
    }

    func tickScheduler() {
        guard let due = try? db.dueTasks() else { return }
        let now = Date()
        for task in due where !isTaskRunning(task) {
            // Lo atrasado fuera de horario (p. ej. al despertar de madrugada) no corre: se mueve a la próxima ventana.
            guard task.schedule.allows(now) else { try? db.skipTask(id: task.id, now: now); continue }
            start(task)
        }
        reloadTasks()
    }

    private func start(_ task: ScheduledTask, manual: Bool = false) {
        guard let agent = agent(id: task.agentId), agent.status == .active, !isTaskRunning(task) else { return }
        let taskRun: TaskRun
        do { taskRun = try db.startTaskRun(taskId: task.id) } catch { return }
        startingTaskIds.insert(task.id)
        reloadTasks()
        Task {
            defer { startingTaskIds.remove(task.id) }
            do {
                let run = try await client.run(prompt: task.instruction, agent: agent, brand: nil, model: task.model, task: task)
                try? db.attachAgentRun(taskRunId: taskRun.id, agentRunId: run.id)
                scheduledRuns[run.id] = ScheduledRunLog(taskRunId: taskRun.id, task: task, startedAt: taskRun.startedAt, manual: manual)
                for update in orphanUpdates.removeValue(forKey: run.id) ?? [] { handleScheduled(update) }
                Task { [weak self] in
                    try? await Task.sleep(for: Self.scheduledRunDeadline)
                    guard let self, self.scheduledRuns[run.id] != nil else { return }
                    await self.client.cancel(runId: run.id) // nadie mira: un run colgado no puede bloquear la tarea
                }
            } catch {
                try? db.finishTaskRun(id: taskRun.id, status: .failed, summary: error.localizedDescription, notified: false,
                                      conversationId: nil, costUsd: 0)
                reloadTasks()
            }
        }
    }

    /// Eventos de una ejecución programada. Devuelve false si el run no es programado.
    @discardableResult
    private func handleScheduled(_ update: AgentUpdate) -> Bool {
        switch update {
        case .event(let runId, let type, let text):
            guard scheduledRuns[runId] != nil else { return false }
            if type == "text" { scheduledRuns[runId]?.record(.agent, text) }
            if type == "tool_call" { scheduledRuns[runId]?.record(.tool, "→ \(text)") }
            return true
        case .notify(let runId, let title, let message):
            guard scheduledRuns[runId] != nil else { return false }
            scheduledRuns[runId]?.notification = (title, message)
            return true
        case .finished(let run):
            guard let log = scheduledRuns.removeValue(forKey: run.id) else { return false }
            let proposals = (try? db.proposalsCount(agentId: log.task.agentId, since: log.startedAt)) ?? 0
            let result = try? db.completeScheduledRun(log, run: run, workspaceId: workspace.id, proposalsCreated: proposals)
            if log.manual, let conversationId = result?.conversationId, !isRunning {
                openConversation(id: conversationId) // la lanzaste tú: te llevo al resultado
            }
            if let note = log.notification {
                deliverNotification(title: note.title, body: note.message, conversationId: result?.conversationId)
            } else if run.status == .failed {
                deliverNotification(title: "Falló «\(log.task.name)»", body: run.resultSummary ?? "Error", conversationId: result?.conversationId)
            }
            memoryVersion += 1
            brands = (try? db.brands(workspaceId: workspace.id)) ?? brands
            reloadAgents()
            reloadSkills()
            reloadContent()
            reloadTasks()
            reloadConversations()
            return true
        default:
            return false
        }
    }

    /// Un run programado puede emitir eventos antes de que `run()` devuelva su id: se guardan un momento
    /// y se reproducen al registrarlo. Los de otros runs (chat, resúmenes) se descartan al llenarse el búfer.
    private func bufferIfUnknown(_ update: AgentUpdate) {
        let runId: String
        switch update {
        case .event(let id, _, _), .notify(let id, _, _): runId = id
        case .finished(let run): runId = run.id
        default: return
        }
        guard runId != currentRunId else { return }
        if orphanUpdates.count > 30 { orphanUpdates.removeAll() }
        if orphanUpdates[runId, default: []].count < 200 { orphanUpdates[runId, default: []].append(update) }
    }

    func deliverNotification(title: String, body: String, conversationId: String?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let conversationId { content.userInfo = ["conversationId": conversationId] }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    /// Al tocar un aviso: abrir su conversación.
    func openConversation(id: String) {
        reloadConversations()
        if let c = conversations.first(where: { $0.id == id }) ?? (try? db.conversations(workspaceId: workspace.id, limit: 200))?.first(where: { $0.id == id }) {
            openConversation(c)
        }
        showMainWindow(section: .chat)
    }

    // MARK: Arranque al iniciar sesión

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do { newValue ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
            catch { errorMessage = "No se pudo cambiar el inicio automático: \(error.localizedDescription)" }
            launchAtLoginVersion += 1
        }
    }
    var launchAtLoginVersion = 0

    // MARK: Trading

    var proposals: [TradeProposal] = []
    var pendingProposals: [TradeProposal] { proposals.filter { $0.status == .proposed } }
    var hasTradingAgents: Bool { agents.contains { $0.trading } }
    /// Propuesta que se está enviando o cerrando (para deshabilitar botones).
    var busyProposalId: String?
    private let tradeKeys = KeychainTradeKeys()

    func reloadProposals() { proposals = (try? db.proposals()) ?? proposals }

    func mandate(agentId: String) -> TradingMandate {
        _ = proposals
        return (try? db.mandate(agentId: agentId)) ?? .default(agentId: agentId)
    }

    @discardableResult
    func saveMandate(_ mandate: TradingMandate) -> Bool {
        let ok = perform { try db.saveMandate(mandate) }
        reloadProposals()
        return ok
    }

    func hasTradingKey(agentId: String, network: TradeNetwork) -> Bool {
        _ = proposals
        return tradeKeys.privateKey(agentId: agentId, network: network) != nil
    }

    @discardableResult
    func saveTradingKey(agentId: String, network: TradeNetwork, key: String) -> Bool {
        let ok = perform { try tradeKeys.save(agentId: agentId, network: network, privateKey: key) }
        reloadProposals()
        return ok
    }

    func removeTradingKey(agentId: String, network: TradeNetwork) {
        perform { try tradeKeys.remove(agentId: agentId, network: network) }
        reloadProposals()
    }

    func approveProposal(_ p: TradeProposal) { runTrade(p) { try await $0.approve(id: p.id) } }
    func closeTrade(_ p: TradeProposal) { runTrade(p) { try await $0.close(id: p.id) } }

    func rejectProposal(_ p: TradeProposal) {
        perform { _ = try client.tradingService(db: db).reject(id: p.id) }
        reloadProposals()
    }

    func pauseAllTrading() {
        perform { try db.pauseAllTrading() }
        reloadProposals()
    }

    /// Posiciones y órdenes abiertas en Hyperliquid (lectura bajo demanda).
    func accountOverview(agentId: String) async -> (JSONValue?, String?) {
        let m = mandate(agentId: agentId)
        guard let address = m.address else { return (nil, "Conecta la wallet del agente para ver sus posiciones.") }
        do { return (try await client.accountOverview(network: m.network, address: address), nil) }
        catch { return (nil, error.localizedDescription) }
    }

    private func runTrade(_ p: TradeProposal, _ work: @escaping (TradingService) async throws -> TradeProposal) {
        guard busyProposalId == nil else { return }
        busyProposalId = p.id
        Task {
            defer { busyProposalId = nil }
            do {
                let done = try await work(await client.trading)
                if done.status == .failed { errorMessage = done.error ?? "No se pudo enviar el trade." }
            } catch let e as ValidationError {
                errorMessage = e.message
            } catch {
                errorMessage = error.localizedDescription
            }
            reloadProposals()
        }
    }

    private func notifyTrade(_ p: TradeProposal) {
        let agentName = agent(id: p.agentId)?.name ?? "Un agente"
        let title: String
        switch p.status {
        case .proposed: title = "\(agentName) propone un trade"
        case .open where p.auto: title = "Trade automático ejecutado"
        case .failed: title = "Falló un trade"
        default: return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = "\(p.side == .long ? "Long" : "Short") \(p.coin) · \(Int(p.sizeUsd)) USD · \(p.leverage)x · SL \(p.stopLoss.formatted())\(p.network == .mainnet ? " · MAINNET" : "")"
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            center.add(UNNotificationRequest(identifier: p.id + p.status.rawValue, content: content, trigger: nil))
        }
    }

    // MARK: Aprobación de scripts

    /// Petición de script esperando al usuario (hoja modal); solo una a la vez.
    var pendingScript: ScriptRequest?
    private var scriptContinuation: CheckedContinuation<Bool, Never>?

    func askScriptApproval(_ request: ScriptRequest) async -> Bool {
        guard scriptContinuation == nil, pendingFileWrite == nil else { return false }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                scriptContinuation = continuation
                pendingScript = request
                NSApp.activate()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.answerScript(false) } // venció el plazo de aprobación
        }
    }

    func answerScript(_ allowed: Bool) {
        scriptContinuation?.resume(returning: allowed)
        scriptContinuation = nil
        pendingScript = nil
    }

    // MARK: Archivos

    /// Cambia cuando cambian las carpetas de algún agente (las vistas lo leen para refrescarse).
    private var foldersVersion = 0

    func folders(agentId: String) -> [String] {
        _ = foldersVersion
        return (try? db.folders(agentId: agentId)) ?? []
    }

    func addFolder(_ url: URL, agentId: String) {
        perform {
            let path = try AgentFiles.validatedFolder(url.path, protected: [paths.root])
            try db.addFolder(agentId: agentId, path: path)
        }
        foldersVersion += 1
    }

    func removeFolder(_ path: String, agentId: String) {
        perform { try db.removeFolder(agentId: agentId, path: path) }
        foldersVersion += 1
    }

    /// Escritura de archivo esperando al usuario (hoja modal); una a la vez y nunca a la vez que un script.
    var pendingFileWrite: FileWriteRequest?
    private var fileWriteContinuation: CheckedContinuation<Bool, Never>?

    func askFileWriteApproval(_ request: FileWriteRequest) async -> Bool {
        guard fileWriteContinuation == nil, pendingScript == nil else { return false }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                fileWriteContinuation = continuation
                pendingFileWrite = request
                NSApp.activate()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.answerFileWrite(false) } // venció el plazo de aprobación
        }
    }

    func answerFileWrite(_ allowed: Bool) {
        fileWriteContinuation?.resume(returning: allowed)
        fileWriteContinuation = nil
        pendingFileWrite = nil
    }

    // MARK: Agentes

    func reloadAgents() {
        agents = (try? db.agents(workspaceId: workspace.id)) ?? agents
        if selectedAgent == nil { selectedAgentId = agents.first?.id ?? "" }
    }

    @discardableResult
    func createAgent(_ draft: AgentDraft) -> Agent? {
        var created: Agent?
        perform {
            let agent = try db.createAgent(workspaceId: workspace.id, draft: draft, status: .active)
            try library.installTemplateSkills(for: agent)
            try db.installTemplateTasks(for: agent)
            created = agent
        }
        reloadAgents()
        reloadSkills()
        reloadTasks()
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
        guard !(isRunning && activeRun?.agentId == id) else { return }
        guard perform({ try db.deleteAgent(id: id) }) else { return }
        for network in TradeNetwork.allCases { try? tradeKeys.remove(agentId: id, network: network) }
        if selectedAgentId == id { selectedAgentId = agents.first { $0.isDefault }?.id ?? "" ; messages = []; currentConversationId = nil }
        reloadAgents()
        reloadConversations()
        section = .chat
    }

    func agent(id: String?) -> Agent? { agents.first { $0.id == id } }

    /// Cambia cuando la memoria puede haber cambiado (las vistas lo leen para refrescarse).
    var memoryVersion = 0

    func memories(agentId: String) -> [AgentMemory] {
        _ = memoryVersion
        return (try? db.memories(agentId: agentId)) ?? []
    }

    func forgetMemory(agentId: String, memoryId: Int64) {
        perform { try db.forget(agentId: agentId, memoryId: memoryId) }
        memoryVersion += 1
    }

    func clearMemory(agentId: String) {
        perform { try db.clearMemory(agentId: agentId) }
        memoryVersion += 1
    }

    // MARK: Chat

    func send(prompt: String) {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunning else { return }
        guard let agent = selectedAgent else { return }
        guard agent.status == .active else {
            errorMessage = "\(agent.name) es un borrador: actívalo en su página para hablar con él."
            return
        }
        let history = chatHistory()
        if currentConversationId == nil {
            guard perform({
                currentConversationId = try db.createConversation(workspaceId: workspace.id, agentId: selectedAgentId, brandId: selectedBrandId, firstPrompt: text).id
            }) else { return }
        }
        record(.user, text)
        if let conversationId = currentConversationId {
            activeRun = ActiveRun(conversationId: conversationId, agentId: agent.id, brandId: selectedBrandId)
        }
        isRunning = true
        mascot.runStarted(at: Date())
        Task {
            do {
                let id = try await client.run(prompt: text, agent: agent, brand: selectedBrand, history: history, model: agent.model).id
                if let run = earlyFinished.removeValue(forKey: id) { finish(run) } else { currentRunId = id }
            } catch {
                isRunning = false
                mascot.runFinished(ok: false, at: Date())
                record(.error, error.localizedDescription, in: activeRun?.conversationId)
                activeRun = nil
            }
        }
    }

    private func chatHistory() -> [ChatTurn] {
        messages.compactMap { m -> ChatTurn? in
            switch m.role {
            case .user: ChatTurn(role: .user, text: m.text)
            case .agent: ChatTurn(role: .agent, text: m.text)
            case .tool, .error: nil
            }
        }
    }

    /// Al dejar una conversación, un run corto (Haiku) guarda en la memoria del agente lo aprendido.
    private func summarizeLeavingConversation() {
        guard let id = currentConversationId, id != runningConversationId,
              let agent = agent(id: conversations.first { $0.id == id }?.agentId ?? selectedAgentId),
              (try? db.conversationNeedsSummary(id: id)) == true else { return }
        let history = chatHistory()
        try? db.markSummarized(id: id)
        Task {
            _ = try? await client.run(prompt: "", agent: agent, brand: nil, history: history,
                                      model: "claude-haiku-4-5-20251001", summarize: true)
        }
    }

    /// Nombre corto del modelo para el composer ("sonnet-5.5").
    var modelName: String { AgentModel.shortName(selectedModel) }

    /// Empieza una conversación nueva con el agente (por defecto, el del chat actual).
    func newConversation(agentId: String? = nil) {
        summarizeLeavingConversation()
        if let agentId { selectedAgentId = agentId }
        messages = []
        currentConversationId = nil
        lastAgentReply = nil
        section = .chat
    }

    func openConversation(_ conversation: Conversation) {
        section = .chat
        guard conversation.id != currentConversationId else { return }
        summarizeLeavingConversation()
        perform {
            messages = try db.messages(conversationId: conversation.id).map { ChatMessage(role: $0.role, text: $0.text) }
            currentConversationId = conversation.id
            if let agentId = conversation.agentId, agents.contains(where: { $0.id == agentId }) { selectedAgentId = agentId }
            lastAgentReply = messages.last { $0.role == .agent }?.text
            if let brandId = conversation.brandId, brands.contains(where: { $0.id == brandId }) { selectedBrandId = brandId }
        }
    }

    func deleteConversation(_ conversation: Conversation) {
        guard !(isRunning && conversation.id == runningConversationId) else { return }
        perform { try db.deleteConversation(id: conversation.id) }
        if conversation.id == currentConversationId { messages = []; currentConversationId = nil; lastAgentReply = nil }
        reloadConversations()
    }

    private func reloadConversations() {
        conversations = (try? db.conversations(workspaceId: workspace.id, limit: 15)) ?? conversations
    }

    /// Añade un mensaje al chat y lo guarda en la conversación abierta.
    private func record(_ role: ChatRole, _ text: String) { record(role, text, in: currentConversationId) }

    /// Guarda un mensaje en su conversación y lo muestra solo si es la que estás viendo.
    private func record(_ role: ChatRole, _ text: String, in conversationId: String?) {
        if conversationId == currentConversationId { messages.append(ChatMessage(role: role, text: text)) }
        guard let id = conversationId else { return }
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
        mascot.runFinished(ok: run.status == .done, at: Date())
        currentRunId = nil
        if run.status == .failed { record(.error, run.resultSummary ?? "Error", in: activeRun?.conversationId) }
        activeRun = nil
        brands = (try? db.brands(workspaceId: workspace.id)) ?? brands
        reloadAgents()
        reloadSkills()
        reloadTasks() // p. ej. una tarea que el agente dejó en borrador desde el chat
        reloadContent()
    }

    private func listen() async {
        for await update in await client.updates() {
            if handleScheduled(update) { continue }
            bufferIfUnknown(update)
            switch update {
            case .event(let runId, let type, let text) where runId == currentRunId:
                if type == "text" {
                    mascot.agentSpoke(at: Date())
                    record(.agent, text, in: activeRun?.conversationId)
                    lastAgentReply = text
                }
                if type == "tool_call" {
                    record(.tool, "→ \(text)", in: activeRun?.conversationId)
                    reloadContent()
                }
            case .finished(let run) where run.id == currentRunId:
                memoryVersion += 1
                finish(run)
            case .finished(let run) where isRunning && currentRunId == nil:
                earlyFinished[run.id] = run
            case .tradesChanged(let proposal):
                reloadProposals()
                notifyTrade(proposal)
            case .finished:
                memoryVersion += 1 // p. ej. el resumen en segundo plano
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

/// Recibe los toques en los avisos de macOS y abre la conversación correspondiente.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    weak var model: AppModel?

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let id = response.notification.request.content.userInfo["conversationId"] as? String else { return }
        await MainActor.run { model?.openConversation(id: id) }
    }

    /// Con la app en primer plano también se muestra el aviso.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

