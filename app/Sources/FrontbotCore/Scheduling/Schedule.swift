import Foundation

public struct TimeOfDay: Codable, Equatable, Hashable, Sendable {
    public var hour: Int
    public var minute: Int
    public init(_ hour: Int, _ minute: Int) { self.hour = hour; self.minute = minute }

    var minutes: Int { hour * 60 + minute }
    public var label: String { String(format: "%02d:%02d", hour, minute) }

    /// "09:30" → 9:30.
    public static func parse(_ text: String) throws -> TimeOfDay {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { throw ValidationError("Hora inválida: \(text). Usa HH:MM.") }
        return TimeOfDay(parts[0], parts[1])
    }
}

/// Horario del día en que una tarea por intervalo puede correr (mismo día: start < end).
public struct TimeWindow: Codable, Equatable, Hashable, Sendable {
    public var start: TimeOfDay
    public var end: TimeOfDay
    public init(start: TimeOfDay, end: TimeOfDay) { self.start = start; self.end = end }
}

/// Frecuencia de una tarea programada. `weekly` usa `Calendar.weekday` (1 = domingo … 7 = sábado).
public enum Schedule: Codable, Equatable, Hashable, Sendable {
    case interval(minutes: Int, window: TimeWindow? = nil)
    case daily(TimeOfDay)
    case weekly(days: [Int], TimeOfDay)

    public static let minimumMinutes = 15
    public static let dayNames = ["dom", "lun", "mar", "mié", "jue", "vie", "sáb"]
    static let dayKeys = ["sun": 1, "mon": 2, "tue": 3, "wed": 4, "thu": 5, "fri": 6, "sat": 7,
                          "dom": 1, "lun": 2, "mar": 3, "mie": 4, "mié": 4, "jue": 5, "vie": 6, "sab": 7, "sáb": 7]

    public func validated() throws -> Schedule {
        func checkTime(_ t: TimeOfDay) throws {
            guard (0...23).contains(t.hour), (0...59).contains(t.minute) else { throw ValidationError("Hora inválida: \(t.label).") }
        }
        switch self {
        case .interval(let minutes, let window):
            guard minutes >= Self.minimumMinutes else { throw ValidationError("El intervalo mínimo es de \(Self.minimumMinutes) minutos.") }
            guard minutes <= 7 * 24 * 60 else { throw ValidationError("El intervalo máximo es de una semana.") }
            if let window {
                try checkTime(window.start); try checkTime(window.end)
                guard window.start.minutes < window.end.minutes else { throw ValidationError("El horario debe empezar antes de terminar (mismo día).") }
            }
        case .daily(let time):
            try checkTime(time)
        case .weekly(let days, let time):
            try checkTime(time)
            guard !days.isEmpty, days.allSatisfy({ (1...7).contains($0) }) else { throw ValidationError("Elige al menos un día de la semana.") }
        }
        return self
    }

    /// Próxima ejecución estrictamente posterior a `after`, en el calendario local.
    public func next(after: Date, calendar: Calendar = .current) -> Date {
        func at(_ day: Date, _ t: TimeOfDay) -> Date {
            calendar.date(bySettingHour: t.hour, minute: t.minute, second: 0, of: day) ?? day
        }
        switch self {
        case .interval(let minutes, let window):
            let candidate = after.addingTimeInterval(TimeInterval(minutes * 60))
            guard let window else { return candidate }
            let startToday = at(candidate, window.start)
            if candidate < startToday { return startToday }
            if candidate <= at(candidate, window.end) { return candidate }
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: candidate)) ?? candidate
            return at(tomorrow, window.start)
        case .daily(let time):
            let today = at(after, time)
            if today > after { return today }
            return at(calendar.date(byAdding: .day, value: 1, to: after) ?? after, time)
        case .weekly(let days, let time):
            for offset in 0...7 {
                guard let day = calendar.date(byAdding: .day, value: offset, to: after) else { continue }
                let candidate = at(day, time)
                if candidate > after, days.contains(calendar.component(.weekday, from: candidate)) { return candidate }
            }
            return after.addingTimeInterval(7 * 86_400)
        }
    }

    /// ¿Puede correr ahora? Solo los intervalos con horario restringen (p. ej. al recuperar lo atrasado de madrugada).
    public func allows(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard case .interval(_, let window?) = self else { return true }
        let c = calendar.dateComponents([.hour, .minute], from: date)
        let minutes = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        return minutes >= window.start.minutes && minutes <= window.end.minutes
    }

    public var summary: String {
        switch self {
        case .interval(let minutes, let window):
            let base = minutes % 60 == 0 ? "cada \(minutes / 60) h" : "cada \(minutes) min"
            return window.map { base + " de \($0.start.label) a \($0.end.label)" } ?? base
        case .daily(let time):
            return "diaria a las \(time.label)"
        case .weekly(let days, let time):
            return days.sorted().map { Self.dayNames[$0 - 1] }.joined(separator: ", ") + " a las \(time.label)"
        }
    }

    /// Lo que mandan los agentes: {kind: interval|daily|weekly, every_minutes, time "HH:MM", days ["mon"…], window {start, end}}.
    public static func parse(_ json: JSONValue) throws -> Schedule {
        guard let kind = json["kind"]?.stringValue else { throw ValidationError("schedule.kind debe ser interval, daily o weekly.") }
        switch kind {
        case "interval":
            guard let minutes = json["every_minutes"]?.intValue else { throw ValidationError("Falta schedule.every_minutes.") }
            var window: TimeWindow?
            if let w = json["window"], let s = w["start"]?.stringValue, let e = w["end"]?.stringValue {
                window = TimeWindow(start: try TimeOfDay.parse(s), end: try TimeOfDay.parse(e))
            }
            return try Schedule.interval(minutes: minutes, window: window).validated()
        case "daily":
            guard let time = json["time"]?.stringValue else { throw ValidationError("Falta schedule.time (HH:MM).") }
            return try Schedule.daily(try TimeOfDay.parse(time)).validated()
        case "weekly":
            guard let time = json["time"]?.stringValue else { throw ValidationError("Falta schedule.time (HH:MM).") }
            let days = try (json["days"]?.arrayValue ?? []).map { v -> Int in
                if let n = v.intValue { return n }
                guard let key = v.stringValue?.lowercased(), let n = dayKeys[key] else { throw ValidationError("Día inválido en schedule.days.") }
                return n
            }
            return try Schedule.weekly(days: Array(Set(days)).sorted(), try TimeOfDay.parse(time)).validated()
        default:
            throw ValidationError("schedule.kind debe ser interval, daily o weekly.")
        }
    }
}
