import SwiftUI
import FrontbotCore

/// Métricas de un post publicado: lecturas a las 24/48/72 h y a pedido, el link del post y el botón de leer.
struct MetricsSection: View {
    let model: AppModel
    let post: Post
    @State private var link: String

    init(model: AppModel, post: Post) {
        self.model = model
        self.post = post
        _link = State(initialValue: post.publishedUrl ?? "")
    }

    private var meta: PostMetadata { model.postMetadata(postId: post.id) }
    private var reading: Bool { model.metricsReadingPostId == post.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Métricas")
            HStack(spacing: 8) {
                TextField("Link del post", text: $link)
                    .textFieldStyle(.plain).font(.system(size: 12))
                    .padding(.horizontal, 10).frame(height: 30).panel(radius: 8)
                Button("Guardar") { model.setPublishedUrl(post, url: link) }
                    .buttonStyle(OutlineButtonStyle())
                    .disabled(link.trimmingCharacters(in: .whitespaces) == (post.publishedUrl ?? ""))
            }
            if meta.publishedAt == nil {
                Text("Este post se publicó antes de las métricas automáticas: léelas a mano.")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            ForEach(Array(meta.metrics.enumerated()), id: \.offset) { _, r in row(r) }
            ForEach(meta.skipped, id: \.self) { c in
                Text("\(label(c)) · saltada (la app estaba cerrada)").font(.system(size: 11)).foregroundStyle(Theme.muted.opacity(0.7))
            }
            HStack(spacing: 8) {
                if reading {
                    ProgressView().controlSize(.small)
                    Text("Leyendo en Chrome…").font(.system(size: 12)).foregroundStyle(Theme.muted)
                    Button("Detener") { model.cancelMetrics() }.buttonStyle(OutlineButtonStyle())
                } else {
                    Button("Leer métricas") { model.readMetrics(post: post) }
                        .buttonStyle(OutlineButtonStyle(prominent: true))
                        .disabled(!model.canReadMetrics)
                        .help(help)
                }
            }
        }
    }

    private var help: Text {
        if !model.defaultAgentCanReadWeb { return Text("Las métricas se leen con Chrome: elige un agente Claude como agente por defecto") }
        if !model.canReadMetrics { return Text("Espera a que termine lo que está haciendo el agente") }
        return Text("Abre el post en tu Chrome y lee alcance, vistas, likes y reposts")
    }

    private func label(_ c: MetricsCheckpoint) -> String {
        switch c {
        case .h24: "24 h"
        case .h48: "48 h"
        case .h72: "72 h"
        case .manual: String(localized: "Manual")
        }
    }

    private func row(_ r: MetricsReading) -> some View {
        func n(_ v: Int?) -> String { v.map { $0.formatted() } ?? "—" }
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(label(r.checkpoint)).font(Theme.mono()).foregroundStyle(Theme.textSecondary).frame(width: 52, alignment: .leading)
                Text(r.readAt.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
            Text("Alcance \(n(r.reach)) · Vistas \(n(r.views)) · Likes \(n(r.likes)) · Reposts \(n(r.reposts))")
                .font(.system(size: 12))
            if let note = r.note { Text(note).font(.system(size: 11)).foregroundStyle(Theme.muted) }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading).panel(radius: 8)
    }
}
