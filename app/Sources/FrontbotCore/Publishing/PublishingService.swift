import Foundation

public struct PreparationResult: Equatable, Sendable {
    public enum Mode: String, Sendable { case composer, manual }
    public let mode: Mode
    public let message: String
    public let url: String

    public init(mode: Mode, message: String, url: String) {
        self.mode = mode
        self.message = message
        self.url = url
    }
}

/// Quien abre el navegador y rellena el compositor (el sidecar vía `AgentClient`).
public protocol PublicationPreparer: Sendable {
    func preparePublication(network: Network, body: String, mediaPaths: [String]) async throws -> PreparationResult
    func openLogin(network: Network) async throws
}

/// Publicación asistida: Frontbot deja el post listo en la red; publicar lo hace siempre el usuario.
public struct PublishingService: Sendable {
    let db: AppDatabase
    let preparer: any PublicationPreparer

    public init(db: AppDatabase, preparer: any PublicationPreparer) {
        self.db = db
        self.preparer = preparer
    }

    public func prepare(postId: String) async throws -> (Post, PreparationResult) {
        guard let post = try db.posts(brandId: nil, status: nil).first(where: { $0.id == postId }) else {
            throw ValidationError("No existe post con id \(postId).")
        }
        guard post.status == .approved else { throw ValidationError("Solo se pueden preparar posts aprobados.") }
        if post.network == .instagram && post.media.isEmpty { throw ValidationError("Instagram necesita al menos una imagen.") }
        let paths = try post.media.map { id -> String in
            guard let asset = try db.asset(id: id) else { throw ValidationError("La imagen \(id) ya no existe.") }
            return asset.path
        }
        let preparing = try db.transitionPost(id: post.id, to: .preparing, actor: .user)
        do {
            let result = try await preparer.preparePublication(network: post.network, body: post.body, mediaPaths: paths)
            return (preparing, result)
        } catch {
            _ = try? db.transitionPost(id: post.id, to: .approved, actor: .user)
            throw error
        }
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
