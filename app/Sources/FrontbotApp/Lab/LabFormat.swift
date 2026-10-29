import SwiftUI
import FrontbotCore

/// Formatos compartidos por las vistas del laboratorio.
enum LabFormat {
    /// 212_000 -> "212k", 1_250_000 -> "1,3M" ("1.3M" con la app en inglés).
    static func tokens(_ n: Int) -> String {
        let separator = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "es").decimalSeparator ?? ","
        func trim(_ v: Double, _ suffix: String) -> String {
            var s = String(format: "%.1f", v).replacingOccurrences(of: ".", with: separator)
            if s.hasSuffix(separator + "0") { s.removeLast(1 + separator.count) }
            return s + suffix
        }
        if n >= 1_000_000 { return trim(Double(n) / 1_000_000, "M") }
        if n >= 1_000 { return trim(Double(n) / 1_000, "k") }
        return "\(n)"
    }

    /// "claude-haiku-4-5" -> "haiku".
    static func modelName(_ id: String) -> String {
        let lower = id.lowercased()
        return ["haiku", "sonnet", "opus"].first { lower.contains($0) } ?? id
    }

    static func sessionStatus(_ s: LabSessionStatus) -> String {
        switch s {
        case .running: String(localized: "en curso")
        case .done: String(localized: "terminada")
        case .failed: String(localized: "fallida")
        case .cut: String(localized: "cortada")
        }
    }
}

/// Píldora pequeña de texto sobre un tono.
struct LabPill: View {
    let text: String
    var color: Color = Theme.muted
    var body: some View {
        Text(text).font(.system(size: 11)).foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.14)))
    }
}
