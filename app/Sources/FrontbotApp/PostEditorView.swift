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

    init(model: AppModel, post: Post) {
        self.model = model
        self.post = post
        _text = State(initialValue: post.body)
        _media = State(initialValue: post.media)
        _hasDate = State(initialValue: post.scheduledFor != nil)
        _date = State(initialValue: post.scheduledFor ?? Date())
    }

    private var editable: Bool { post.status == .draft || post.status == .approved }
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

            HStack {
                Button("Archivar", role: .destructive) { model.archive(post); dismiss() }.disabled(post.status == .archived)
                Spacer()
                Button("Cerrar") { dismiss() }
                if editable {
                    Button("Guardar") { if save() { dismiss() } }.disabled(validationError != nil)
                }
                if post.status == .draft {
                    Button("Guardar y aprobar") { if save() { model.approve(post); dismiss() } }
                        .keyboardShortcut(.defaultAction).disabled(validationError != nil)
                }
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func save() -> Bool {
        model.updatePost(post, body: text, media: media, scheduledFor: hasDate ? date : nil)
    }

    private var statusLabel: String {
        switch post.status {
        case .draft: "Borrador"
        case .approved: "Aprobado"
        case .preparing: "Preparando"
        case .scheduled: "Programado"
        case .published: "Publicado"
        case .archived: "Archivado"
        }
    }
}
