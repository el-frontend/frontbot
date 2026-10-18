import SwiftUI
import AppKit

/// Campo de texto del chat. Return envía; ⌘, ⇧ u ⌥ + Return insertan un salto de línea.
/// Crece con el texto hasta `maxLines` y a partir de ahí hace scroll.
struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var focusToken: AnyHashable = 0
    var maxLines = 8
    var onSubmit: () -> Void

    static let font = NSFont.systemFont(ofSize: 14)

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = ComposerNSTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = Self.font
        textView.textColor = NSColor(Theme.text)
        textView.insertionPointColor = NSColor(Theme.accent)
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        // Sin minSize/maxSize el documento no crece en alto y las líneas nuevas quedan fuera de vista.
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.placeholder = placeholder
        textView.string = text

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = textView
        context.coordinator.textView = textView
        DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        if textView.string != text {
            textView.string = text
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            context.coordinator.scrollToCaret()
        }
        if textView.placeholder != placeholder { textView.placeholder = placeholder; textView.needsDisplay = true }
        if context.coordinator.focusToken != focusToken {
            context.coordinator.focusToken = focusToken
            DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        }
    }

    // Mide en un layout aparte: tocar el contenedor real con anchos de prueba de SwiftUI
    // lo dejaba con un ancho menor al del campo y el texto saltaba de línea antes del borde.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        let width = proposal.width ?? 400
        let lineHeight = NSLayoutManager().defaultLineHeight(for: Self.font)
        let used = max(Self.textHeight(text, width: width), lineHeight)
        return CGSize(width: width, height: min(ceil(used), ceil(lineHeight * CGFloat(maxLines))))
    }

    static func textHeight(_ text: String, width: CGFloat) -> CGFloat {
        let storage = NSTextStorage(string: text, attributes: [.font: font])
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        let layout = NSLayoutManager()
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        return layout.usedRect(for: container).height
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        var focusToken: AnyHashable
        weak var textView: ComposerNSTextView?

        init(_ parent: ComposerTextView) { self.parent = parent; self.focusToken = parent.focusToken }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            scrollToCaret()
        }

        /// El alto del campo cambia en el siguiente pase de layout; el cursor se lleva a la vista después.
        func scrollToCaret() {
            DispatchQueue.main.async { [weak self] in
                guard let textView = self?.textView else { return }
                textView.scrollRangeToVisible(textView.selectedRange())
            }
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            if ComposerNSTextView.wantsLineBreak(NSApp.currentEvent) {
                textView.insertNewlineIgnoringFieldEditor(nil)
            } else {
                parent.onSubmit()
            }
            return true
        }
    }
}

final class ComposerNSTextView: NSTextView {
    var placeholder = ""

    static func wantsLineBreak(_ event: NSEvent?) -> Bool {
        guard let event else { return false }
        return !event.modifierFlags.intersection([.command, .shift, .option]).isEmpty
    }

    private static func isReturn(_ event: NSEvent) -> Bool { event.keyCode == 36 || event.keyCode == 76 }

    // ⌘Return llega como atajo de teclado antes que como tecla: se convierte en salto de línea aquí.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, Self.isReturn(event), event.modifierFlags.contains(.command), !hasMarkedText() {
            insertNewlineIgnoringFieldEditor(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: ComposerTextView.font, .foregroundColor: NSColor(Theme.muted)]
        (placeholder as NSString).draw(at: NSPoint(x: textContainerInset.width, y: textContainerInset.height), withAttributes: attributes)
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }
}
