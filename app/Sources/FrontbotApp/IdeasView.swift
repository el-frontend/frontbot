import SwiftUI
import FrontbotCore

struct IdeasView: View {
    @Bindable var model: AppModel
    @State private var selected: String?

    var body: some View {
        HSplitView {
            List(model.ideas, selection: $selected) { idea in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(idea.title).bold()
                        Spacer()
                        Text(String(repeating: "★", count: idea.score)).foregroundStyle(.orange)
                    }
                    Text(idea.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                .tag(idea.id)
                .contextMenu { Button("Eliminar", role: .destructive) { model.deleteIdea(idea) } }
            }
            .frame(minWidth: 260)
            .overlay {
                if model.ideas.isEmpty {
                    Text("Pídele al agente: «busca oportunidades de negocio en…»").foregroundStyle(.secondary).padding()
                }
            }

            ScrollView {
                if let idea = model.ideas.first(where: { $0.id == selected }) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(idea.title).font(.title).bold()
                        Text(idea.summary)
                        if !idea.sources.isEmpty {
                            Text("Fuentes").font(.headline)
                            ForEach(idea.sources, id: \.self) { s in
                                if let url = URL(string: s) { Link(s, destination: url) } else { Text(s) }
                            }
                        }
                        if let report = model.ideaReport(idea) {
                            Divider()
                            Text((try? AttributedString(markdown: report, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(report))
                                .textSelection(.enabled)
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("Elige una idea").foregroundStyle(.secondary).padding()
                }
            }
        }
    }
}
