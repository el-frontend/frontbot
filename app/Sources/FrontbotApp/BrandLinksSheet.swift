import SwiftUI
import FrontbotCore

/// Links de la marca (web, Instagram, LinkedIn…) para que el agente escriba la guía y traiga logo y fotos.
struct BrandLinksSheet: View {
    let model: AppModel
    let brand: Brand
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    private var parsed: BrandLinks.Result { BrandLinks.parse(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Guía desde links").font(.system(size: 16, weight: .semibold))
            Text("Pega uno o más links, uno por línea: tu web, Instagram, LinkedIn, Linktree… Frontbot los lee, escribe la guía y trae tu logo y algunas fotos.")
                .font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text)
                .font(.system(size: 13, design: .monospaced)).scrollContentBackground(.hidden)
                .padding(8).frame(height: 140).panel(radius: 8)
            if !parsed.invalid.isEmpty {
                Text("No son links válidos: \(parsed.invalid.joined(separator: ", ")) (máximo \(BrandLinks.maxLinks), solo webs públicas)")
                    .font(.system(size: 12)).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }.buttonStyle(OutlineButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Leer links") {
                    let links = parsed.links
                    dismiss()
                    model.guideFromLinks(links)
                }
                .buttonStyle(AccentButtonStyle())
                .disabled(parsed.links.isEmpty || !parsed.invalid.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 460)
        .background(Theme.sidebar)
        .onAppear { text = brand.links.joined(separator: "\n") }
    }
}
