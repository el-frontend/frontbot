import Foundation

/// `tool.images_render_html` y `tool.images_generate`: crean imágenes y las guardan en los assets de la marca.
/// En un run de imagen manda el plan de la app (modo, cuántas, tamaño); en el chat, un tope por corrida.
public actor ImageCreateTool {
    public static let chatMaxHTML = 10
    public static let chatMaxAI = 4

    let importer: AssetImporter
    let renderer: HTMLRendering
    private var provider: @Sendable () -> ImageProvider?
    private var plans: [String: ImageRunPlan] = [:]
    private var used: [String: (html: Int, ai: Int)] = [:]

    public init(importer: AssetImporter, renderer: HTMLRendering, provider: @escaping @Sendable () -> ImageProvider?) {
        self.importer = importer
        self.renderer = renderer
        self.provider = provider
    }

    /// La key de OpenAI puede cambiar en Ajustes sin reiniciar.
    public func setProvider(_ provider: @escaping @Sendable () -> ImageProvider?) {
        self.provider = provider
    }

    public func beginRun(_ runId: String, plan: ImageRunPlan) {
        plans[runId] = plan
    }

    public func endRun(_ runId: String) {
        plans[runId] = nil
        used[runId] = nil
    }

    public func handle(method: String, params: JSONValue) async throws -> JSONValue {
        let kind: ImageKind
        switch method {
        case "tool.images_render_html": kind = .html
        case "tool.images_generate": kind = .ai
        default: throw ValidationError("Herramienta desconocida: \(method)")
        }
        guard let runId = params["run_id"]?.stringValue, let brandId = params["brand_id"]?.stringValue else {
            throw ValidationError("Faltan run_id o brand_id.")
        }
        let content = kind == .html ? params["html"]?.stringValue : params["prompt"]?.stringValue
        guard let content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError(kind == .html ? "Falta html." : "Falta prompt.")
        }
        guard try importer.db.brand(id: brandId) != nil else { throw ValidationError("No existe marca con id \(brandId).") }

        let size = try reserve(runId: runId, kind: kind, network: params["network"]?.stringValue)
        do {
            let data: Data
            switch kind {
            case .html:
                data = try await renderer.render(html: try withLogo(content, brandId: brandId), size: size)
            case .ai:
                guard let provider = provider() else {
                    throw ValidationError(String(localized: "Falta la API key de OpenAI. Agrégala en Ajustes."))
                }
                data = try await provider.generate(prompt: content, size: size)
            }
            // El run terminó o lo paraste mientras se creaba: no se guarda nada.
            try Task.checkCancellation()
            let asset = try importer.importImage(data: data, brandId: brandId, kind: .image)
            return ["asset_id": .string(asset.id)]
        } catch {
            release(runId: runId, kind: kind)
            throw error
        }
    }

    /// Reserva el cupo antes del await (el actor se suelta ahí) y devuelve el tamaño que toca.
    private func reserve(runId: String, kind: ImageKind, network: String?) throws -> ImageSize {
        var count = used[runId] ?? (0, 0)
        let size: ImageSize
        if let plan = plans[runId] {
            guard plan.kind == kind else {
                throw ValidationError(kind == .html
                    ? "En esta corrida se crean fotos con images_generate, no diseños."
                    : "En esta corrida se crean diseños con images_render_html, no fotos.")
            }
            guard count.html + count.ai < plan.count else {
                throw ValidationError("Ya creaste las \(plan.count) imágenes de esta corrida.")
            }
            size = plan.size
        } else if kind == .html {
            guard count.html < Self.chatMaxHTML else { throw ValidationError("Ya creaste \(Self.chatMaxHTML) diseños en esta corrida.") }
            size = .forNetwork(network.flatMap(Network.init(rawValue:)))
        } else {
            guard count.ai < Self.chatMaxAI else { throw ValidationError("Ya generaste \(Self.chatMaxAI) fotos en esta corrida.") }
            size = .ai
        }
        if kind == .html { count.html += 1 } else { count.ai += 1 }
        used[runId] = count
        return size
    }

    private func release(runId: String, kind: ImageKind) {
        guard var count = used[runId] else { return }
        if kind == .html { count.html -= 1 } else { count.ai -= 1 }
        used[runId] = count
    }

    /// `{{logo}}` → el logo de la marca como `data:` (el render no carga archivos ni red); sin logo, vacío.
    private func withLogo(_ html: String, brandId: String) throws -> String {
        guard html.contains("{{logo}}") else { return html }
        var uri = ""
        if let logo = try importer.db.assets(brandId: brandId, kind: .logo).first,
           let data = try? Data(contentsOf: URL(fileURLWithPath: logo.path)) {
            let mime = logo.path.lowercased().hasSuffix(".jpg") ? "image/jpeg" : "image/png"
            uri = "data:\(mime);base64,\(data.base64EncodedString())"
        }
        return html.replacingOccurrences(of: "{{logo}}", with: uri)
    }
}
