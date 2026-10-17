import Foundation
import GRDB

public enum LabTopicStatus: String, Codable, Sendable {
    case studying, paused, resolved, abandoned, graduated
    public var isOpen: Bool { self == .studying || self == .paused }
}

public enum LabOrigin: String, Codable, Sendable { case agent, user }
public enum LabSessionStatus: String, Codable, Sendable { case running, done, failed, cut }
/// Por qué se cortó una sesión: por tokens o por el usuario no es un fallo; por el reloj sí (§7).
public enum LabCutReason: String, Codable, Sendable { case tokens, clock, user }
public enum LabOutcome: String, Codable, Sendable { case `continue`, pause, resolve, abandon }
public enum LabEntryKind: String, Codable, Sendable { case hypothesis, test, result, conclusion, model_note, feedback, note }
public enum Evidence: String, Codable, Sendable { case weak, medium, strong }
public enum SkillProposalKind: String, Codable, Sendable { case new, update }
public enum SkillProposalStatus: String, Codable, Sendable { case pending, approved, rejected }

public struct LabModelUsage: Codable, Equatable, Sendable {
    public var model: String
    public var tokens: Int
    public init(model: String, tokens: Int) { self.model = model; self.tokens = tokens }
}

public struct LabTopic: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable {
    public var id: String
    public var agentId: String
    public var question: String
    public var why: String
    public var origin: LabOrigin
    public var status: LabTopicStatus
    public var conclusion: String?
    public var sessions: Int
    public var tokensUsed: Int
    public var nextSessionAfter: Date?
    public var consecutiveFailures: Int
    public var pausedReason: String?
    public var createdAt: Date
    public var updatedAt: Date
}

public struct LabSession: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable {
    public var id: String
    public var topicId: String
    public var agentRunId: String?
    public var status: LabSessionStatus
    public var tokens: Int
    public var models: [LabModelUsage]
    public var outcome: LabOutcome?
    public var summary: String?
    public var startedAt: Date
    public var finishedAt: Date?
    /// Límite de tokens con que se lanzó: se cobra entero si la sesión termina sin que el sidecar cuente lo gastado.
    public var budgetTokens: Int
}

public struct LabEntry: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable, Sendable {
    public var id: Int64?
    public var topicId: String
    public var sessionId: String?
    public var kind: LabEntryKind
    public var text: String
    public var evidence: Evidence?
    public var sources: [String]
    public var model: String?
    public var createdAt: Date

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct SkillProposal: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable {
    public var id: String
    public var agentId: String
    public var topicId: String?
    public var kind: SkillProposalKind
    public var skillName: String
    public var description: String
    public var body: String
    public var files: [String: String]
    public var evidenceSummary: String
    public var baseVersion: Int?
    /// En `update`: el id del skill propuesto, para no aprobar sobre otro que se llame igual.
    public var skillId: String?
    public var status: SkillProposalStatus
    public var comment: String?
    public var createdAt: Date
    public var decidedAt: Date?
}

public struct SkillVersion: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable {
    public var id: String
    public var skillId: String
    public var number: Int
    public var proposalId: String?
    public var snapshotPath: String
    public var createdAt: Date
}

public struct AgentLabSettings: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    public var agentId: String
    public var sessionTokenCap: Int
    public var dailyTokenCap: Int
    public var maxOpenTopics: Int
    public var enabled: Bool
    public var allowOpus: Bool

    public static func defaults(agentId: String) -> AgentLabSettings {
        AgentLabSettings(agentId: agentId, sessionTokenCap: 150_000, dailyTokenCap: 500_000,
                         maxOpenTopics: 3, enabled: true, allowOpus: false)
    }
}
