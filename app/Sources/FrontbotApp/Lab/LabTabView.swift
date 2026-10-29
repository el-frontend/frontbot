import SwiftUI
import FrontbotCore

/// Pestaña Laboratorio de un agente: presupuesto, propuestas listas, temas de estudio y lo aprendido.
struct LabTabView: View {
    @Bindable var model: AppModel
    let agent: Agent
    @State private var creating = false
    @State private var notebook: LabTopic?
    @State private var reviewing: SkillProposal?

    var body: some View {
        let lab = model.lab!
        let topics = lab.topics(agentId: agent.id)
        let open = topics.filter { $0.status.isOpen }
        let learned = topics.filter { $0.status == .resolved || $0.status == .graduated }
        let settings = lab.settings(agentId: agent.id)
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                usageHeader(lab.usage(agentId: agent.id), settings: settings)
                let proposals = lab.pendingProposals(agentId: agent.id)
                if !proposals.isEmpty { readySection(proposals, topics: topics) }
                topicsSection(open, settings: settings)
                if !learned.isEmpty { learnedSection(learned) }
                LabSettingsSection(model: model, agent: agent)
            }
            .frame(maxWidth: 820, alignment: .leading)
            .padding(.horizontal, 28).padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $creating) { NewTopicSheet(model: model, agent: agent) }
        .sheet(item: $notebook) { NotebookView(model: model, agent: agent, topic: $0) }
        .sheet(item: $reviewing) { ProposalReviewSheet(model: model, proposal: $0) }
    }

    private func usageHeader(_ usage: (today: Int, month: Int), settings: AgentLabSettings) -> some View {
        let fraction = settings.dailyTokenCap > 0 ? min(1, Double(usage.today) / Double(settings.dailyTokenCap)) : 0
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("hoy \(LabFormat.tokens(usage.today)) / \(LabFormat.tokens(settings.dailyTokenCap)) tokens")
                    .font(Theme.mono(12))
                Spacer()
                Text("este mes \(LabFormat.tokens(usage.month))").font(Theme.mono(12)).foregroundStyle(Theme.muted)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.raised)
                    Capsule().fill(Theme.accent).frame(width: geo.size.width * fraction)
                }
            }
            .frame(height: 6)
        }
        .padding(16).panel(radius: 12)
    }

    private func readySection(_ proposals: [SkillProposal], topics: [LabTopic]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Listo para graduar").font(.system(size: 14, weight: .semibold))
            ForEach(proposals) { p in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text(p.skillName).font(Theme.mono(13))
                        LabPill(text: p.kind == .new ? String(localized: "skill nueva") : String(localized: "mejora de \(p.skillName)"), color: Theme.accent)
                        Spacer()
                    }
                    Text(firstLines(p.evidenceSummary, 2)).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    HStack(spacing: 8) {
                        Button("Revisar y aprobar") { reviewing = p }.buttonStyle(AccentButtonStyle())
                        if let topic = topics.first(where: { $0.id == p.topicId }) {
                            Button("Ver cuaderno") { notebook = topic }.buttonStyle(OutlineButtonStyle())
                        }
                    }
                }
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.accent))
            }
        }
    }

    private func topicsSection(_ open: [LabTopic], settings: AgentLabSettings) -> some View {
        let full = open.count >= settings.maxOpenTopics
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Temas de estudio").font(.system(size: 14, weight: .semibold))
                Text("\(open.count)/\(settings.maxOpenTopics)").font(Theme.mono()).foregroundStyle(Theme.muted)
                Spacer()
                Button("Nuevo tema") { creating = true }
                    .buttonStyle(OutlineButtonStyle(prominent: true)).disabled(full || agent.status != .active)
            }
            if full {
                Text("Ya tienes \(settings.maxOpenTopics) temas abiertos. Abandona o resuelve uno para abrir otro.")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
            } else if open.isEmpty {
                Text("\(agent.name) aún no estudia nada. Abre un tema y trabajará en él por su cuenta, dentro del presupuesto.")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            ForEach(open) { topic in
                LabTopicRow(model: model, topic: topic) { notebook = topic }
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading).panel(radius: 12)
    }

    private func learnedSection(_ learned: [LabTopic]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Aprendido").font(.system(size: 14, weight: .semibold))
            ForEach(learned) { topic in
                Button { notebook = topic } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(topic.question).font(.system(size: 13, weight: .medium)).multilineTextAlignment(.leading)
                        if let c = topic.conclusion {
                            Text(c).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(3).multilineTextAlignment(.leading)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 6)
                .overlay(alignment: .bottom) { Theme.border.frame(height: 1) }
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading).panel(radius: 12)
    }

    private func firstLines(_ text: String, _ n: Int) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: true).prefix(n).joined(separator: "\n")
    }
}
