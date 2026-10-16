import SwiftUI
import FrontbotCore

/// Tema oscuro y sobrio de Frontbot (diseño: canvas "Frontbot UI Redesign").
enum Theme {
    static let background = Color(hex: 0x0B0B0C)
    static let sidebar = Color(hex: 0x0F0F11)
    static let surface = Color(hex: 0x111113)
    static let raised = Color(hex: 0x18181B)
    static let selected = Color(hex: 0x1C1C20)
    static let border = Color(hex: 0x232326)
    static let borderStrong = Color(hex: 0x2A2A2E)
    static let text = Color(hex: 0xECECEE)
    static let textSecondary = Color(hex: 0xB4B4BA)
    static let muted = Color(hex: 0x8B8B92)
    static let accent = Color(hex: 0xF2A3C9)
    static let onAccent = Color(hex: 0x1A0F15)
    static let danger = Color(hex: 0xF29AA8)

    static let draft = Color(hex: 0xF5B454)
    static let approved = Color(hex: 0x5FD08A)
    static let inFlight = Color(hex: 0x6AA7FF)
    static let published = Color(hex: 0xB58CFF)

    static func mono(_ size: CGFloat = 11) -> Font { .system(size: size, design: .monospaced) }

    static func statusColor(_ status: PostStatus) -> Color {
        switch status {
        case .draft: draft
        case .approved: approved
        case .preparing, .scheduled: inFlight
        case .published: published
        case .archived: muted
        }
    }

    static func statusLabel(_ status: PostStatus) -> String {
        switch status {
        case .draft: "Borrador"
        case .approved: "Aprobado"
        case .preparing: "Preparando"
        case .scheduled: "Programado"
        case .published: "Publicado"
        case .archived: "Archivado"
        }
    }

    static func networkShort(_ network: Network) -> String { network == .instagram ? "IG" : "in" }
    static func networkName(_ network: Network) -> String { network == .instagram ? "Instagram" : "LinkedIn" }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}

struct StatusDot: View {
    let color: Color
    var size: CGFloat = 6
    var body: some View { Circle().fill(color).frame(width: size, height: size) }
}

/// Iniciales de la marca sobre un tono derivado de su id (estable entre arranques).
struct BrandAvatar: View {
    let brand: Brand
    var size: CGFloat = 18

    private static let tones: [(UInt32, UInt32)] = [
        (0x3A2A1C, 0xF5B454), (0x1C2A3A, 0x6AA7FF), (0x1C3A2A, 0x5FD08A), (0x2E1C3A, 0xB58CFF), (0x3A1C2A, 0xF2A3C9),
    ]

    var body: some View {
        let tone = Self.tones[abs(brand.id.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }) % Self.tones.count]
        Text(initials)
            .font(.system(size: size * 0.55, weight: .semibold))
            .foregroundStyle(Color(hex: tone.1))
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.28).fill(Color(hex: tone.0)))
    }

    private var initials: String {
        let words = brand.name.split(separator: " ").prefix(2)
        return words.map { String($0.prefix(1)) }.joined().uppercased()
    }
}

/// Botón secundario con borde fino.
struct OutlineButtonStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .foregroundStyle(prominent ? Theme.text : Theme.textSecondary)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7).fill(prominent ? Theme.raised : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.borderStrong))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Rectangle())
    }
}

/// Acción principal con el color de acento (o en rojo si borra algo).
struct AccentButtonStyle: ButtonStyle {
    var destructive = false
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(destructive ? Color.white : Theme.onAccent)
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 8).fill(destructive ? Theme.danger : Theme.accent))
            .opacity(!isEnabled ? 0.4 : configuration.isPressed ? 0.8 : 1)
            .contentShape(Rectangle())
    }
}

/// Etiqueta de sección en versalitas pequeñas.
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased()).font(.system(size: 11)).tracking(0.6).foregroundStyle(Theme.muted)
    }
}

extension View {
    /// Caja de superficie con borde fino.
    func panel(radius: CGFloat = 10, fill: Color = Theme.surface) -> some View {
        background(RoundedRectangle(cornerRadius: radius).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(Theme.border))
    }
}

/// Icono del agente (SF Symbol) sobre un tono estable derivado de su id.
struct AgentAvatar: View {
    let agent: Agent
    var size: CGFloat = 18

    private static let tones: [(UInt32, UInt32)] = [
        (0x3A1C2A, 0xF2A3C9), (0x1C2A3A, 0x6AA7FF), (0x1C3A2A, 0x5FD08A), (0x2E1C3A, 0xB58CFF), (0x3A2A1C, 0xF5B454),
    ]

    var body: some View {
        let tone = agent.isDefault ? Self.tones[0] : Self.tones[abs(agent.id.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }) % Self.tones.count]
        Image(systemName: agent.icon)
            .font(.system(size: size * 0.52, weight: .semibold))
            .foregroundStyle(Color(hex: tone.1))
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.28).fill(Color(hex: tone.0)))
            .opacity(agent.status == .draft ? 0.55 : 1)
    }
}
