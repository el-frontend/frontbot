import SwiftUI
import AppKit
import FrontbotCore

/// Respuesta del agente en Markdown: títulos, listas, citas, tablas y bloques de código copiables.
struct MarkdownView: View {
    let text: String
    var color: Color = Color(hex: 0xDCDCE0)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(MarkdownBlocks.parse(text).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .foregroundStyle(color)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case let .heading(level, text):
            Inline(text: text)
                .font(.system(size: level == 1 ? 20 : level == 2 ? 17 : 15, weight: .semibold))
                .foregroundStyle(Theme.text)
                .padding(.top, level <= 2 ? 6 : 2)
        case let .paragraph(text):
            Inline(text: text).lineSpacing(4)
        case let .list(_, items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(item.marker)
                            .font(item.marker.hasSuffix(".") ? Theme.mono(12) : .system(size: 13))
                            .foregroundStyle(item.marker == "☑" ? Theme.approved : Theme.muted)
                            .frame(minWidth: 14, alignment: .trailing)
                        Inline(text: item.text).lineSpacing(4)
                            .strikethrough(item.marker == "☑", color: Theme.muted)
                    }
                    .padding(.leading, CGFloat(item.depth) * 18)
                }
            }
        case let .quote(text):
            Inline(text: text).lineSpacing(4).foregroundStyle(Theme.textSecondary)
                .padding(.leading, 12)
                .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 1).fill(Theme.accent.opacity(0.6)).frame(width: 2) }
        case let .code(language, code):
            CodeBlockView(language: language, code: code)
        case let .table(header, rows):
            TableBlock(header: header, rows: rows)
        case .rule:
            Theme.border.frame(height: 1).padding(.vertical, 4)
        }
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
            if run.link != nil {
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
