import AppKit
import WebKit

/// Convierte un diseño HTML en PNG.
public protocol HTMLRendering: Sendable {
    func render(html: String, size: ImageSize) async throws -> Data
}

/// Render fuera de pantalla con WebKit, sin JavaScript, sin red y sin archivos: el HTML lo escribe el modelo.
/// Lo único que entra es lo que ya viene dentro del documento (CSS inline y `data:`).
public struct WebKitHTMLRenderer: HTMLRendering {
    public static let maxHTMLBytes = 512 * 1024

    let timeout: Duration

    public init(timeout: Duration = .seconds(15)) {
        self.timeout = timeout
    }

    public func render(html: String, size: ImageSize) async throws -> Data {
        guard html.utf8.count <= Self.maxHTMLBytes else {
            throw ValidationError(String(localized: "El diseño pesa más de 512 KB."))
        }
        guard size.width > 0, size.height > 0 else { throw ValidationError("Tamaño de imagen inválido.") }
        let rules = try await Self.blockingRules()
        let timeout = timeout
        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { try await Self.snapshot(html: html, size: size, rules: rules) }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ValidationError(String(localized: "El diseño tardó demasiado en renderizarse."))
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    /// Bloquea toda carga salvo `data:`. Se compila una vez por proceso.
    @MainActor private static var compiled: WKContentRuleList?

    @MainActor private static func blockingRules() async throws -> WKContentRuleList {
        if let compiled { return compiled }
        let json = """
        [{"trigger":{"url-filter":".*"},"action":{"type":"block"}},
         {"trigger":{"url-filter":"^data:"},"action":{"type":"ignore-previous-rules"}}]
        """
        guard let store = WKContentRuleListStore.default() else { throw ValidationError("WebKit no está disponible.") }
        let list = try await store.compileContentRuleList(forIdentifier: "frontbot-image-offline", encodedContentRuleList: json)
        guard let list else { throw ValidationError("No se pudo preparar el render sin red.") }
        compiled = list
        return list
    }

    @MainActor private static func snapshot(html: String, size: ImageSize, rules: WKContentRuleList) async throws -> Data {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.userContentController.add(rules)
        let frame = NSRect(x: 0, y: 0, width: size.width, height: size.height)
        let webView = WKWebView(frame: frame, configuration: config)
        // Sin ventana WebKit no pinta: una ventana sin mostrar, fuera de pantalla.
        let window = NSWindow(contentRect: frame.offsetBy(dx: -20_000, dy: -20_000), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        defer { webView.stopLoading(); window.contentView = nil; window.close() }

        let loader = LoadWaiter()
        webView.navigationDelegate = loader
        try await loader.load { webView.loadHTMLString(html, baseURL: nil) }
        try Task.checkCancellation()

        let snapshotConfig = WKSnapshotConfiguration()
        snapshotConfig.rect = frame
        snapshotConfig.snapshotWidth = NSNumber(value: size.width)
        let image = try await webView.takeSnapshot(configuration: snapshotConfig)
        return try png(image, size: size)
    }

    /// Redibuja a exactamente width×height píxeles (1x), sea cual sea la escala de la pantalla.
    @MainActor private static func png(_ image: NSImage, size: ImageSize) throws -> Data {
        // En sRGB: los hex de la guía tienen que salir tal cual en el PNG.
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size.width, pixelsHigh: size.height,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)?.retagging(with: .sRGB) else {
            throw ValidationError("No se pudo crear la imagen.")
        }
        rep.size = NSSize(width: size.width, height: size.height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: size.width, height: size.height))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else { throw ValidationError("No se pudo crear la imagen.") }
        return data
    }
}

/// Espera a que termine la carga del documento (o falle).
@MainActor private final class LoadWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?

    func load(_ start: () -> Void) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            start()
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(.success(())) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }
}
