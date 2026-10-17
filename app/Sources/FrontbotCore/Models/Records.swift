import Foundation
import GRDB

public struct Workspace: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var createdAt: Date
}

public struct Brand: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable {
    public var id: String
    public var workspaceId: String
    public var name: String
    public var industry: String
    public var networks: [Network]
    public var createdAt: Date

    /// Para borrar una marca hay que escribir su nombre exacto (sin contar espacios de los extremos).
    public func deletionConfirmed(by typed: String) -> Bool {
        typed.trimmingCharacters(in: .whitespacesAndNewlines) == name
    }
}

public struct BrandAsset: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable {
    public var id: String
    public var brandId: String
    public var kind: String
    public var path: String
    public var createdAt: Date
}

public struct Post: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable {
    public var id: String
    public var brandId: String
    public var network: Network
    public var body: String
    public var media: [String]
    public var status: PostStatus
    public var scheduledFor: Date?
    public var publishedUrl: String?
    public var createdAt: Date
    public var updatedAt: Date
}

public struct TaskItem: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable {
    public static let databaseTableName = "task"
    public var id: String
    public var workspaceId: String
    public var title: String
    public var dueDate: Date?
    public var done: Bool
    public var brandId: String?
    public var createdAt: Date
}

public struct BusinessIdea: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable {
    public var id: String
    public var workspaceId: String
    public var title: String
    public var summary: String
    public var sources: [String]
    public var score: Int
    public var reportPath: String?
    public var createdAt: Date
}

public struct AgentRun: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable {
    public var id: String
    public var workspaceId: String
    public var brandId: String?
    public var prompt: String
    public var status: RunStatus
    public var resultSummary: String?
    public var inputTokens: Int
    public var outputTokens: Int
    public var costUsd: Double
    public var logPath: String?
    public var createdAt: Date
}

public struct Conversation: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable {
    public var id: String
    public var workspaceId: String
    public var brandId: String?
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var activity: Int
    /// Agente de la conversación (las anteriores a v3 pasan a Frontbot en `ensureDefaultAgent`).
    public var agentId: String?
    /// Último resumen a memoria; evita resumir dos veces lo mismo.
    public var summarizedAt: Date?
    /// Último mensaje incluido en ese resumen.
    public var summarizedThrough: Int64
}

public struct Agent: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Hashable, Sendable {
    public var id: String
    public var workspaceId: String
    public var name: String
    /// Nombre de un SF Symbol.
    public var icon: String
    public var description: String
    public var instructions: String
    public var model: String
    public var browser: Bool
    public var trading: Bool
    public var status: AgentStatus
    public var isDefault: Bool
    public var templateId: String?
    public var createdAt: Date
    public var updatedAt: Date
}

/// Lo que el usuario (o Frontbot) define de un agente; el resto lo pone el store.
public struct AgentDraft: Equatable, Sendable {
    public var name: String
    public var icon: String
    public var description: String
    public var instructions: String
    public var model: String
    public var browser: Bool
    public var trading: Bool
    public var templateId: String?

    public init(name: String, icon: String = "person.crop.circle", description: String = "", instructions: String,
                model: String = AgentConfig.defaultModel, browser: Bool = false, trading: Bool = false, templateId: String? = nil) {
        self.name = name; self.icon = icon; self.description = description; self.instructions = instructions
        self.model = model; self.browser = browser; self.trading = trading; self.templateId = templateId
    }

    public init(agent: Agent) {
        self.init(name: agent.name, icon: agent.icon, description: agent.description, instructions: agent.instructions,
                  model: agent.model, browser: agent.browser, trading: agent.trading, templateId: agent.templateId)
    }
}

public struct StoredMessage: Codable, FetchableRecord, MutablePersistableRecord, Equatable, Sendable {
    public static let databaseTableName = "chatMessage"
    public var id: Int64?
    public var conversationId: String
    public var role: ChatRole
    public var text: String
    public var createdAt: Date

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// Carpeta del usuario en la que un agente puede leer y (con aprobación) escribir.
public struct AgentFolder: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    public var agentId: String
    public var path: String
    public var createdAt: Date
}

/// Nota de la memoria de un agente.
public struct AgentMemory: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable, Sendable {
    public var id: Int64?
    public var agentId: String
    public var text: String
    public var createdAt: Date

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// Índice de un skill; el contenido vive en su carpeta (`SKILL.md` es la fuente de verdad).
public struct Skill: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var description: String
    public var source: SkillSource
    public var status: SkillStatus
    public var hasScripts: Bool
    public var createdByAgentId: String?
    public var createdAt: Date
    public var updatedAt: Date
}

struct AgentSkill: Codable, FetchableRecord, PersistableRecord {
    var agentId: String
    var skillId: String
}
