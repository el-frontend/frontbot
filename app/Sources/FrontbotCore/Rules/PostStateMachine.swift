import Foundation

public enum PostStateMachine {
    private static let userTransitions: [PostStatus: Set<PostStatus>] = [
        .draft: [.approved],
        .approved: [.preparing],
        .preparing: [.published, .scheduled, .approved],
        .scheduled: [.published],
        .published: [],
        .archived: [],
    ]

    public static func canTransition(from: PostStatus, to: PostStatus, actor: Actor) -> Bool {
        guard actor == .user else { return false }
        if to == .archived { return from != .archived }
        return userTransitions[from, default: []].contains(to)
    }

    public static func checkTransition(from: PostStatus, to: PostStatus, actor: Actor) throws(ValidationError) {
        guard canTransition(from: from, to: to, actor: actor) else {
            throw ValidationError("No se puede pasar un post de \(from.rawValue) a \(to.rawValue).")
        }
    }
}
