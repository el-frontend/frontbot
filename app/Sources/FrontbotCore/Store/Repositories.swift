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

    // MARK: Posts
    public func createDraft(brandId: String, network: Network, body: String, media: [String], scheduledFor: Date?) throws -> Post {
        guard let brand = try brand(id: brandId) else { throw notFound("marca", brandId) }
        guard brand.networks.contains(network) else {
            throw ValidationError("La marca \(brand.name) no tiene \(network.rawValue) configurado.")
        }
        try PostRules.validate(body: body, network: network)
        let now = Date.dbNow()
        let post = Post(id: UUID().uuidString, brandId: brandId, network: network, body: body, media: media,
                        status: .draft, scheduledFor: scheduledFor, publishedUrl: nil, createdAt: now, updatedAt: now)
        try writer.write { try post.insert($0) }
        return post
    }

    public func updateDraft(id: String, body: String?, media: [String]?, scheduledFor: Date?) throws -> Post {
        try writer.write { db in
            guard var post = try Post.fetchOne(db, key: id) else { throw notFound("post", id) }
            guard post.status == .draft else {
                throw ValidationError("Solo se pueden editar posts en borrador; este está en \(post.status.rawValue).")
            }
            if let body {
                try PostRules.validate(body: body, network: post.network)
                post.body = body
            }
            if let media { post.media = media }
            if let scheduledFor { post.scheduledFor = scheduledFor }
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
        try writer.write { db in
            guard var task = try TaskItem.fetchOne(db, key: id) else { throw notFound("tarea", id) }
            task.done = true
            try task.update(db)
            return task
        }
    }

    // MARK: Ideas
    public func createIdea(workspaceId: String, title: String, summary: String, sources: [String], score: Int) throws -> BusinessIdea {
        guard (1...5).contains(score) else { throw ValidationError("El puntaje debe estar entre 1 y 5; recibido \(score).") }
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ValidationError("La idea necesita un título.") }
        let idea = BusinessIdea(id: UUID().uuidString, workspaceId: workspaceId, title: title, summary: summary, sources: sources, score: score, reportPath: nil, createdAt: .dbNow())
        try writer.write { try idea.insert($0) }
        return idea
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
