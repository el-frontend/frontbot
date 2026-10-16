import Foundation
import GRDB

private func notFound(_ entity: String, _ id: String) -> ValidationError {
    ValidationError("No existe \(entity) con id \(id).")
}

extension AppDatabase {
    // MARK: Brands
    public func createBrand(workspaceId: String, name: String, industry: String, networks: [Network]) throws -> Brand {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ValidationError("La marca necesita un nombre.") }
        let brand = Brand(id: UUID().uuidString, workspaceId: workspaceId, name: trimmed, industry: industry, networks: networks, createdAt: .dbNow())
        try writer.write { try brand.insert($0) }
        return brand
    }

    public func brands(workspaceId: String) throws -> [Brand] {
        try writer.read { try Brand.filter(Column("workspaceId") == workspaceId).order(Column("name")).fetchAll($0) }
    }

    public func brand(id: String) throws -> Brand? {
        try writer.read { try Brand.fetchOne($0, key: id) }
    }

    /// Borra la marca con sus posts e imágenes (cascade); tareas y conversaciones quedan sin marca.
    /// Los archivos de la marca se borran aparte con `BrandFiles.deleteBrand`.
    public func deleteBrand(id: String) throws {
        try writer.write { db in
            guard let brand = try Brand.fetchOne(db, key: id) else { return }
            let preparing = try Post.filter(Column("brandId") == id && Column("status") == PostStatus.preparing.rawValue).fetchCount(db)
            if preparing > 0 {
                throw ValidationError("\(brand.name) tiene un post preparándose en el navegador: termina o cancela antes de borrarla.")
            }
            try brand.delete(db)
        }
    }

    // MARK: Posts
    public func createDraft(brandId: String, network: Network, body: String, media: [String], scheduledFor: Date?) throws -> Post {
        guard let brand = try brand(id: brandId) else { throw notFound("marca", brandId) }
        guard brand.networks.contains(network) else {
            throw ValidationError("La marca \(brand.name) no tiene \(network.rawValue) configurado.")
        }
        try PostRules.validate(body: body, network: network)
        let now = Date.dbNow()
        var post = Post(id: UUID().uuidString, brandId: brandId, network: network, body: body, media: [],
                        status: .draft, scheduledFor: scheduledFor, publishedUrl: nil, createdAt: now, updatedAt: now)
        try writer.write { db in
            try post.insert(db)
            try apply(to: &post, body: nil, media: media, scheduledFor: nil, db: db)
        }
        return post
    }

    public func updateDraft(id: String, body: String?, media: [String]?, scheduledFor: Date?) throws -> Post {
        try writer.write { db in
            guard var post = try Post.fetchOne(db, key: id) else { throw notFound("post", id) }
            guard post.status == .draft else {
                throw ValidationError("Solo se pueden editar posts en borrador; este está en \(post.status.rawValue).")
            }
            try apply(to: &post, body: body, media: media, scheduledFor: scheduledFor.map { .some($0) }, db: db)
            return post
        }
    }

    public static let maxMediaPerPost = 10

    /// Valida y guarda los cambios dentro de la transacción que ya leyó el post (sin lecturas anidadas).
    private func apply(to post: inout Post, body: String?, media: [String]?, scheduledFor: Date??, db: Database) throws {
        if let body {
            try PostRules.validate(body: body, network: post.network)
            post.body = body
        }
        if let media {
            guard media.count <= Self.maxMediaPerPost else { throw ValidationError("Un post admite máximo 10 imágenes.") }
            for assetId in media {
                guard let asset = try BrandAsset.fetchOne(db, key: assetId), asset.brandId == post.brandId,
                      asset.kind == AssetKind.image.rawValue else {
                    throw ValidationError("La imagen \(assetId) no pertenece a esta marca.")
                }
            }
            post.media = media
        }
        if let scheduledFor { post.scheduledFor = scheduledFor }
        post.updatedAt = .dbNow()
        try post.update(db)
    }

    public func updatePostByUser(id: String, body: String?, media: [String]?, scheduledFor: Date??) throws -> Post {
        try writer.write { db in
            guard var post = try Post.fetchOne(db, key: id) else { throw notFound("post", id) }
            guard post.status == .draft || post.status == .approved else {
                throw ValidationError("Este post ya no se puede editar (\(post.status.rawValue)).")
            }
            try apply(to: &post, body: body, media: media, scheduledFor: scheduledFor, db: db)
            return post
        }
    }

    public func markPublished(id: String, url: String?) throws -> Post {
        let trimmed = url?.trimmingCharacters(in: .whitespacesAndNewlines)
        let clean = (trimmed?.isEmpty ?? true) ? nil : trimmed
        if let clean, !(clean.hasPrefix("https://") || clean.hasPrefix("http://")) {
            throw ValidationError("La URL debe empezar con https://.")
        }
        return try writer.write { db in
            guard var post = try Post.fetchOne(db, key: id) else { throw notFound("post", id) }
            try PostStateMachine.checkTransition(from: post.status, to: .published, actor: .user)
            post.status = .published
            post.publishedUrl = clean
            post.updatedAt = .dbNow()
            try post.update(db)
            return post
        }
    }

    public func transitionPost(id: String, to status: PostStatus, actor: Actor) throws -> Post {
        try writer.write { db in
            guard var post = try Post.fetchOne(db, key: id) else { throw notFound("post", id) }
            try PostStateMachine.checkTransition(from: post.status, to: status, actor: actor)
            post.status = status
            post.updatedAt = .dbNow()
            try post.update(db)
            return post
        }
    }

    public func posts(brandId: String?, status: PostStatus?) throws -> [Post] {
        try writer.read { db in
            var request = Post.all()
            if let brandId { request = request.filter(Column("brandId") == brandId) }
            if let status { request = request.filter(Column("status") == status.rawValue) }
            return try request.order(Column("scheduledFor"), Column("createdAt")).fetchAll(db)
        }
    }

    // MARK: Tasks
    public func createTask(workspaceId: String, title: String, dueDate: Date?, brandId: String?) throws -> TaskItem {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ValidationError("La tarea necesita un título.") }
        if let brandId, try brand(id: brandId) == nil { throw notFound("marca", brandId) }
        let task = TaskItem(id: UUID().uuidString, workspaceId: workspaceId, title: trimmed, dueDate: dueDate, done: false, brandId: brandId, createdAt: .dbNow())
        try writer.write { try task.insert($0) }
        return task
    }

    public func tasks(workspaceId: String, on day: Date?) throws -> [TaskItem] {
        try writer.read { db in
            var request = TaskItem.filter(Column("workspaceId") == workspaceId)
            if let day {
                let start = Calendar.current.startOfDay(for: day)
                let end = Calendar.current.date(byAdding: .day, value: 1, to: start)!
                request = request.filter(Column("dueDate") >= start && Column("dueDate") < end)
            }
            return try request.order(Column("done"), Column("dueDate")).fetchAll(db)
        }
    }

    public func completeTask(id: String) throws -> TaskItem {
        try setTaskDone(id: id, done: true)
    }

    public func setTaskDone(id: String, done: Bool) throws -> TaskItem {
        try writer.write { db in
            guard var task = try TaskItem.fetchOne(db, key: id) else { throw notFound("tarea", id) }
            task.done = done
            try task.update(db)
            return task
        }
    }

    public func deleteTask(id: String) throws {
        _ = try writer.write { try TaskItem.deleteOne($0, key: id) }
    }

    // MARK: Ideas
    public func createIdea(workspaceId: String, title: String, summary: String, sources: [String], score: Int) throws -> BusinessIdea {
        guard (1...5).contains(score) else { throw ValidationError("El puntaje debe estar entre 1 y 5; recibido \(score).") }
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ValidationError("La idea necesita un título.") }
        let idea = BusinessIdea(id: UUID().uuidString, workspaceId: workspaceId, title: title, summary: summary, sources: sources, score: score, reportPath: nil, createdAt: .dbNow())
        try writer.write { try idea.insert($0) }
        return idea
    }

    public func ideas(workspaceId: String) throws -> [BusinessIdea] {
        try writer.read { try BusinessIdea.filter(Column("workspaceId") == workspaceId)
            .order(Column("score").desc, Column("createdAt").desc).fetchAll($0) }
    }

    @discardableResult
    public func deleteIdea(id: String) throws -> BusinessIdea? {
        try writer.write { db in
            let idea = try BusinessIdea.fetchOne(db, key: id)
            _ = try BusinessIdea.deleteOne(db, key: id)
            return idea
        }
    }

    public func setIdeaReportPath(id: String, path: String) throws {
        try writer.write { db in
            guard var idea = try BusinessIdea.fetchOne(db, key: id) else { throw notFound("idea", id) }
            idea.reportPath = path
            try idea.update(db)
        }
    }

    // MARK: Runs
    public func startRun(workspaceId: String, brandId: String?, prompt: String) throws -> AgentRun {
        let run = AgentRun(id: UUID().uuidString, workspaceId: workspaceId, brandId: brandId, prompt: prompt, status: .running,
                           resultSummary: nil, inputTokens: 0, outputTokens: 0, costUsd: 0, logPath: nil, createdAt: .dbNow())
        try writer.write { try run.insert($0) }
        return run
    }

    public func finishRun(id: String, status: RunStatus, summary: String?, inputTokens: Int, outputTokens: Int, costUsd: Double) throws -> AgentRun {
        try writer.write { db in
            guard var run = try AgentRun.fetchOne(db, key: id) else { throw notFound("ejecución", id) }
            run.status = status
            run.resultSummary = summary
            run.inputTokens = inputTokens
            run.outputTokens = outputTokens
            run.costUsd = costUsd
            try run.update(db)
            return run
        }
    }

    @discardableResult
    public func failRunningRuns() throws -> Int {
        try writer.write { db in
            try AgentRun.filter(Column("status") == RunStatus.running.rawValue)
                .updateAll(db, Column("status").set(to: RunStatus.failed.rawValue))
        }
    }

    public func runs(workspaceId: String) throws -> [AgentRun] {
        try writer.read { try AgentRun.filter(Column("workspaceId") == workspaceId).order(Column("createdAt").desc).fetchAll($0) }
    }

    // MARK: Agentes

    /// Frontbot, el agente por defecto: lo crea si falta y le asigna las conversaciones sin agente.
    @discardableResult
    public func ensureDefaultAgent(workspaceId: String) throws -> Agent {
        try writer.write { db in
            let agent: Agent
            if let existing = try Agent.filter(Column("workspaceId") == workspaceId && Column("isDefault") == true).fetchOne(db) {
                agent = existing
            } else {
                let now = Date.dbNow()
                agent = Agent(id: UUID().uuidString, workspaceId: workspaceId, name: "Frontbot", icon: "sparkles",
                              description: "Marcas, redes sociales, tareas e ideas de negocio.",
                              instructions: AgentTemplate.frontbotInstructions, model: AgentConfig.defaultModel,
                              browser: false, trading: false, status: .active, isDefault: true, templateId: nil,
                              createdAt: now, updatedAt: now)
                try agent.insert(db)
            }
            try db.execute(sql: "UPDATE conversation SET agentId = ? WHERE agentId IS NULL AND workspaceId = ?",
                           arguments: [agent.id, workspaceId])
            return agent
        }
    }

    public func createAgent(workspaceId: String, draft: AgentDraft, status: AgentStatus) throws -> Agent {
        let clean = try Self.validated(draft)
        let now = Date.dbNow()
        let agent = Agent(id: UUID().uuidString, workspaceId: workspaceId, name: clean.name, icon: clean.icon,
                          description: clean.description, instructions: clean.instructions, model: clean.model,
                          browser: clean.browser, trading: clean.trading, status: status, isDefault: false,
                          templateId: clean.templateId, createdAt: now, updatedAt: now)
        try writer.write { try agent.insert($0) }
        return agent
    }

    public func updateAgent(id: String, draft: AgentDraft) throws -> Agent {
        let clean = try Self.validated(draft)
        return try writer.write { db in
            guard var agent = try Agent.fetchOne(db, key: id) else { throw notFound("agente", id) }
            agent.name = clean.name; agent.icon = clean.icon; agent.description = clean.description
            agent.instructions = clean.instructions; agent.model = clean.model
            agent.browser = clean.browser; agent.trading = clean.trading
            agent.updatedAt = .dbNow()
            try agent.update(db)
            return agent
        }
    }

    /// Solo el usuario activa agentes: ninguna herramienta llama a esto.
    public func activateAgent(id: String) throws -> Agent {
        try writer.write { db in
            guard var agent = try Agent.fetchOne(db, key: id) else { throw notFound("agente", id) }
            agent.status = .active
            agent.updatedAt = .dbNow()
            try agent.update(db)
            return agent
        }
    }

    /// Frontbot primero; luego por nombre.
    public func agents(workspaceId: String) throws -> [Agent] {
        try writer.read {
            try Agent.filter(Column("workspaceId") == workspaceId)
                .order(Column("isDefault").desc, Column("name").collating(.localizedCaseInsensitiveCompare)).fetchAll($0)
        }
    }

    public func agent(id: String) throws -> Agent? {
        try writer.read { try Agent.fetchOne($0, key: id) }
    }

    /// Borra el agente con sus conversaciones (cascade). Frontbot no se borra.
    public func deleteAgent(id: String) throws {
        try writer.write { db in
            guard let agent = try Agent.fetchOne(db, key: id) else { return }
            if agent.isDefault { throw ValidationError("Frontbot no se puede borrar.") }
            let live = try TradeProposal.filter(Column("agentId") == id && ["open", "sending"].contains(Column("status"))).fetchCount(db)
            if live > 0 { throw ValidationError("\(agent.name) tiene trades abiertos: ciérralos antes de borrarlo.") }
            try agent.delete(db)
        }
    }

    static func validated(_ draft: AgentDraft) throws -> AgentDraft {
        var d = draft
        d.name = d.name.trimmingCharacters(in: .whitespacesAndNewlines)
        d.instructions = d.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        d.description = d.description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !d.name.isEmpty else { throw ValidationError("El agente necesita un nombre.") }
        guard d.name.count <= 40 else { throw ValidationError("El nombre del agente admite hasta 40 caracteres.") }
        guard !d.instructions.isEmpty else { throw ValidationError("El agente necesita instrucciones.") }
        guard d.instructions.count <= 20_000 else { throw ValidationError("Las instrucciones admiten hasta 20.000 caracteres.") }
        d.model = AgentModel.resolve(d.model)
        if d.icon.isEmpty { d.icon = "person.crop.circle" }
        return d
    }

    // MARK: Memoria de agentes

    public static let memoryLimit = 50

    /// Guarda una nota; con la memoria llena, se borra la más antigua.
    public func remember(agentId: String, text: String) throws -> (memory: AgentMemory, evictedOldest: Bool) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw ValidationError("La nota está vacía.") }
        guard clean.count <= 500 else { throw ValidationError("Una nota admite hasta 500 caracteres; tiene \(clean.count). Resúmela.") }
        return try writer.write { db in
            guard try Agent.fetchOne(db, key: agentId) != nil else { throw notFound("agente", agentId) }
            var memory = AgentMemory(id: nil, agentId: agentId, text: clean, createdAt: .dbNow())
            try memory.insert(db)
            let count = try AgentMemory.filter(Column("agentId") == agentId).fetchCount(db)
            let evicted = count > Self.memoryLimit
            if evicted {
                try db.execute(sql: """
                    DELETE FROM agentMemory WHERE id IN
                    (SELECT id FROM agentMemory WHERE agentId = ? ORDER BY id LIMIT ?)
                    """, arguments: [agentId, count - Self.memoryLimit])
            }
            return (memory, evicted)
        }
    }

    /// Las más recientes primero.
    public func memories(agentId: String) throws -> [AgentMemory] {
        try writer.read { try AgentMemory.filter(Column("agentId") == agentId).order(Column("id").desc).fetchAll($0) }
    }

    public func forget(agentId: String, memoryId: Int64) throws {
        try writer.write { db in
            guard let memory = try AgentMemory.fetchOne(db, key: memoryId), memory.agentId == agentId else {
                throw ValidationError("No existe la nota \(memoryId) en tu memoria.")
            }
            _ = try memory.delete(db)
        }
    }

    public func clearMemory(agentId: String) throws {
        _ = try writer.write { try AgentMemory.filter(Column("agentId") == agentId).deleteAll($0) }
    }

    // MARK: Trading

    /// El mandato del agente; si no existe, el conservador por defecto.
    public func mandate(agentId: String) throws -> TradingMandate {
        try writer.write { db in
            if let m = try TradingMandate.fetchOne(db, key: agentId) { return m }
            let m = TradingMandate.default(agentId: agentId)
            try m.insert(db)
            return m
        }
    }

    public func saveMandate(_ mandate: TradingMandate) throws {
        guard mandate.maxRiskPct > 0, mandate.maxRiskPct <= 10 else { throw ValidationError("El riesgo por trade debe estar entre 0 y 10 %.") }
        guard (1...50).contains(mandate.maxLeverage) else { throw ValidationError("El apalancamiento máximo debe estar entre 1x y 50x.") }
        guard (0...50).contains(mandate.maxTradesPerDay) else { throw ValidationError("Los trades por día deben estar entre 0 y 50.") }
        if let address = mandate.address, !address.isEmpty {
            guard address.hasPrefix("0x"), address.count == 42, address.dropFirst(2).allSatisfy(\.isHexDigit) else {
                throw ValidationError("La dirección debe ser una dirección EVM (0x + 40 caracteres hex).")
            }
        }
        var m = mandate
        m.coins = Array(Set(m.coins.map { $0.uppercased().trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })).sorted()
        m.address = m.address?.isEmpty == true ? nil : m.address
        m.updatedAt = .dbNow()
        try writer.write { try m.save($0) }
    }

    /// Botón de pánico: pausa el trading de todos los agentes.
    public func pauseAllTrading() throws {
        try writer.write { try $0.execute(sql: "UPDATE tradingMandate SET paused = 1") }
    }

    public func saveProposal(_ proposal: TradeProposal) throws {
        var p = proposal
        p.updatedAt = .dbNow()
        try writer.write { try p.save($0) }
    }

    public func proposal(id: String) throws -> TradeProposal? {
        try writer.read { try TradeProposal.fetchOne($0, key: id) }
    }

    public func proposals(agentId: String? = nil, limit: Int = 200) throws -> [TradeProposal] {
        try writer.read { db in
            var request = TradeProposal.order(Column("createdAt").desc)
            if let agentId { request = request.filter(Column("agentId") == agentId) }
            return try request.limit(limit).fetchAll(db)
        }
    }

    /// proposed → sending de forma atómica (marca executedAt para contarlo en el día). nil si ya no estaba pendiente.
    public func claimProposal(id: String) throws -> TradeProposal? {
        try writer.write { db in
            guard var p = try TradeProposal.fetchOne(db, key: id), p.status == .proposed else { return nil }
            p.status = .sending
            p.executedAt = .dbNow()
            p.updatedAt = .dbNow()
            try p.update(db)
            return p
        }
    }

    /// sending → proposed si el envío no llegó a salir (falló una validación previa).
    @discardableResult
    public func releaseProposal(id: String) throws -> TradeProposal? {
        try writer.write { db in
            guard var p = try TradeProposal.fetchOne(db, key: id), p.status == .sending else { return nil }
            p.status = .proposed
            p.executedAt = nil
            p.updatedAt = .dbNow()
            try p.update(db)
            return p
        }
    }

    /// Cambio de estado atómico (p. ej. rechazar solo si sigue pendiente).
    public func transitionProposal(id: String, from: TradeStatus, to: TradeStatus) throws -> TradeProposal? {
        try writer.write { db in
            guard var p = try TradeProposal.fetchOne(db, key: id), p.status == from else { return nil }
            p.status = to
            p.updatedAt = .dbNow()
            try p.update(db)
            return p
        }
    }

    /// Propuestas de trade del agente creadas desde `since` (para saber si una tarea programada propuso algo).
    public func proposalsCount(agentId: String, since: Date) throws -> Int {
        try writer.read { try TradeProposal.filter(Column("agentId") == agentId && Column("createdAt") >= since).fetchCount($0) }
    }

    /// Trades enviados hoy (día local) por el agente.
    public func tradesToday(agentId: String, now: Date = Date()) throws -> Int {
        let start = Calendar.current.startOfDay(for: now)
        return try writer.read {
            try TradeProposal.filter(Column("agentId") == agentId && Column("executedAt") >= start).fetchCount($0)
        }
    }

    /// Envíos que quedaron a medias (la app se cerró): se marcan para revisar en Hyperliquid.
    @discardableResult
    public func flagInterruptedSends() throws -> Int {
        try writer.write { db in
            try db.execute(sql: """
                UPDATE tradeProposal SET status = 'failed',
                error = 'La app se cerró mientras se enviaba la orden: revisa tus posiciones en la pestaña Trades o en Hyperliquid.'
                WHERE status = 'sending'
                """)
            return db.changesCount
        }
    }

    // MARK: Tareas programadas

    public func createTask(agentId: String, draft: TaskDraft, status: TaskStatus, createdBy: String?, templateKey: String? = nil,
                           now: Date = Date()) throws -> ScheduledTask {
        let clean = try Self.validated(draft)
        guard let agent = try agent(id: agentId) else { throw notFound("agente", agentId) }
        let stamp = Date.dbNow()
        let task = ScheduledTask(id: UUID().uuidString, agentId: agentId, name: clean.name, instruction: clean.instruction,
                                 schedule: clean.schedule, model: AgentModel.resolve(clean.model ?? agent.model), status: status,
                                 maxRunsPerDay: clean.maxRunsPerDay, lastRunAt: nil,
                                 nextRunAt: status == .active ? clean.schedule.next(after: now) : nil,
                                 createdByAgentId: createdBy, templateKey: templateKey, createdAt: stamp, updatedAt: stamp)
        try writer.write { try task.insert($0) }
        return task
    }

    public func updateTask(id: String, draft: TaskDraft, now: Date = Date()) throws -> ScheduledTask {
        let clean = try Self.validated(draft)
        return try writer.write { db in
            guard var t = try ScheduledTask.fetchOne(db, key: id) else { throw notFound("tarea", id) }
            let scheduleChanged = t.schedule != clean.schedule
            t.name = clean.name; t.instruction = clean.instruction; t.schedule = clean.schedule
            t.model = AgentModel.resolve(clean.model ?? t.model); t.maxRunsPerDay = clean.maxRunsPerDay
            if scheduleChanged && t.status == .active { t.nextRunAt = clean.schedule.next(after: now) }
            t.updatedAt = .dbNow()
            try t.update(db)
            return t
        }
    }

    /// Solo el usuario activa o pausa tareas: ninguna herramienta llama a esto.
    public func setTaskStatus(id: String, _ status: TaskStatus, now: Date = Date()) throws -> ScheduledTask {
        try writer.write { db in
            guard var t = try ScheduledTask.fetchOne(db, key: id) else { throw notFound("tarea", id) }
            t.status = status
            t.nextRunAt = status == .active ? t.schedule.next(after: now) : nil
            t.updatedAt = .dbNow()
            try t.update(db)
            return t
        }
    }

    public func deleteTask(scheduledTaskId id: String) throws {
        _ = try writer.write { try ScheduledTask.deleteOne($0, key: id) }
    }

    public func task(id: String) throws -> ScheduledTask? {
        try writer.read { try ScheduledTask.fetchOne($0, key: id) }
    }

    public func tasks(agentId: String? = nil) throws -> [ScheduledTask] {
        try writer.read { db in
            var r = ScheduledTask.order(Column("status"), Column("nextRunAt"), Column("name"))
            if let agentId { r = r.filter(Column("agentId") == agentId) }
            return try r.fetchAll(db)
        }
    }

    /// Activas, con su hora pasada, agente activo, sin otra ejecución en curso y dentro del límite del día.
    public func dueTasks(now: Date = Date()) throws -> [ScheduledTask] {
        let dayStart = Calendar.current.startOfDay(for: now)
        return try writer.read { db in
            try ScheduledTask.fetchAll(db, sql: """
                SELECT t.* FROM scheduledTask t JOIN agent a ON a.id = t.agentId
                WHERE t.status = 'active' AND a.status = 'active' AND t.nextRunAt IS NOT NULL AND t.nextRunAt <= ?
                  AND NOT EXISTS (SELECT 1 FROM taskRun r WHERE r.taskId = t.id AND r.status = 'running')
                  AND (SELECT COUNT(*) FROM taskRun r WHERE r.taskId = t.id AND r.startedAt >= ?) < t.maxRunsPerDay
                ORDER BY t.nextRunAt
                """, arguments: [now, dayStart])
        }
    }

    /// Empieza una ejecución y fija la próxima desde ahora (lo perdido corre una sola vez).
    public func startTaskRun(taskId: String, now: Date = Date()) throws -> TaskRun {
        try writer.write { db in
            guard var t = try ScheduledTask.fetchOne(db, key: taskId) else { throw notFound("tarea", taskId) }
            t.lastRunAt = now
            t.nextRunAt = t.status == .active ? t.schedule.next(after: now) : t.nextRunAt
            t.updatedAt = .dbNow()
            try t.update(db)
            let run = TaskRun(id: UUID().uuidString, taskId: taskId, agentRunId: nil, status: .running, summary: nil,
                              notified: false, conversationId: nil, costUsd: 0, startedAt: now, finishedAt: nil)
            try run.insert(db)
            return run
        }
    }

    /// Salta esta ejecución (fuera de horario): solo mueve la próxima.
    public func skipTask(id: String, now: Date = Date()) throws {
        try writer.write { db in
            guard var t = try ScheduledTask.fetchOne(db, key: id) else { return }
            t.nextRunAt = t.schedule.next(after: now)
            t.updatedAt = .dbNow()
            try t.update(db)
        }
    }

    public func hasRunningRun(taskId: String) throws -> Bool {
        try writer.read { try TaskRun.filter(Column("taskId") == taskId && Column("status") == "running").fetchCount($0) > 0 }
    }

    public func attachAgentRun(taskRunId: String, agentRunId: String) throws {
        try writer.write { try $0.execute(sql: "UPDATE taskRun SET agentRunId = ? WHERE id = ?", arguments: [agentRunId, taskRunId]) }
    }

    public func finishTaskRun(id: String, status: TaskRunStatus, summary: String?, notified: Bool, conversationId: String?,
                              costUsd: Double, now: Date = Date()) throws {
        try writer.write { db in
            guard var r = try TaskRun.fetchOne(db, key: id) else { return }
            r.status = status; r.summary = summary; r.notified = notified; r.conversationId = conversationId
            r.costUsd = costUsd; r.finishedAt = now
            try r.update(db)
        }
    }

    public func taskRuns(taskId: String, limit: Int = 50) throws -> [TaskRun] {
        try writer.read { try TaskRun.filter(Column("taskId") == taskId).order(Column("startedAt").desc).limit(limit).fetchAll($0) }
    }

    /// Ejecuciones que quedaron "running" de una sesión anterior.
    @discardableResult
    public func failRunningTaskRuns() throws -> Int {
        try writer.write { db in
            try db.execute(sql: "UPDATE taskRun SET status = 'failed', summary = 'La app se cerró durante la ejecución.' WHERE status = 'running'")
            return db.changesCount
        }
    }

    /// Tareas sugeridas por la plantilla del agente (borradores; no se duplican).
    @discardableResult
    public func installTemplateTasks(for agent: Agent, now: Date = Date()) throws -> [ScheduledTask] {
        let existing = Set(try tasks(agentId: agent.id).compactMap(\.templateKey))
        return try TemplateTasks.tasks(for: agent.templateId).filter { !existing.contains($0.key) }.map {
            try createTask(agentId: agent.id, draft: $0.draft, status: .draft, createdBy: nil, templateKey: $0.key, now: now)
        }
    }

    static func validated(_ draft: TaskDraft) throws -> TaskDraft {
        var d = draft
        d.name = d.name.trimmingCharacters(in: .whitespacesAndNewlines)
        d.instruction = d.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !d.name.isEmpty else { throw ValidationError("La tarea necesita un nombre.") }
        guard d.name.count <= 80 else { throw ValidationError("El nombre de la tarea admite hasta 80 caracteres.") }
        guard !d.instruction.isEmpty else { throw ValidationError("La tarea necesita una instrucción.") }
        guard d.instruction.count <= 4_000 else { throw ValidationError("La instrucción admite hasta 4.000 caracteres.") }
        guard (1...96).contains(d.maxRunsPerDay) else { throw ValidationError("El límite diario debe estar entre 1 y 96 ejecuciones.") }
        d.schedule = try d.schedule.validated()
        return d
    }

    // MARK: Conversaciones

    /// Crea una conversación titulada con el primer mensaje (una línea, máximo 60 caracteres).
    public func createConversation(workspaceId: String, agentId: String, brandId: String?, firstPrompt: String) throws -> Conversation {
        let line = firstPrompt.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let title = line.count > 60 ? String(line.prefix(60)) + "…" : line
        let now = Date.dbNow()
        return try writer.write { db in
            let c = Conversation(id: UUID().uuidString, workspaceId: workspaceId, brandId: brandId,
                                 title: title.isEmpty ? "Conversación" : title, createdAt: now, updatedAt: now,
                                 activity: try nextActivity(db), agentId: agentId, summarizedAt: nil, summarizedThrough: 0)
            try c.insert(db)
            return c
        }
    }

    public func appendMessage(conversationId: String, role: ChatRole, text: String) throws {
        try writer.write { db in
            guard var c = try Conversation.fetchOne(db, key: conversationId) else { throw notFound("conversación", conversationId) }
            var message = StoredMessage(id: nil, conversationId: conversationId, role: role, text: text, createdAt: .dbNow())
            try message.insert(db)
            c.updatedAt = message.createdAt
            c.activity = try nextActivity(db)
            try c.update(db)
        }
    }

    /// Las más recientes primero (por última actividad).
    public func conversations(workspaceId: String, limit: Int) throws -> [Conversation] {
        try writer.read {
            try Conversation.filter(Column("workspaceId") == workspaceId)
                .order(Column("activity").desc).limit(limit).fetchAll($0)
        }
    }

    public func messages(conversationId: String) throws -> [StoredMessage] {
        try writer.read { try StoredMessage.filter(Column("conversationId") == conversationId).order(Column("id")).fetchAll($0) }
    }

    /// Hay respuestas del agente posteriores al último resumen (comparando ids de mensaje, no horas).
    public func conversationNeedsSummary(id: String) throws -> Bool {
        try writer.read { db in
            guard let c = try Conversation.fetchOne(db, key: id) else { return false }
            let lastAgent = try Int64.fetchOne(db, sql: "SELECT MAX(id) FROM chatMessage WHERE conversationId = ? AND role = 'agent'", arguments: [id])
            guard let lastAgent else { return false }
            guard c.summarizedAt != nil else { return true }
            return lastAgent > c.summarizedThrough
        }
    }

    public func markSummarized(id: String) throws {
        try writer.write { db in
            guard var c = try Conversation.fetchOne(db, key: id) else { return }
            c.summarizedAt = .dbNow()
            c.summarizedThrough = try Int64.fetchOne(db, sql: "SELECT MAX(id) FROM chatMessage WHERE conversationId = ?", arguments: [id]) ?? 0
            try c.update(db)
        }
    }

    private func nextActivity(_ db: Database) throws -> Int {
        (try Int.fetchOne(db, sql: "SELECT MAX(activity) FROM conversation") ?? 0) + 1
    }

    public func deleteConversation(id: String) throws {
        _ = try writer.write { try Conversation.deleteOne($0, key: id) }
    }

    // MARK: Assets
    public func assets(brandId: String, kind: AssetKind?) throws -> [BrandAsset] {
        try writer.read { db in
            var request = BrandAsset.filter(Column("brandId") == brandId)
            if let kind { request = request.filter(Column("kind") == kind.rawValue) }
            return try request.order(Column("createdAt")).fetchAll(db)
        }
    }

    public func asset(id: String) throws -> BrandAsset? {
        try writer.read { try BrandAsset.fetchOne($0, key: id) }
    }

    func insertAsset(_ asset: BrandAsset) throws {
        try writer.write { try asset.insert($0) }
    }
}
