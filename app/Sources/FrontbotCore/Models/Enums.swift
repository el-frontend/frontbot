import Foundation

public enum Network: String, Codable, CaseIterable, Sendable {
    case instagram, linkedin
}

public enum PostStatus: String, Codable, CaseIterable, Sendable {
    case draft, approved, preparing, scheduled, published, archived
}

public enum Actor: Sendable {
    case user, agent
}

public enum RunStatus: String, Codable, Sendable {
    case running, done, failed
}

public enum ChatRole: String, Codable, Sendable {
    case user, agent, tool, error
}

public struct ValidationError: Error, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
}
