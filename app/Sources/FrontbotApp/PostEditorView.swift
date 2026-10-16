import SwiftUI
import FrontbotCore

struct PostEditorView: View {
    let model: AppModel
    let post: Post
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var media: [String]
    @State private var hasDate: Bool
    @State private var date: Date
    @State private var publishedUrl = ""

    init(model: AppModel, post: Post) {
        self.model = model
        self.post = post
        _text = State(initialValue: post.body)
        _media = State(initialValue: post.media)
        _hasDate = State(initialValue: post.scheduledFor != nil)
        _date = State(initialValue: post.scheduledFor ?? Date())
    }

    /// El post actual (no el valor capturado al abrir la hoja): sigue los cambios de estado.
    private var current: Post { model.currentPost(post.id) ?? post }
    private var editable: Bool { current.status == .draft || current.status == .approved }
    /// Cambios sin guardar: se prepararía el texto guardado, no el que se ve.
    private var dirty: Bool {
        text != current.body || media != current.media || (hasDate ? date : nil) != current.scheduledFor
    }
    private var validationError: String? {
        do { try PostRules.validate(body: text, network: post.network); return nil } catch { return error.message }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(model.brand(id: post.brandId)?.name ?? "") · \(post.network.rawValue)").font(.headline)
                Spacer()
                Text(statusLabel).font(.caption).padding(4).background(Capsule().fill(Color.secondary.opacity(0.15)))
            }
            TextEditor(text: $text).frame(minHeight: 200).disabled(!editable)
            HStack {
                Text("\(text.count) / \(PostRules.maxLength(for: post.network))")
                    .font(.caption).foregroundStyle(text.count > PostRules.maxLength(for: post.network) ? .red : .secondary)
                if let validationError { Text(validationError).font(.caption).foregroundStyle(.red) }
            }
            // La alerta de la ventana no se ve mientras la hoja está abierta: errores al guardar van aquí.
            if let error = model.errorMessage { Text(error).font(.caption).foregroundStyle(.red) }

            Text("Imágenes").font(.subheadline).bold()
            ScrollView(.horizontal) {
                HStack {
                    ForEach(model.brandAssets(post.brandId)) { asset in
                        AssetThumbnail(path: asset.path)
                            .overlay(alignment: .topTrailing) {
                                if let i = media.firstIndex(of: asset.id) {
                                    Text("\(i + 1)").font(.caption.bold()).padding(5)
                                        .background(Circle().fill(Color.accentColor)).foregroundStyle(.white).padding(4)
                                }
                            }
                            .onTapGesture {
                                guard editable else { return }
                                if let i = media.firstIndex(of: asset.id) { media.remove(at: i) } else { media.append(asset.id) }
                            }
                    }
                }
            }

            Toggle("Fecha programada", isOn: $hasDate).disabled(!editable)
            if hasDate { DatePicker("", selection: $date).labelsHidden().disabled(!editable) }

            if current.status == .approved {
                Divider()
                Button(model.preparingPostId == post.id ? "Preparando…" : "Preparar publicación en \(post.network == .instagram ? "Instagram" : "LinkedIn")") {
                    model.preparePublication(current)
                }
                .disabled(model.preparingPostId != nil || dirty)
                if dirty { Text("Guarda los cambios antes de preparar la publicación.").font(.caption).foregroundStyle(.secondary) }
            }
            if current.status == .preparing || current.status == .scheduled {
                Divider()
                if let message = model.preparationMessage { Text(message).font(.callout) }
                Text(current.status == .preparing
                     ? "Publica o programa el post en la ventana de Chrome y confírmalo aquí."
                     : "Programado en la red. Confírmalo cuando se publique.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("URL del post publicado (opcional)", text: $publishedUrl)
                HStack {
                    Button("Ya se publicó") { model.confirmPublished(current, url: publishedUrl) }
                    if current.status == .preparing {
                        Button("Lo programé en la red") { model.confirmScheduled(current) }
                        Spacer()
                        Button("Cancelar preparación") { model.cancelPreparation(current) }
                    }
                }
            }
            if current.status == .published, let url = current.publishedUrl, let link = URL(string: url) {
                Link("Ver publicación", destination: link)
            }

            HStack {
                Button("Archivar", role: .destructive) { model.archive(post); dismiss() }.disabled(current.status == .archived)
                Spacer()
                Button("Cerrar") { dismiss() }
                if editable {
                    Button("Guardar") { if save() { dismiss() } }.disabled(validationError != nil)
                }
                if current.status == .draft {
                    Button("Guardar y aprobar") { if save() { model.approve(post); dismiss() } }
                        .keyboardShortcut(.defaultAction).disabled(validationError != nil)
                }
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear { model.errorMessage = nil }
        .onDisappear { model.errorMessage = nil }
    }

    private func save() -> Bool {
        model.updatePost(post, body: text, media: media, scheduledFor: hasDate ? date : nil)
    }

    private var statusLabel: String {
        switch current.status {
        case .draft: "Borrador"
        case .approved: "Aprobado"
        case .preparing: "Preparando"
        case .scheduled: "Programado"
        case .published: "Publicado"
        case .archived: "Archivado"
        }
    }
}
