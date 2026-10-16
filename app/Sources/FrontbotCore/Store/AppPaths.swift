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
    public var database: URL { root.appendingPathComponent("frontbot.sqlite") }
    public func brandDir(_ brandId: String) -> URL { root.appendingPathComponent("brands/\(brandId)", isDirectory: true) }
    public func assetsDir(_ brandId: String) -> URL { brandDir(brandId).appendingPathComponent("assets", isDirectory: true) }
    public func guide(_ brandId: String) -> URL { brandDir(brandId).appendingPathComponent("guide.md") }
    public func ideaReport(_ ideaId: String) -> URL { root.appendingPathComponent("ideas/\(ideaId).md") }
    public func runLog(_ runId: String) -> URL { root.appendingPathComponent("runs/\(runId).log") }
}
