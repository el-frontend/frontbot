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
    @State private var confirmingDelete = false

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(alignment: .top, spacing: 0) {
                guideSection.frame(maxWidth: .infinity)
                Theme.border.frame(width: 1)
                imagesSection.frame(width: 420)
            }
        }
        .background(Theme.background)
        .sheet(isPresented: $confirmingDelete) { DeleteBrandSheet(model: model, brand: brand) }
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

    private var header: some View {
        HStack(spacing: 14) {
            BrandAvatar(brand: brand, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(brand.name).font(.system(size: 22, weight: .semibold))
                Text(([brand.industry] + brand.networks.map(Theme.networkName)).filter { !$0.isEmpty }.joined(separator: " · "))
                    .foregroundStyle(Theme.muted)
            }
            Spacer()
            Button { confirmingDelete = true } label: { Image(systemName: "trash") }
                .buttonStyle(OutlineButtonStyle()).help("Borrar marca").accessibilityLabel("Borrar marca")
            Button("Pedir contenido para esta marca") {
                model.selectedBrandId = brand.id
                model.section = .chat
            }
            .buttonStyle(OutlineButtonStyle(prominent: true))
        }
        .padding(.horizontal, 28).padding(.top, 22).padding(.bottom, 18)
        .overlay(alignment: .bottom) { Theme.border.frame(height: 1) }
    }

    private var guideSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text("Guía de marca").font(.system(size: 14, weight: .semibold))
                Text("guide.md").font(Theme.mono()).foregroundStyle(Theme.muted)
                Spacer()
                if !editingGuide {
                    Button("Entrevístame") { model.startInterview() }.buttonStyle(OutlineButtonStyle()).disabled(model.isRunning)
                    Button("Desde un PDF") { importMode = .pdf; importing = true }.buttonStyle(OutlineButtonStyle()).disabled(model.isRunning)
                    Button(model.guide == nil ? String(localized: "Escribirla") : String(localized: "Editar")) {
                        guideDraft = model.guide ?? ""
                        editingGuide = true
                    }
                    .buttonStyle(OutlineButtonStyle(prominent: true))
                }
            }
            if editingGuide {
                TextEditor(text: $guideDraft)
                    .font(.system(size: 13, design: .monospaced)).scrollContentBackground(.hidden)
                    .padding(12).panel(radius: 12)
                HStack {
                    Spacer()
                    Button("Cancelar") { editingGuide = false }.buttonStyle(OutlineButtonStyle())
                    Button("Guardar guía") { model.saveGuide(guideDraft); editingGuide = false }
                        .buttonStyle(AccentButtonStyle()).keyboardShortcut(.defaultAction)
                }
            } else {
                ScrollView {
                    Group {
                        if let guide = model.guide {
                            GuideText(markdown: guide)
                        } else {
                            Text("Esta marca aún no tiene guía. Pídele a Frontbot que te entreviste, súbela en PDF o escríbela tú.")
                                .foregroundStyle(Theme.muted)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 22).padding(.vertical, 20)
                }
                .panel(radius: 12, fill: Theme.sidebar)
            }
        }
        .padding(.horizontal, 28).padding(.vertical, 22)
    }

    private var imagesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text("Imágenes").font(.system(size: 14, weight: .semibold))
                Text("\(model.assets.count) · JPEG/PNG ≤ 8 MB").font(Theme.mono()).foregroundStyle(Theme.muted)
                Spacer()
                Button("Subir imágenes") { importMode = .images; importing = true }.buttonStyle(OutlineButtonStyle(prominent: true))
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 10)], spacing: 10) {
                    ForEach(model.assets) { asset in AssetThumbnail(path: asset.path, size: 112) }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Redes").font(.system(size: 13, weight: .medium))
                Text("Se abren en tu navegador, con tu sesión.")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
                HStack {
                    ForEach(brand.networks, id: \.self) { network in
                        Button("Abrir \(Theme.networkName(network))") { model.openNetwork(network) }.buttonStyle(OutlineButtonStyle())
                    }
                }
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading).panel(radius: 10, fill: Color.clear)
        }
        .padding(.horizontal, 24).padding(.vertical, 22)
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

/// Markdown de la guía con títulos (`##`) como encabezados y el resto como párrafos.
struct GuideText: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(markdown.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("#") {
                    Text(trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces))
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text).padding(.top, 4)
                } else if !trimmed.isEmpty {
                    Text((try? AttributedString(markdown: trimmed)) ?? AttributedString(trimmed))
                        .foregroundStyle(Color(hex: 0xD4D4D8)).lineSpacing(4).textSelection(.enabled)
                }
            }
        }
    }
}

struct AssetThumbnail: View {
    let path: String
    var size: CGFloat = 110

    var body: some View {
        Group {
            if let image = NSImage(contentsOfFile: path) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Theme.raised
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
