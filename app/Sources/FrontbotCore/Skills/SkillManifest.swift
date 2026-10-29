import Foundation

/// Frontmatter de un `SKILL.md` (estándar de Anthropic): `name` y `description` obligatorios.
public struct SkillManifest: Equatable, Sendable {
    public let name: String
    public let description: String
    public let body: String

    /// minúsculas, números y guiones; hasta 64 caracteres (como exige el estándar).
    public static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 64 && name.allSatisfy { ($0.isLetter && $0.isLowercase && $0.isASCII) || $0.isNumber || $0 == "-" }
            && !name.hasPrefix("-") && !name.hasSuffix("-")
    }

    public static func parse(_ text: String) throws -> SkillManifest {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            throw ValidationError(String(localized: "SKILL.md debe empezar con un frontmatter entre líneas ---."))
        }
        let fields = parseFields(Array(lines[1..<end]))
        guard let name = fields["name"], isValidName(name) else {
            throw ValidationError(String(localized: "El name del skill debe ser kebab-case (minúsculas, números y guiones; máx. 64)."))
        }
        guard let description = fields["description"], !description.isEmpty else {
            throw ValidationError(String(localized: "El skill \(name) necesita una description."))
        }
        guard description.count <= 1024 else { throw ValidationError(String(localized: "La description admite hasta 1024 caracteres.")) }
        return SkillManifest(name: name, description: description, body: lines[(end + 1)...].joined(separator: "\n"))
    }

    public static func render(name: String, description: String, body: String) -> String {
        let escaped = description.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
        return "---\nname: \(name)\ndescription: \"\(escaped)\"\n---\n\n\(body.trimmingCharacters(in: .whitespacesAndNewlines))\n"
    }

    /// YAML mínimo: `clave: valor`, valores entre comillas y bloques `>` / `|` indentados.
    private static func parseFields(_ lines: [String]) -> [String: String] {
        var fields: [String: String] = [:]
        var i = 0
        while i < lines.count {
            let line = lines[i]
            i += 1
            guard !line.hasPrefix(" "), let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if [">", "|", ">-", "|-"].contains(value) {
                var block: [String] = []
                while i < lines.count, lines[i].hasPrefix(" ") || lines[i].isEmpty {
                    block.append(lines[i].trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                value = block.joined(separator: value.hasPrefix(">") ? " " : "\n").trimmingCharacters(in: .whitespaces)
            } else if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
            } else if value.count >= 2, value.hasPrefix("'"), value.hasSuffix("'") {
                value = String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
            }
            fields[key] = value
        }
        return fields
    }
}
