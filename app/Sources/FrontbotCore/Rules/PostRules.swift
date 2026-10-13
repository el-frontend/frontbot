import Foundation

public enum PostRules {
    public static func maxLength(for network: Network) -> Int {
        switch network {
        case .instagram: 2200
        case .linkedin: 3000
        }
    }

    public static let instagramMaxHashtags = 30

    public static func validate(body: String, network: Network) throws(ValidationError) {
        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError("El texto del post está vacío.")
        }
        let count = body.count
        let max = maxLength(for: network)
        if count > max {
            throw ValidationError("El texto de \(network.rawValue) tiene \(count) caracteres; el máximo es \(max).")
        }
        if network == .instagram {
            let hashtags = hashtagCount(in: body)
            if hashtags > instagramMaxHashtags {
                throw ValidationError("Instagram admite máximo \(instagramMaxHashtags) hashtags; el texto tiene \(hashtags).")
            }
        }
    }

    static func hashtagCount(in body: String) -> Int {
        body.split(whereSeparator: \.isWhitespace)
            .filter { $0.hasPrefix("#") && $0.count > 1 }
            .count
    }
}
