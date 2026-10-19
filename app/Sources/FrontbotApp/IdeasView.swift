import SwiftUI
import FrontbotCore

/// Ideas de negocio que guardan los agentes: lista a la izquierda, detalle a la derecha.
struct IdeasView: View {
    @Bindable var model: AppModel
    @State private var selectedId: String?
    @State private var confirmingDelete: BusinessIdea?

    private var selected: BusinessIdea? { model.ideas.first { $0.id == selectedId } ?? model.ideas.first }

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.ideas.isEmpty {
                emptyState
            } else {
                HStack(alignment: .top, spacing: 0) {
                    list.frame(width: 320)
                    Theme.border.frame(width: 1)
                    if let idea = selected {
                        IdeaDetail(model: model, idea: idea) { confirmingDelete = idea }.id(idea.id)
                    }
                }
            }
        }
        .background(Theme.background)
        .confirmationDialog("¿Eliminar «\(confirmingDelete?.title ?? "")»?", isPresented: Binding(
            get: { confirmingDelete != nil }, set: { if !$0 { confirmingDelete = nil } })
        ) {
            Button("Eliminar", role: .destructive) {
                if let idea = confirmingDelete { model.deleteIdea(idea) }
                confirmingDelete = nil
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Ideas").font(.system(size: 17, weight: .semibold))
            Text("\(model.ideas.count) · oportunidades que investigan los agentes").font(Theme.mono()).foregroundStyle(Theme.muted)
            Spacer()
        }
        .padding(.horizontal, 20).frame(height: 56)
        .overlay(alignment: .bottom) { Theme.border.frame(height: 1) }
    }

    private var list: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(model.ideas) { idea in
                    let isSelected = selected?.id == idea.id
                    Button { selectedId = idea.id } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(idea.title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                                Spacer()
                                IdeaScore(score: idea.score)
                            }
                            Text(idea.summary).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(2)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(isSelected ? Theme.selected : .clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu { Button("Eliminar", role: .destructive) { confirmingDelete = idea } }
                }
            }
            .padding(10)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Aún no hay ideas").font(.system(size: 18, weight: .semibold))
            Text("Pídele a un agente: «busca oportunidades de negocio en…». Las ideas que guarde aparecerán aquí con su resumen, fuentes e informe.")
                .foregroundStyle(Theme.muted).lineSpacing(3)
        }
        .padding(28).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct IdeaScore: View {
    let score: Int
    var body: some View {
        let value = min(max(score, 0), 5)
        Text(String(repeating: "★", count: value) + String(repeating: "☆", count: 5 - value))
            .font(.system(size: 10)).foregroundStyle(Theme.draft)
            .help("Puntuación \(value) de 5")
    }
}

private struct IdeaDetail: View {
    @Bindable var model: AppModel
    let idea: BusinessIdea
    var onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text(idea.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                IdeaScore(score: idea.score)
                Text(idea.createdAt.formatted(date: .abbreviated, time: .omitted)).font(.system(size: 12)).foregroundStyle(Theme.muted)
                Spacer()
                Button(action: onDelete) { Image(systemName: "trash") }
                    .buttonStyle(OutlineButtonStyle()).help("Eliminar")
            }
            .padding(.horizontal, 22).padding(.vertical, 14)
            .overlay(alignment: .bottom) { Theme.border.frame(height: 1) }

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(idea.summary).font(.system(size: 13)).foregroundStyle(Theme.textSecondary).lineSpacing(3)
                        .textSelection(.enabled)

                    if !idea.sources.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("FUENTES").font(Theme.mono(10)).foregroundStyle(Theme.muted)
                            ForEach(idea.sources, id: \.self) { source in
                                if let url = URL(string: source), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                                    Link(destination: url) {
                                        Text(source).font(Theme.mono(11)).lineLimit(1).truncationMode(.middle)
                                    }
                                    .foregroundStyle(Theme.inFlight)
                                } else {
                                    Text(source).font(Theme.mono(11)).foregroundStyle(Theme.textSecondary).lineLimit(2)
                                }
                            }
                        }
                    }

                    if let report = model.ideaReport(idea) {
                        Theme.border.frame(height: 1)
                        MarkdownView(text: report).textSelection(.enabled)
                    }
                }
                .padding(22)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
