import Foundation
import GRDB

public enum TaskBucket: String, CaseIterable, Sendable {
    case overdue = "Atrasadas", today = "Hoy", upcoming = "Próximas", someday = "Sin fecha", done = "Hechas"
}

public enum TaskGrouping {
    public static func bucket(_ t: TaskItem, now: Date, calendar: Calendar) -> TaskBucket {
        if t.done { return .done }
        guard let due = t.dueDate else { return .someday }
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        if due < start { return .overdue }
        if due < end { return .today }
        return .upcoming
    }

    public static func group(_ tasks: [TaskItem], now: Date, calendar: Calendar = .current) -> [(TaskBucket, [TaskItem])] {
        let sorted = tasks.sorted { ($0.dueDate ?? .distantFuture, $0.createdAt) < ($1.dueDate ?? .distantFuture, $1.createdAt) }
        return TaskBucket.allCases.compactMap { bucket in
            let items = sorted.filter { self.bucket($0, now: now, calendar: calendar) == bucket }
            return items.isEmpty ? nil : (bucket, items)
        }
    }
}

/// Lo que muestra el notch: tareas de hoy (y atrasadas) y posts pendientes.
public struct TodaySummary: Equatable, Sendable {
    public let tasks: [TaskItem]
    public let draftsToReview: Int
    public let readyToPublish: Int
    public let postsToday: [Post]
}

extension AppDatabase {
    public func todaySummary(workspaceId: String, now: Date = Date(), calendar: Calendar = .current) throws -> TodaySummary {
        let tasks = try writer.read { try TaskItem.filter(Column("workspaceId") == workspaceId && Column("done") == false).fetchAll($0) }
            .filter { [.overdue, .today].contains(TaskGrouping.bucket($0, now: now, calendar: calendar)) }
            .sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
        let brandIds = Set(try brands(workspaceId: workspaceId).map(\.id))
        let posts = try posts(brandId: nil, status: nil).filter { brandIds.contains($0.brandId) }
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        let active: Set<PostStatus> = [.draft, .approved, .preparing, .scheduled]
        let today = posts
            .filter { p in active.contains(p.status) && (p.scheduledFor.map { $0 >= start && $0 < end } ?? false) }
            .sorted { $0.scheduledFor! < $1.scheduledFor! }
        return TodaySummary(
            tasks: tasks,
            draftsToReview: posts.filter { $0.status == .draft }.count,
            readyToPublish: posts.filter { $0.status == .approved }.count,
            postsToday: today)
    }
}
