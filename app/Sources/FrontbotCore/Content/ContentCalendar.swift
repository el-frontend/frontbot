import Foundation

public enum CalendarScope: Sendable {
    case week, month
}

public struct CalendarDay: Identifiable, Equatable, Sendable {
    public let date: Date
    public let inScope: Bool
    public let posts: [Post]
    public var id: Date { date }
}

/// Agrupa posts por día para las vistas semanal y mensual. Semana de lunes a domingo, hora local.
public struct ContentCalendar: Sendable {
    let calendar: Calendar

    public init(calendar: Calendar = ContentCalendar.defaultCalendar()) {
        self.calendar = calendar
    }

    public static func defaultCalendar() -> Calendar {
        var cal = Calendar.current
        cal.firstWeekday = 2
        return cal
    }

    public func range(_ scope: CalendarScope, containing date: Date) -> DateInterval {
        switch scope {
        case .week:
            return calendar.dateInterval(of: .weekOfYear, for: date)!
        case .month:
            let month = calendar.dateInterval(of: .month, for: date)!
            let start = calendar.dateInterval(of: .weekOfYear, for: month.start)!.start
            let lastDay = calendar.date(byAdding: .second, value: -1, to: month.end)!
            let end = calendar.dateInterval(of: .weekOfYear, for: lastDay)!.end
            return DateInterval(start: start, end: end)
        }
    }

    public func days(_ scope: CalendarScope, containing date: Date, posts: [Post], brandId: String?, network: Network?) -> [CalendarDay] {
        let interval = range(scope, containing: date)
        let month = calendar.dateInterval(of: .month, for: date)!
        let visible = filter(posts, brandId: brandId, network: network)
        var result: [CalendarDay] = []
        var day = interval.start
        while day < interval.end {
            let next = calendar.date(byAdding: .day, value: 1, to: day)!
            let dayPosts = visible
                .filter { p in p.scheduledFor.map { $0 >= day && $0 < next } ?? false }
                .sorted { ($0.scheduledFor ?? .distantPast) < ($1.scheduledFor ?? .distantPast) }
            let inScope = scope == .week || (day >= month.start && day < month.end) // contains() incluye el final
            result.append(CalendarDay(date: day, inScope: inScope, posts: dayPosts))
            day = next
        }
        return result
    }

    public func unscheduled(_ posts: [Post], brandId: String?, network: Network?) -> [Post] {
        filter(posts, brandId: brandId, network: network).filter { $0.scheduledFor == nil }
    }

    public func shift(_ date: Date, scope: CalendarScope, by n: Int) -> Date {
        calendar.date(byAdding: scope == .week ? .weekOfYear : .month, value: n, to: date)!
    }

    private func filter(_ posts: [Post], brandId: String?, network: Network?) -> [Post] {
        posts.filter { p in
            p.status != .archived
                && (brandId == nil || p.brandId == brandId)
                && (network == nil || p.network == network)
        }
    }
}
