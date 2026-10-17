import Foundation

public struct AppPaths: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    public static func standard() -> AppPaths {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return AppPaths(root: support.appendingPathComponent("Frontbot", isDirectory: true))
    }

    public var skillsDir: URL { root.appendingPathComponent("skills", isDirectory: true) }
    public func skillDir(_ name: String) -> URL { skillsDir.appendingPathComponent(name, isDirectory: true) }
    public var skillsVersionsDir: URL { skillsDir.appendingPathComponent(".versions", isDirectory: true) }
    public func skillVersionsDir(_ name: String) -> URL { skillsVersionsDir.appendingPathComponent(name, isDirectory: true) }
    public var labsDir: URL { root.appendingPathComponent("labs", isDirectory: true) }
    public func labDir(_ agentId: String) -> URL { labsDir.appendingPathComponent(agentId, isDirectory: true) }
    public func labTopicDir(_ agentId: String, _ topicId: String) -> URL {
        labDir(agentId).appendingPathComponent("topics", isDirectory: true).appendingPathComponent(topicId, isDirectory: true)
    }
    public func labSharedDir(_ agentId: String) -> URL { labDir(agentId).appendingPathComponent("shared", isDirectory: true) }
    public var datasetsDir: URL { root.appendingPathComponent("datasets", isDirectory: true) }
    public func datasetDir(_ name: String) -> URL { datasetsDir.appendingPathComponent(name, isDirectory: true) }
    public var labVenvPython: URL { labsDir.appendingPathComponent(".venv/bin/python3") }
    public var database: URL { root.appendingPathComponent("frontbot.sqlite") }
    public func brandDir(_ brandId: String) -> URL { root.appendingPathComponent("brands/\(brandId)", isDirectory: true) }
    public func assetsDir(_ brandId: String) -> URL { brandDir(brandId).appendingPathComponent("assets", isDirectory: true) }
    public func guide(_ brandId: String) -> URL { brandDir(brandId).appendingPathComponent("guide.md") }
    public func ideaReport(_ ideaId: String) -> URL { root.appendingPathComponent("ideas/\(ideaId).md") }
    public func runLog(_ runId: String) -> URL { root.appendingPathComponent("runs/\(runId).log") }
}
