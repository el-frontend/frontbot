import SwiftUI
import FrontbotCore

/// Panel lateral para editar, aprobar y publicar un post.
struct PostEditorView: View {
    let model: AppModel
    let post: Post
    let close: () -> Void
    @State private var text: String
    @State private var media: [String]
    @State private var hasDate: Bool
    @State private var date: Date
    @State private var publishedUrl = ""

    init(model: AppModel, post: Post, close: @escaping () -> Void) {
        self.model = model
        self.post = post
        self.close = close
        _text = State(initialValue: post.body)
        _media = State(initialValue: post.media)
        _hasDate = State(initialValue: post.scheduledFor != nil)
        _date = State(initialValue: post.scheduledFor ?? Date())
    }

    /// El post actual (no el valor capturado al abrir el panel): sigue los cambios de estado.
    private var current: Post { model.currentPost(post.id) ?? post }
    private var editable: Bool { current.status == .draft || current.status == .approved }
    /// Cambios sin guardar: se prepararía el texto guardado, no el que se ve.
    private var dirty: Bool {
        text != current.body || media != current.media || (hasDate ? date : nil) != current.scheduledFor
    }
    private var validationError: String? {
        do { try PostRules.validate(body: text, network: post.network); return nil } catch { return error.message }
    }
    private var hashtagCount: Int { text.split(whereSeparator: \.isWhitespace).filter { $0.hasPrefix("#") && $0.count > 1 }.count }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    textSection
                    imagesSection
                    dateSection
                    publishingSection
                    if let error = model.errorMessage { Text(error).font(.system(size: 12)).foregroundStyle(Theme.danger) }
                }
                .padding(20)
            }
            footer
        }
        .background(Theme.sidebar)
        .onAppear { model.errorMessage = nil }
        .onDisappear { model.errorMessage = nil }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if let brand = model.brand(id: post.brandId) {
                BrandAvatar(brand: brand, size: 20)
                Text(brand.name).font(.system(size: 13, weight: .semibold))
            }
            Text(Theme.networkName(post.network)).font(Theme.mono()).foregroundStyle(Theme.muted)
            HStack(spacing: 6) {
                StatusDot(color: Theme.statusColor(current.status))
                Text(Theme.statusLabel(current.status))
            }
            .font(.system(size: 11)).foregroundStyle(Theme.statusColor(current.status))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(Theme.statusColor(current.status).opacity(0.12)))
            Spacer()
            CopyButton(help: "Copiar el texto del post") { text }
            Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(Theme.muted)
                .accessibilityLabel("Cerrar").keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20).frame(height: 56)
        .overlay(alignment: .bottom) { Theme.border.frame(height: 1) }
    }

    private var textSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Texto")
            TextEditor(text: $text)
                .font(.system(size: 14)).lineSpacing(3)
                .scrollContentBackground(.hidden)
                .padding(10).frame(minHeight: 180)
                .panel(radius: 10)
                .disabled(!editable)
            HStack {
                Text(post.network == .instagram ? "\(hashtagCount) hashtags · máx. 30" : "LinkedIn")
                Spacer()
                Text("\(text.count) / \(PostRules.maxLength(for: post.network))")
                    .foregroundStyle(text.count > PostRules.maxLength(for: post.network) ? Theme.danger : Theme.muted)
            }
            .font(Theme.mono()).foregroundStyle(Theme.muted)
            if let validationError { Text(validationError).font(.system(size: 12)).foregroundStyle(Theme.danger) }
        }
    }

    private var imagesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Imágenes · toca para elegir el orden")
            let assets = model.brandAssets(post.brandId)
            if assets.isEmpty {
                Text("Esta marca no tiene imágenes todavía. Súbelas desde la página de la marca.")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(assets) { asset in
                        let index = media.firstIndex(of: asset.id)
                        AssetThumbnail(path: asset.path, size: 96)
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(index != nil ? Theme.accent : Theme.borderStrong, lineWidth: index != nil ? 2 : 1))
                            .overlay(alignment: .topTrailing) {
                                if let index {
                                    Text("\(index + 1)").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.onAccent)
                                        .frame(width: 20, height: 20).background(Circle().fill(Theme.accent)).padding(6)
                                }
                            }
                            .onTapGesture {
                                guard editable else { return }
                                if let index { media.remove(at: index) } else { media.append(asset.id) }
                            }
                            .accessibilityLabel(index != nil ? "Imagen \(index! + 1), seleccionada" : "Imagen")
                    }
                }
            }
        }
    }

    private var dateSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Fecha")
            HStack {
                Toggle("Programada", isOn: $hasDate).toggleStyle(.checkbox).disabled(!editable)
                if hasDate { DatePicker("", selection: $date).labelsHidden().disabled(!editable) }
                Spacer()
            }
        }
    }

    @ViewBuilder
    private var publishingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Publicación asistida").font(.system(size: 13, weight: .medium))
            switch current.status {
            case .draft:
                Text("Al aprobarlo podrás prepararlo: Frontbot abre \(Theme.networkName(post.network)) en tu navegador con el texto y las imágenes listos, y tú publicas.")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted).lineSpacing(2)
            case .approved:
                Button("Abrir en \(Theme.networkName(post.network)) para publicar") {
                    model.preparePublication(current)
                }
                .buttonStyle(OutlineButtonStyle(prominent: true))
                .disabled(dirty)
                if dirty { Text("Guarda los cambios antes de preparar la publicación.").font(.system(size: 12)).foregroundStyle(Theme.muted) }
            case .preparing, .scheduled:
                if let message = model.preparationMessage { Text(message).font(.system(size: 12)) }
                Text(current.status == .preparing
                     ? "Publica o programa el post en tu navegador y confírmalo aquí."
                     : "Programado en la red. Confírmalo cuando se publique.")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
                TextField("URL del post publicado (opcional)", text: $publishedUrl)
                    .textFieldStyle(.plain).padding(.horizontal, 10).frame(height: 32).panel(radius: 8)
                HStack {
                    Button("Ya se publicó") { model.confirmPublished(current, url: publishedUrl) }.buttonStyle(OutlineButtonStyle(prominent: true))
                    if current.status == .preparing {
                        Button("Lo programé en la red") { model.confirmScheduled(current) }.buttonStyle(OutlineButtonStyle())
                        Spacer()
                        Button("Cancelar preparación") { model.cancelPreparation(current) }.buttonStyle(OutlineButtonStyle())
                    }
                }
            case .published:
                if let url = current.publishedUrl, let link = URL(string: url) { Link("Ver publicación", destination: link) }
                else { Text("Publicado.").font(.system(size: 12)).foregroundStyle(Theme.muted) }
            case .archived:
                Text("Archivado.").font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(radius: 10, fill: Color(hex: 0x0C0C0E))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Archivar") { model.archive(post); close() }
                .buttonStyle(OutlineButtonStyle()).foregroundStyle(Theme.danger)
                .disabled(current.status == .archived)
            Spacer()
            if editable {
                Button("Guardar") { if save() { close() } }.buttonStyle(OutlineButtonStyle(prominent: true)).disabled(validationError != nil)
            }
            if current.status == .draft {
                Button("Guardar y aprobar") { if save() { model.approve(post); close() } }
                    .buttonStyle(AccentButtonStyle())
                    .keyboardShortcut(.defaultAction).disabled(validationError != nil)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .overlay(alignment: .top) { Theme.border.frame(height: 1) }
    }

    private func save() -> Bool {
        model.updatePost(post, body: text, media: media, scheduledFor: hasDate ? date : nil)
    }
}
