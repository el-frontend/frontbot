import SwiftUI
import AppKit

/// Copia texto al portapapeles y confirma con "Copiado" un par de segundos.
struct CopyButton: View {
    var label = "Copiar"
    var help = "Copiar todo el texto"
    let text: () -> String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text(), forType: .string)
            copied = true
            Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
        } label: {
            Label(copied ? "Copiado" : label, systemImage: copied ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(OutlineButtonStyle())
        .help(help)
    }
}
