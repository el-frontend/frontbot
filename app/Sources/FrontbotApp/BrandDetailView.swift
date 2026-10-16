import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FrontbotCore

struct BrandDetailView: View {
    @Bindable var model: AppModel
    let brand: Brand
    @State private var editingGuide = false
    @State private var guideDraft = ""
    /// Un solo fileImporter: SwiftUI solo respeta el último si hay dos en la misma vista.
    private enum ImportMode { case images, pdf }
    @State private var importMode: ImportMode = .images
    @State private var importing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(brand.name).font(.largeTitle).bold()
                Text([brand.industry, brand.networks.map(\.rawValue).joined(separator: " · ")].filter { !$0.isEmpty }.joined(separator: " — "))
                    .foregroundStyle(.secondary)

                GroupBox("Guía de marca") {
                    VStack(alignment: .leading, spacing: 10) {
                        if editingGuide {
                            TextEditor(text: $guideDraft).font(.body.monospaced()).frame(minHeight: 260)
                            HStack {
                                Button("Cancelar") { editingGuide = false }
                                Spacer()
                                Button("Guardar") { model.saveGuide(guideDraft); editingGuide = false }.keyboardShortcut(.defaultAction)
                            }
                        } else if let guide = model.guide {
                            Text((try? AttributedString(markdown: guide, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(guide))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Text("Esta marca aún no tiene guía.").foregroundStyle(.secondary)
                        }
                        if !editingGuide {
                            HStack {
                                Button("Entrevístame") { model.startInterview() }.disabled(model.isRunning)
                                Button("Desde un PDF…") { importMode = .pdf; importing = true }.disabled(model.isRunning)
                                Button(model.guide == nil ? "Escribirla a mano" : "Editar") {
                                    guideDraft = model.guide ?? ""
                                    editingGuide = true
                                }
                            }
                        }
                    }
                    .padding(8)
                }

                GroupBox("Imágenes") {
                    VStack(alignment: .leading, spacing: 10) {
                        if model.assets.isEmpty {
                            Text("Sube imágenes JPEG o PNG (máx. 8 MB) para usarlas en los posts.").foregroundStyle(.secondary)
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110))], spacing: 10) {
                            ForEach(model.assets) { asset in
                                AssetThumbnail(path: asset.path)
                            }
                        }
                        Button("Subir imágenes…") { importMode = .images; importing = true }
                    }
                    .padding(8)
                }
            }
            .padding(24)
        }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: importMode == .images ? [.jpeg, .png] : [.pdf],
                      allowsMultipleSelection: importMode == .images) { result in
            guard case .success(let urls) = result else { return }
            switch importMode {
            case .images: model.importImages(withAccess(urls))
            case .pdf: if let local = withAccess(urls).first { model.guideFromPDF(local) }
            }
        }
    }

    /// Los archivos del selector pueden requerir acceso con ámbito de seguridad;
    /// se copian a una carpeta temporal para leerlos fuera de ese acceso.
    private func withAccess(_ urls: [URL]) -> [URL] {
        urls.map { url in
            let ok = url.startAccessingSecurityScopedResource()
            defer { if ok { url.stopAccessingSecurityScopedResource() } }
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
            if (try? FileManager.default.copyItem(at: url, to: tmp)) != nil { return tmp }
            return url
        }
    }
}

struct AssetThumbnail: View {
    let path: String

    var body: some View {
        Group {
            if let image = NSImage(contentsOfFile: path) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Color.secondary.opacity(0.2)
            }
        }
        .frame(width: 110, height: 110)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
