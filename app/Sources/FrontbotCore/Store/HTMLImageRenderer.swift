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
    /// Con el logo incrustado (hasta 8 MB en base64) el documento crece: este es el tope del render.
    static let maxRenderBytes = maxHTMLBytes + AssetImporter.maxImageBytes * 4 / 3 + 1024

    let timeout: Duration

    public init(timeout: Duration = .seconds(15)) {
        self.timeout = timeout
    }

    public func render(html: String, size: ImageSize) async throws -> Data {
        guard html.utf8.count <= Self.maxRenderBytes else {
            throw ValidationError(String(localized: "El diseño pesa más de 512 KB."))
        }
        guard size.width > 0, size.height > 0 else { throw ValidationError("Tamaño de imagen inválido.") }
        let rules = try await Self.blockingRules()
        return try await Self.race(timeout: timeout) { try await Self.snapshot(html: html, size: size, rules: rules) }
    }

    /// El primero en terminar: la operación o el plazo. A diferencia de un task group, no espera a que la
    /// operación atienda la cancelación (una carga de WebKit que nunca avisa no puede colgar la herramienta).
    static func race<T: Sendable>(timeout: Duration, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let gate = RaceGate<T>()
        let work = Task { await gate.settle(Result { try await operation() }) }
        let clock = Task {
            try? await Task.sleep(for: timeout)
            await gate.settle(.failure(ValidationError(String(localized: "El diseño tardó demasiado en renderizarse."))))
        }
        defer { work.cancel(); clock.cancel() }
        return try await withTaskCancellationHandler {
            try await gate.value()
        } onCancel: {
            Task { await gate.settle(.failure(CancellationError())) }
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

/// Guarda el primer resultado y se lo da a quien espera, llegue antes o después.
private actor RaceGate<T: Sendable> {
    private var result: Result<T, Error>?
    private var waiter: CheckedContinuation<T, Error>?

    func settle(_ result: Result<T, Error>) {
        guard self.result == nil else { return }
        self.result = result
        waiter?.resume(with: result)
        waiter = nil
    }

    func value() async throws -> T {
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }
}

/// Espera a que termine la carga del documento (o falle, o la cancelen, o se caiga el proceso web).
@MainActor private final class LoadWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?

    func load(_ start: () -> Void) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                start()
            }
        } onCancel: {
            Task { @MainActor in self.finish(.failure(CancellationError())) }
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(.failure(ValidationError("El render del diseño se interrumpió.")))
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
