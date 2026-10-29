import Foundation

public struct PreparationResult: Equatable, Sendable {
    public let message: String
    public let url: URL
}

/// Entrega el post al navegador del usuario: abre la red, copia el texto y muestra las imágenes.
/// La implementación vive en la app (AppKit); los tests usan una falsa.
public protocol PublicationHandoff: Sendable {
    func handOff(url: URL, body: String, mediaPaths: [String]) throws
}

/// URLs de las redes en el navegador del usuario (con sus sesiones).
public enum PublishingLinks {
    public static func homeURL(_ network: Network) -> URL {
        URL(string: network == .instagram ? "https://www.instagram.com/" : "https://www.linkedin.com/feed/")!
    }

    /// LinkedIn abre el compositor con el texto ya escrito (`shareActive`, no documentado: el texto
    /// también va al portapapeles por si deja de funcionar). Instagram no admite nada parecido en la web.
    public static func composeURL(network: Network, body: String) -> URL {
        guard network == .linkedin else { return homeURL(network) }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?/")
        let text = body.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return URL(string: "https://www.linkedin.com/feed/?shareActive=true&text=\(text)")!
    }
}

/// Publicación asistida: Frontbot deja el post listo en el navegador del usuario; publicar lo hace siempre el usuario.
public struct PublishingService: Sendable {
    let db: AppDatabase
    let handoff: any PublicationHandoff

    public init(db: AppDatabase, handoff: any PublicationHandoff) {
        self.db = db
        self.handoff = handoff
    }

    public func prepare(postId: String) throws -> (Post, PreparationResult) {
        guard let post = try db.posts(brandId: nil, status: nil).first(where: { $0.id == postId }) else {
            throw ValidationError(String(localized: "No existe post con id \(postId)."))
        }
        guard post.status == .approved else { throw ValidationError(String(localized: "Solo se pueden preparar posts aprobados.")) }
        if post.network == .instagram && post.media.isEmpty { throw ValidationError(String(localized: "Instagram necesita al menos una imagen.")) }
        let paths = try post.media.map { id -> String in
            guard let asset = try db.asset(id: id) else { throw ValidationError(String(localized: "La imagen \(id) ya no existe.")) }
            return asset.path
        }
        let url = PublishingLinks.composeURL(network: post.network, body: post.body)
        try handoff.handOff(url: url, body: post.body, mediaPaths: paths)
        let preparing = try db.transitionPost(id: post.id, to: .preparing, actor: .user)
        let images = paths.isEmpty ? "" : String(localized: " Las imágenes están seleccionadas en el Finder.")
        let message = post.network == .linkedin
            ? String(localized: "Abrí LinkedIn en tu navegador con el texto escrito (también está en el portapapeles).\(images) Revisa y publica.")
            : String(localized: "Abrí Instagram en tu navegador. El texto está en el portapapeles.\(images) Pulsa Crear, sube las imágenes, pega el texto y publica.")
        return (preparing, PreparationResult(message: message, url: url))
    }

    public func confirmPublished(postId: String, url: String?) throws -> Post {
        try db.markPublished(id: postId, url: url)
    }

    public func confirmScheduled(postId: String) throws -> Post {
        try db.transitionPost(id: postId, to: .scheduled, actor: .user)
    }

    public func cancelPreparation(postId: String) throws -> Post {
        try db.transitionPost(id: postId, to: .approved, actor: .user)
    }
}
