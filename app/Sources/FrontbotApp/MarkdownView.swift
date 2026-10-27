import SwiftUI
import AppKit
import FrontbotCore

/// Respuesta del agente en Markdown: títulos, listas, citas, tablas y bloques de código copiables.
struct MarkdownView: View {
    let text: String
    var color: Color = Color(hex: 0xDCDCE0)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(Self.segments(MarkdownBlocks.parse(text)).enumerated()), id: \.offset) { _, segment in
                view(for: segment)
            }
        }
        .foregroundStyle(color)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Tramos que se pintan juntos: el texto corrido va en un solo Text para que la selección
    /// con el cursor cruce títulos, párrafos y listas; código, tablas y separadores van aparte.
    private enum Segment {
        case prose([MarkdownBlock])
        case code(language: String?, code: String)
        case table(header: [String], rows: [[String]])
        case rule
    }

    private static func segments(_ blocks: [MarkdownBlock]) -> [Segment] {
        var result: [Segment] = []
        var prose: [MarkdownBlock] = []
        func flush() { if !prose.isEmpty { result.append(.prose(prose)); prose = [] } }
        for block in blocks {
            switch block {
            case let .code(language, code): flush(); result.append(.code(language: language, code: code))
            case let .table(header, rows): flush(); result.append(.table(header: header, rows: rows))
            case .rule: flush(); result.append(.rule)
            default: prose.append(block)
            }
        }
        flush()
        return result
    }

    @ViewBuilder
    private func view(for segment: Segment) -> some View {
        switch segment {
        case let .prose(blocks):
            Text(Self.prose(blocks)).lineSpacing(4).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        case let .code(language, code):
            CodeBlockView(language: language, code: code)
        case let .table(header, rows):
            TableBlock(header: header, rows: rows)
        case .rule:
            Theme.border.frame(height: 1).padding(.vertical, 4)
        }
    }

    /// Une los bloques de texto en un AttributedString; un salto de línea con letra pequeña hace de espacio entre bloques.
    private static func prose(_ blocks: [MarkdownBlock]) -> AttributedString {
        var out = AttributedString()
        var gap = AttributedString("\n\n")
        gap.font = .system(size: 6)
        for (index, block) in blocks.enumerated() {
            if index > 0 { out += gap }
            switch block {
            case let .heading(level, text):
                var heading = Inline.attributed(text)
                let font = Font.system(size: level == 1 ? 20 : level == 2 ? 17 : 15, weight: .semibold)
                for run in heading.runs where run.font == nil { heading[run.range].font = font }
                heading.foregroundColor = Theme.text
                out += heading
            case let .paragraph(text):
                out += Inline.attributed(text)
            case let .list(_, items):
                for (i, item) in items.enumerated() {
                    if i > 0 { out += AttributedString("\n") }
                    var marker = AttributedString(String(repeating: "    ", count: item.depth) + item.marker + "  ")
                    marker.font = item.marker.hasSuffix(".") ? Theme.mono(12) : .system(size: 13)
                    marker.foregroundColor = item.marker == "☑" ? Theme.approved : Theme.muted
                    var body = Inline.attributed(item.text)
                    if item.marker == "☑" { body.swiftUI.strikethroughStyle = Text.LineStyle(pattern: .solid, color: Theme.muted) }
                    out += marker + body
                }
            case let .quote(text):
                var bar = AttributedString("▎ ")
                bar.foregroundColor = Theme.accent.opacity(0.6)
                var quote = Inline.attributed(text)
                for run in quote.runs where run.foregroundColor == nil { quote[run.range].foregroundColor = Theme.textSecondary }
                out += bar + quote
            case .code, .table, .rule:
                break
            }
        }
        return out
    }
}

/// Texto con formato en línea: **negrita**, *cursiva*, `código`, ~~tachado~~ y enlaces.
private struct Inline: View {
    let text: String

    var body: some View {
        Text(Self.attributed(text)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
    }

    static func attributed(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        guard var result = try? AttributedString(markdown: text, options: options) else { return AttributedString(text) }
        for run in result.runs {
            if run.inlinePresentationIntent?.contains(.code) == true {
                result[run.range].font = Theme.mono(12.5)
                result[run.range].foregroundColor = Theme.accent
                result[run.range].backgroundColor = Theme.raised
            }
            if let link = run.link {
                // El texto puede venir de webs que leyó el agente: solo se abren enlaces web o de correo.
                guard ["http", "https", "mailto"].contains(link.scheme?.lowercased() ?? "") else {
                    result[run.range].link = nil
                    continue
                }
                result[run.range].foregroundColor = Theme.inFlight
                result[run.range].underlineStyle = .single
            }
        }
        return result
    }
}

/// Bloque de código con el lenguaje y un botón para copiarlo.
struct CodeBlockView: View {
    let language: String?
    let code: String
    @State private var copied = false
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(language?.lowercased() ?? "código").font(Theme.mono(11)).foregroundStyle(Theme.muted)
                Spacer()
                Button(action: copy) {
                    Label(copied ? "Copiado" : "Copiar", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11))
                        .foregroundStyle(copied ? Theme.approved : hovering ? Theme.text : Theme.muted)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .help("Copiar el código")
                .accessibilityLabel(copied ? "Código copiado" : "Copiar código")
            }
            .padding(.horizontal, 12).frame(height: 30)
            .background(Theme.raised)
            .overlay(alignment: .bottom) { Theme.border.frame(height: 1) }

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(Theme.mono(12.5)).foregroundStyle(Theme.text).lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize()
                    .padding(12)
            }
        }
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        withAnimation(.easeOut(duration: 0.15)) { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(.easeOut(duration: 0.2)) { copied = false }
        }
    }
}

private struct TableBlock: View {
    let header: [String]
    let rows: [[String]]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                        Inline(text: cell).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.text).cellPadding()
                    }
                }
                .background(Theme.raised)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    Divider().overlay(Theme.border)
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Inline(text: cell).font(.system(size: 12.5)).cellPadding()
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
        }
    }
}

private extension View {
    func cellPadding() -> some View { padding(.horizontal, 12).padding(.vertical, 7) }
}
