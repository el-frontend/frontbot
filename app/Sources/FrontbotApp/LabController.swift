import Foundation
import Observation
import FrontbotCore

/// Pestaña de la página de un agente (la UI del laboratorio la construye sobre esto).
enum AgentTab { case general, lab }

/// Reloj del laboratorio: cada minuto decide si toca una sesión de estudio, la lanza y avisa de lo que sale.
@MainActor @Observable
final class LabController {
    static let studyModel = "claude-sonnet-5-5"
    /// Red de seguridad: una sesión que no termina en este plazo se cancela (cuenta como fallo).
    static let safetyDeadline: Duration = .seconds(25 * 60)

    private let db: AppDatabase
    private let paths: AppPaths
    private let client: AgentClient
    private let workspaceId: String
    @ObservationIgnored private weak var model: AppModel?

    var runningSession: (session: LabSession, topic: LabTopic, agent: Agent)?
    var datasets: [DatasetMeta] = []
    /// Cambia con cada escritura para que las vistas que leen del disco se refresquen.
    private(set) var version = 0
    /// Entre `startLabSession` y que el run tenga id: el reloj no lanza otra sesión.
    @ObservationIgnored private var launching = false
    @ObservationIgnored private var runningRunId: String?

    init(db: AppDatabase, paths: AppPaths, client: AgentClient, workspaceId: String, model: AppModel) {
        self.db = db
        self.paths = paths
        self.client = client
        self.workspaceId = workspaceId
        self.model = model
        reloadDatasets()
    }

    private var library: SkillLibrary { SkillLibrary(db: db, paths: paths) }
    private var versions: SkillVersions { SkillVersions(library: library) }
    private var datasetStore: Datasets { Datasets(paths: paths, downloader: URLSessionDatasetDownloader()) }

    // MARK: Reloj

    func tick() {
        guard !launching, runningSession == nil, let model else { return }
        if (try? db.runningLabSession()) != nil { return } // una sola sesión en toda la app
        let now = Date()
        var candidates: [LabCandidate] = []
        for agent in model.agents where agent.status == .active {
            guard let topics = try? db.topics(agentId: agent.id), let settings = try? db.labSettings(agentId: agent.id) else { continue }
            let used = (try? db.labTokensUsed(agentId: agent.id, day: now)) ?? 0
            for topic in topics where topic.status == .studying {
                candidates.append(LabCandidate(topic: topic, agent: agent, settings: settings, usedToday: used))
            }
        }
        guard let pick = LabScheduler.next(candidates: candidates, sessionRunning: false, agentsInChat: model.agentsInChat, now: now),
              let budget = LabScheduler.budget(settings: pick.settings, usedToday: pick.usedToday),
              let session = try? db.startLabSession(topicId: pick.topic.id, now: now) else { return }
        launching = true
        runningSession = (session, pick.topic, pick.agent)
        runningRunId = nil
        version += 1
        let study = AgentClient.StudyContext(topic: pick.topic, session: session, budgetTokens: budget, allowOpus: pick.settings.allowOpus)
        Task {
            defer { launching = false }
            do {
                let run = try await client.run(prompt: pick.topic.question, agent: pick.agent, brand: nil, model: Self.studyModel, study: study)
                try? db.attachAgentRun(labSessionId: session.id, agentRunId: run.id)
                if runningSession?.session.id == session.id { runningRunId = run.id }
                watchdog(runId: run.id, sessionId: session.id)
            } catch {
                closeFailed(session)
            }
        }
    }

    private func watchdog(runId: String, sessionId: String) {
        Task { [weak self] in
            try? await Task.sleep(for: Self.safetyDeadline)
            guard let self, self.runningSession?.session.id == sessionId else { return }
            await self.client.cancel(runId: runId) // colgada: AgentClient la cierra como fallida
        }
    }

    private func closeFailed(_ session: LabSession) {
        _ = try? db.finishLabSession(id: session.id, status: .failed, outcome: nil, summary: nil, conclusion: nil,
                                     tokens: 0, models: [], now: Date())
        if runningSession?.session.id == session.id { runningSession = nil; runningRunId = nil }
        version += 1
    }

    // MARK: Updates del cliente

    /// `true` si la actualización pertenece a un run de estudio (el chat y las tareas no deben verla).
    func handle(_ update: AgentUpdate) -> Bool {
        switch update {
        case .event(let runId, _, _), .notify(let runId, _, _):
            return isStudyRun(runId)
        case .finished(let run):
            guard isStudyRun(run.id) else { return false }
            finishStudy()
            return true
        default:
            return false
        }
    }

