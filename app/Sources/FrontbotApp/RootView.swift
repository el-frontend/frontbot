import SwiftUI
import FrontbotCore

struct RootView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView {
            BrandsView(model: model)
        } detail: {
            switch model.section {
            case .agent(let id):
                if let agent = model.agent(id: id) { AgentDetailView(model: model, agent: agent).id(agent.id) }
            case .brand(let id):
                // .id: cada marca tiene su propio estado (si no, el editor de guía de una marca se queda abierto en otra).
                if let brand = model.brand(id: id) { BrandDetailView(model: model, brand: brand).id(brand.id) }
            case .calendar:
                CalendarView(model: model)
            case .chat:
                ChatView(model: model)
            case .tasks:
                TasksView(model: model)
            case .ideas:
                IdeasView(model: model)
            case .skills:
                SkillsView(model: model)
            case .trades:
                TradesView(model: model)
            case .schedules:
                SchedulesView(model: model)
            }
        }
        .frame(minWidth: 1000, minHeight: 640)
        .background(Theme.background)
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        .onAppear { model.openMainWindowAction = { [openWindow] in openWindow(id: AppModel.mainWindowId) } }
        .sheet(item: Binding(get: { model.pendingScript.map(IdentifiedScript.init) }, set: { if $0 == nil { model.answerScript(false) } })) { item in
            ScriptApprovalSheet(model: model, request: item.request)
        }
        .sheet(item: Binding(get: { model.pendingFileWrite.map(IdentifiedFileWrite.init) }, set: { if $0 == nil { model.answerFileWrite(false) } })) { item in
            FileWriteApprovalSheet(model: model, request: item.request)
        }
        .alert("Frontbot", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

private struct IdentifiedScript: Identifiable {
    let request: ScriptRequest
    var id: String { request.agentName + request.skillName + request.command }
}

private struct IdentifiedFileWrite: Identifiable {
    let request: FileWriteRequest
    var id: String { request.agentName + request.path + String(request.content.hashValue) }
}
