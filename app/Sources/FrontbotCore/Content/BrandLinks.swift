import Foundation

/// Links que el usuario pega para una marca (web, perfiles, Linktree…): limpios, con esquema y sin repetir.
public enum BrandLinks {
    public static let maxLinks = 10

    public struct Result: Equatable, Sendable {
        public var links: [String] = []
        /// Lo que no es un link http(s) con host, o sobra del máximo; tal como lo escribió el usuario.
        public var invalid: [String] = []
    }

    /// Separa por saltos de línea, espacios y comas. Sin esquema antepone `https://`.
    public static func parse(_ text: String) -> Result {
        var result = Result()
        let pieces = text.components(separatedBy: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",")))
            .filter { !$0.isEmpty }
        for piece in pieces {
            guard let link = normalize(piece) else { result.invalid.append(piece); continue }
            if result.links.contains(link) { continue }
            if result.links.count >= maxLinks { result.invalid.append(piece); continue }
            result.links.append(link)
        }
        return result
    }

    static func normalize(_ raw: String) -> String? {
        let withScheme = raw.range(of: "://") == nil ? "https://" + raw : raw
        guard var parts = URLComponents(string: withScheme), let scheme = parts.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = parts.host, !host.isEmpty else { return nil }
        // "hola" no es un sitio: el host necesita un punto o ser una IP.
        guard host.contains(".") || host.contains(":") else { return nil }
        parts.scheme = scheme
        parts.host = host.lowercased()
        return parts.string
    }
}
