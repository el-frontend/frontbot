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
