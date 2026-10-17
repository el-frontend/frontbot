import Foundation
import Observation
import FrontbotCore
import GRDB

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
    @ObservationIgnored private var watchdogTask: Task<Void, Never>?

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
                guard runningSession?.session.id == session.id else { return } // ya terminó y se procesó
                runningRunId = run.id
                // Si el run terminó antes de devolver su id, su `.finished` pudo perderse: la sesión ya no está `running`.
                if (try? db.labSession(id: session.id))?.status != .running { finishStudy(); return }
                watchdog(runId: run.id, sessionId: session.id)
            } catch {
                closeFailed(session)
            }
        }
    }

    private func watchdog(runId: String, sessionId: String) {
        watchdogTask = Task { [weak self] in
            try? await Task.sleep(for: Self.safetyDeadline)
            guard !Task.isCancelled, let self, self.runningSession?.session.id == sessionId else { return }
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
        watchdogTask?.cancel()
        watchdogTask = nil
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

    /// Solo lectura desde la UI: lista y lee los archivos de un tema.
    func workspace(agentId: String, topicId: String) -> LabWorkspace {
        LabWorkspace(paths: paths, db: db, agentId: agentId, topicId: topicId)
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
        let runId = runningRunId ?? (try? db.labSession(id: current.session.id))?.agentRunId
        watchdogTask?.cancel()
        watchdogTask = nil
        runningSession = nil // una `.finished` perdida no puede bloquear el laboratorio
        runningRunId = nil
        version += 1
        if let runId { Task { await client.cancel(runId: runId) } }
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

    /// Archivos de la propuesta frente a los actuales, para el diff.
    func proposalFiles(_ proposal: SkillProposal) -> [(path: String, old: String?, new: String)] {
        versions.proposalFiles(proposal)
    }

    func topic(id: String?) -> LabTopic? {
        guard let id else { return nil }
        return try? db.topic(id: id)
    }

    // MARK: Historial de skills

    func skillVersions(skillId: String) -> [SkillVersion] {
        _ = version
        return versions.versions(skillId: skillId)
    }

    /// Nombre del agente cuya propuesta originó una versión, si la hubo.
    func proposalAgentName(_ proposalId: String?) -> String? {
        guard let proposalId, let p = try? db.writer.read({ try SkillProposal.fetchOne($0, key: proposalId) }) else { return nil }
        return model?.agent(id: p.agentId)?.name
    }

    func revertSkill(_ skillId: String, to number: Int) {
        change { _ = try versions.revert(skillId: skillId, to: number) }
        model?.reloadSkills()
    }

    // MARK: Datasets

    func reloadDatasets() { datasets = (try? datasetStore.list()) ?? datasets }

    /// La copia (hasta 500 MB) corre fuera del hilo principal. Devuelve `true` si se importó.
    func importDataset(folder: URL, name: String, description: String) async -> Bool {
        let store = datasetStore
        var ok = true
        do {
            _ = try await Task.detached { try store.importFolder(folder, name: name, description: description) }.value
        } catch let e as ValidationError {
            model?.errorMessage = e.message; ok = false
        } catch {
            model?.errorMessage = error.localizedDescription; ok = false
        }
        version += 1
        reloadDatasets()
        return ok
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
