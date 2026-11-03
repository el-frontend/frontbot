import SwiftUI
import FrontbotCore

/// Casilla "Crear imagen" de la tira de imágenes del post: abre el panel o muestra el progreso.
struct CreateImageTile: View {
    let job: ImageJobs.Job?
    let enabled: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                if let job, job.running {
                    ProgressView().controlSize(.small)
                    Text("Creando \(min(job.done + 1, job.total)) de \(job.total)…").multilineTextAlignment(.center)
                } else {
                    Text(verbatim: "✦")
                    Text("Crear imagen")
                }
            }
            .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            .frame(width: 96, height: 96)
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.borderStrong, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .help(help)
    }
}

/// Panel en línea: modo, carrusel, indicación y Crear. Mientras crea, solo Detener.
struct CreateImagePanel: View {
    let maxCount: Int
    let canUseAI: Bool
    let running: Bool
    let create: (_ kind: ImageKind, _ count: Int, _ indication: String) -> Void
    let stop: () -> Void
    let cancel: () -> Void

    @State private var kind: ImageKind = .html
    @State private var carousel = false
    @State private var count = 5
    @State private var indication = ""

    private var carouselMax: Int { min(10, maxCount) }
    private var total: Int { carousel ? min(max(count, 2), carouselMax) : 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $kind) {
                Text("Diseño (HTML)").tag(ImageKind.html)
                Text("Foto con IA").tag(ImageKind.ai)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .disabled(running)
            if !canUseAI {
                Text("Agrega tu API key de OpenAI en Ajustes para crear fotos con IA.")
                    .font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
            HStack(spacing: 10) {
                Toggle("Carrusel", isOn: $carousel).toggleStyle(.checkbox)
                    .disabled(running || carouselMax < 2)
                    .help(carouselMax < 2 ? Text("No caben más láminas en este post") : Text("Varias láminas, en orden"))
                if carousel {
                    Stepper(value: $count, in: 2...max(2, carouselMax)) {
                        Text("\(total)").font(Theme.mono(12)).frame(minWidth: 20)
                    }
                    .disabled(running)
                    Text("láminas").font(Theme.mono()).foregroundStyle(Theme.muted)
                }
            }
            .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            TextField("Indicación opcional", text: $indication)
                .textFieldStyle(.plain).font(.system(size: 12))
                .padding(.horizontal, 10).frame(height: 30)
                .panel(radius: 8)
                .disabled(running)
            if kind == .ai {
                Text("≈ \(total) imágenes en tu cuenta de OpenAI").font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
            HStack(spacing: 8) {
                Spacer()
                if running {
                    Button("Detener", action: stop).buttonStyle(OutlineButtonStyle())
                } else {
                    Button("Cancelar", action: cancel).buttonStyle(OutlineButtonStyle())
                    Button("Crear") { create(kind, total, indication) }
                        .buttonStyle(AccentButtonStyle())
                        .disabled(maxCount < 1 || (kind == .ai && !canUseAI))
                }
            }
        }
        .padding(14)
        .panel(radius: 10)
        .onAppear {
            count = min(5, max(2, carouselMax))
            if !canUseAI { kind = .html }
        }
        .onChange(of: canUseAI) { _, ok in if !ok { kind = .html } }
    }
}
