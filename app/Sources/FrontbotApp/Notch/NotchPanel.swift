import AppKit
import SwiftUI
import FrontbotCore

/// Panel sin bordes que no roba el foco al abrirse, pero acepta teclado para el prompt.
final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class NotchController {
    private let model: AppModel
    private var panel: NotchPanel?

    init(model: AppModel) {
        self.model = model
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout(animated: false) }
        }
    }

    /// La pantalla con notch si hay una; si no, la principal.
    private var screen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.screens.first // la de la barra de menú
    }

    private func geometry(for screen: NSScreen) -> NotchGeometry {
        NotchGeometry(
            screenWidth: screen.frame.width, safeAreaTop: screen.safeAreaInsets.top,
            auxiliaryLeftWidth: screen.auxiliaryTopLeftArea?.width, auxiliaryRightWidth: screen.auxiliaryTopRightArea?.width,
            menuBarHeight: screen.frame.maxY - screen.visibleFrame.maxY)
    }

    func show() {
        if panel == nil {
            let p = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = .statusBar
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.contentView = NSHostingView(rootView: NotchView(model: model, controller: self))
            // Al hacer clic fuera, el panel deja de ser key: se recoge.
            NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: p, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.collapse() }
            }
            panel = p
        }
        layout(animated: false)
        panel?.orderFrontRegardless()
    }

    func toggle() {
        model.notchExpanded.toggle()
        layout(animated: true)
        // Panel no activante: toma el teclado sin activar la app (no trae la ventana principal al frente).
        if model.notchExpanded { panel?.makeKeyAndOrderFront(nil) }
    }

    func collapse() {
        guard model.notchExpanded else { return }
        model.notchExpanded = false
        layout(animated: true)
    }

    private func layout(animated: Bool) {
        guard let panel, let screen else { return }
        let frame = geometry(for: screen).panelFrame(in: screen.frame, expanded: model.notchExpanded)
        panel.setFrame(frame, display: true, animate: animated)
    }
}
