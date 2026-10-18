import SwiftUI

/// Micrófono del chat: un clic empieza a dictar y otro lo para. Mientras escucha,
/// se pinta del color de acento y unas barras siguen el volumen de la voz.
struct MicButton: View {
    @ObservedObject var dictation: Dictation
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if dictation.state == .listening {
                    LevelBars(level: CGFloat(dictation.level))
                } else {
                    Image(systemName: "mic").font(.system(size: 13, weight: .medium))
                        .opacity(dictation.state == .starting ? 0.5 : 1)
                }
            }
            .foregroundStyle(dictation.state == .listening ? Theme.onAccent : Theme.textSecondary)
            .frame(width: 32, height: 32)
            .background(RoundedRectangle(cornerRadius: 8).fill(dictation.state == .listening ? Theme.accent : Theme.raised))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(dictation.state == .listening ? Color.clear : Theme.borderStrong))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(dictation.state == .listening ? "Dejar de dictar (Esc)" : "Dictar")
        .accessibilityLabel(dictation.state == .listening ? "Dejar de dictar" : "Dictar")
    }
}

/// Cinco barras que suben con el volumen; las del centro más que las de los lados.
private struct LevelBars: View {
    var level: CGFloat
    private let weights: [CGFloat] = [0.45, 0.75, 1, 0.75, 0.45]

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2) {
                ForEach(weights.indices, id: \.self) { i in
                    // Un leve vaivén para que se note vivo aunque estés en silencio.
                    let wobble = (sin(t * 7 + Double(i) * 1.3) + 1) / 2 * 0.15
                    Capsule().frame(width: 2.5, height: 4 + 12 * min(1, level * weights[i] + CGFloat(wobble)))
                }
            }
            .animation(.easeOut(duration: 0.08), value: level)
        }
    }
}
