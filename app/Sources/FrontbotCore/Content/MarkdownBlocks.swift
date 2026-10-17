import Foundation

/// Bloques de Markdown para pintar las respuestas del agente. El formato en línea (negrita, `código`,
/// enlaces…) queda en el texto: lo resuelve la vista con `AttributedString(markdown:)`.
public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case list(ordered: Bool, items: [ListItem])
    case quote(String)
    /// `language` es nil si la valla no lo indica. Una valla sin cerrar llega hasta el final (respuesta a medias).
    case code(language: String?, code: String)
    case table(header: [String], rows: [[String]])
    case rule

    public struct ListItem: Equatable, Sendable {
        public var text: String
        public var depth: Int
        /// "•", "1.", "☐" o "☑".
        public var marker: String
        public init(text: String, depth: Int, marker: String) {
            self.text = text; self.depth = depth; self.marker = marker
        }
    }
}

public enum MarkdownBlocks {
    public static func parse(_ markdown: String) -> [MarkdownBlock] {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var i = 0

        func flushParagraph() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph = []
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty { flushParagraph(); i += 1; continue }

            if let fence = fence(trimmed) {
                flushParagraph()
                let info = trimmed.dropFirst(fence.count).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[i]); i += 1
                }
                i += 1 // la valla de cierre (si existe)
                let language = info.split(separator: " ").first.map(String.init)
                blocks.append(.code(language: language, code: code.joined(separator: "\n")))
                continue
            }

            if let heading = heading(trimmed) { flushParagraph(); blocks.append(heading); i += 1; continue }

            if isRule(trimmed) { flushParagraph(); blocks.append(.rule); i += 1; continue }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoted: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix(">") else { break }
                    quoted.append(String(t.dropFirst()).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                blocks.append(.quote(quoted.joined(separator: "\n")))
                continue
            }

            if trimmed.hasPrefix("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                flushParagraph()
                let header = cells(trimmed)
                var rows: [[String]] = []
                i += 2
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix("|") else { break }
                    var row = cells(t)
                    row += Array(repeating: "", count: max(0, header.count - row.count))
                    rows.append(Array(row.prefix(header.count)))
                    i += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }

            if let first = listItem(line) {
                flushParagraph()
                var items = [first.item]
                let ordered = first.ordered
                i += 1
                while i < lines.count {
                    let next = lines[i]
                    if let item = listItem(next), item.ordered == ordered || item.item.depth > 0 {
                        items.append(item.item); i += 1
                    } else if !next.trimmingCharacters(in: .whitespaces).isEmpty, next.first == " " || next.first == "\t" {
                        // Línea de continuación del elemento anterior.
                        items[items.count - 1].text += "\n" + next.trimmingCharacters(in: .whitespaces)
                        i += 1
                    } else {
                        break
                    }
                }
                blocks.append(.list(ordered: ordered, items: items))
                continue
            }

            paragraph.append(trimmed)
            i += 1
        }
        flushParagraph()
        return blocks
    }

    private static func fence(_ line: String) -> String? {
        for marker in ["```", "~~~"] where line.hasPrefix(marker) {
            let char = marker.first!
            return String(line.prefix { $0 == char })
        }
        return nil
    }

    private static func heading(_ line: String) -> MarkdownBlock? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.isEmpty || rest.first == " " else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        // "### Título ###": los # de cierre sobran.
        while text.hasSuffix("#") { text.removeLast() }
        return .heading(level: hashes, text: text.trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ line: String) -> Bool {
        let compact = line.filter { $0 != " " }
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-"), t.contains("|") else { return false }
        return t.allSatisfy { "|-: ".contains($0) }
    }

    private static func cells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func listItem(_ line: String) -> (item: MarkdownBlock.ListItem, ordered: Bool)? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let body = line.drop { $0 == " " || $0 == "\t" }
        let depth = indent / 2

        if let bullet = body.first, "-*+".contains(bullet), body.dropFirst().first == " " {
            var text = body.dropFirst(2).trimmingCharacters(in: .whitespaces)
            var marker = "•"
            if text.hasPrefix("[ ] ") || text == "[ ]" { marker = "☐"; text = String(text.dropFirst(3)).trimmingCharacters(in: .whitespaces) }
            else if text.lowercased().hasPrefix("[x] ") || text.lowercased() == "[x]" { marker = "☑"; text = String(text.dropFirst(3)).trimmingCharacters(in: .whitespaces) }
            return (.init(text: text, depth: depth, marker: marker), false)
        }

        let digits = body.prefix { $0.isASCII && $0.isNumber }
        guard (1...9).contains(digits.count) else { return nil }
        let after = body.dropFirst(digits.count)
        guard let punct = after.first, punct == "." || punct == ")", after.dropFirst().first == " " else { return nil }
        let text = after.dropFirst(2).trimmingCharacters(in: .whitespaces)
        return (.init(text: text, depth: depth, marker: "\(digits)."), true)
    }
}
