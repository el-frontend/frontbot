import SwiftUI
import FrontbotCore

struct NotchView: View {
    @Bindable var model: AppModel
    let controller: NotchController
    @State private var prompt = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if model.notchExpanded { expanded } else { collapsed }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(UnevenRoundedRectangle(bottomLeadingRadius: 18, bottomTrailingRadius: 18).fill(.black))
        .foregroundStyle(.white)
    }

    /// Colapsado: indicadores a los lados del notch; clic para abrir.
    private var collapsed: some View {
        HStack {
            if let n = model.today?.tasks.count, n > 0 { Label("\(n)", systemImage: "checklist").font(.caption2) }
            Spacer()
            if let n = model.today?.draftsToReview, n > 0 { Label("\(n)", systemImage: "doc.badge.ellipsis").font(.caption2) }
        }
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { controller.toggle() }
    }

    private var expanded: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Pídele algo a Frontbot…", text: $prompt)
                    .textFieldStyle(.plain).focused($focused)
                    .onSubmit { model.send(prompt: prompt); prompt = "" }
                if model.isRunning { ProgressView().controlSize(.small) }
                Button { controller.collapse() } label: { Image(systemName: "chevron.up") }.buttonStyle(.plain)
            }
            .padding(8).background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.1)))

            if let reply = model.lastAgentReply {
                ScrollView { Text(reply).font(.callout).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                    .frame(maxHeight: 110)
            }

            if let today = model.today {
                if !today.tasks.isEmpty {
                    Text("Hoy").font(.caption).foregroundStyle(.white.opacity(0.6))
                    ForEach(today.tasks.prefix(5)) { task in
                        Toggle(isOn: Binding(get: { task.done }, set: { model.setTaskDone(task, done: $0) })) { Text(task.title) }
                            .toggleStyle(.checkbox)
                    }
                }
                HStack {
                    if today.draftsToReview > 0 {
                        Button("\(today.draftsToReview) por revisar") { model.showMainWindow(section: .calendar); controller.collapse() }
                    }
                    if today.readyToPublish > 0 {
                        Button("\(today.readyToPublish) listos para publicar") { model.showMainWindow(section: .calendar); controller.collapse() }
                    }
                    Spacer()
                    Button("Abrir Frontbot") { model.showMainWindow(section: .chat); controller.collapse() }
                }
                .buttonStyle(.link)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 34).padding(.horizontal, 16).padding(.bottom, 12)
        .onAppear { focused = true }
        .onExitCommand { controller.collapse() }
    }
}