    private func isStudyRun(_ runId: String) -> Bool {
        guard let current = runningSession else { return false }
        if let known = runningRunId { return known == runId }
        return (try? db.labSession(id: current.session.id))?.agentRunId == runId
    }

    private func finishStudy() {
        guard let current = runningSession else { return }
        runningSession = nil
        runningRunId = nil
        version += 1
        reloadDatasets()
        model?.reloadSkills()
        notifyNewProposals(agent: current.agent, since: current.session.startedAt)
    }

    private func notifyNewProposals(agent: Agent, since: Date) {
        for p in versions.pendingProposals(agentId: agent.id) where p.createdAt >= since {
            let evidence = p.evidenceSummary.count > 200 ? String(p.evidenceSummary.prefix(200)) + "…" : p.evidenceSummary
            model?.deliverNotification(title: "\(agent.name) quiere graduar «\(p.skillName)»", body: evidence,
                                       conversationId: nil, agentLab: agent.id)
        }
    }

    // MARK: Consultas

    func topics(agentId: String) -> [LabTopic] {
        _ = version
        return (try? db.topics(agentId: agentId)) ?? []
    }

    func entries(topicId: String) -> [LabEntry] {
        _ = version
        return (try? db.entries(topicId: topicId)) ?? []
    }

    func sessions(topicId: String) -> [LabSession] {
        _ = version
        return (try? db.labSessions(topicId: topicId)) ?? []
    }

    func usage(agentId: String) -> (today: Int, month: Int) {
        _ = version
        let cal = Calendar.current
        let now = Date()
        let today = (try? db.labTokensUsed(agentId: agentId, day: now)) ?? 0
        let start = cal.dateInterval(of: .month, for: now)
        let month = start.flatMap { try? db.labTokensUsed(agentId: agentId, from: $0.start, to: $0.end) } ?? 0
        return (today, month)
    }

    func settings(agentId: String) -> AgentLabSettings {
        _ = version
        return (try? db.labSettings(agentId: agentId)) ?? .defaults(agentId: agentId)
    }

    func save(_ settings: AgentLabSettings) {
        change { try db.saveLabSettings(settings) }
    }

    // MARK: Temas

    func openTopic(agentId: String, question: String, why: String) {
        change { _ = try db.openTopic(agentId: agentId, question: question, why: why, origin: .user, now: Date()) }
    }

    func studyNow(_ topic: LabTopic) { change { _ = try db.studyNow(topicId: topic.id, now: Date()) } }
    func pause(_ topic: LabTopic) { change { _ = try db.setTopicStatus(id: topic.id, .paused, reason: "Pausado por ti", now: Date()) } }
    func resume(_ topic: LabTopic) { change { _ = try db.setTopicStatus(id: topic.id, .studying, reason: nil, now: Date()) } }
    func abandon(_ topic: LabTopic) { change { _ = try db.setTopicStatus(id: topic.id, .abandoned, reason: nil, now: Date()) } }

    /// Cancelar es decisión del usuario: la sesión queda `cut` (no cuenta como fallo) antes de parar el run.
    func cancelRunning() {
        guard let current = runningSession else { return }
        _ = try? db.finishLabSession(id: current.session.id, status: .cut, outcome: nil, summary: nil, conclusion: nil,
                                     tokens: 0, models: [], now: Date())
        version += 1
        if let runId = runningRunId ?? (try? db.labSession(id: current.session.id))?.agentRunId {
            Task { await client.cancel(runId: runId) }
        }
    }

    // MARK: Propuestas

    func pendingProposals(agentId: String) -> [SkillProposal] {
        _ = version
        return versions.pendingProposals(agentId: agentId)
    }

    func approve(_ proposal: SkillProposal) {
        change { _ = try versions.approve(proposalId: proposal.id) }
        model?.reloadSkills()
    }

    func reject(_ proposal: SkillProposal, comment: String?) {
        change { try versions.reject(proposalId: proposal.id, comment: comment) }
    }

    // MARK: Datasets

    func reloadDatasets() { datasets = (try? datasetStore.list()) ?? datasets }

    func importDataset(folder: URL, name: String, description: String) {
        change { _ = try datasetStore.importFolder(folder, name: name, description: description) }
        reloadDatasets()
    }

    func deleteDataset(_ meta: DatasetMeta) {
        change { try datasetStore.delete(name: meta.name) }
        reloadDatasets()
    }

    private func change(_ work: () throws -> Void) {
        do { try work() } catch let e as ValidationError { model?.errorMessage = e.message } catch { model?.errorMessage = error.localizedDescription }
        version += 1
    }
}
