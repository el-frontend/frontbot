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
            // Quieta en reposo (logo); viva mientras el agente trabaja o reacciona.
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                let state = model.mascot.state(at: context.date, listening: false)
                if state == .idle { FrontbotLogo(size: 18) } else { MascotView(state: state, size: 22) }
            }
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
            .padding(.horizontal, 12).frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(hex: 0x141416)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(hex: 0x26262A)))

            if let reply = model.lastAgentReply {
                HStack(alignment: .top, spacing: 10) {
                    TimelineView(.periodic(from: .now, by: 0.25)) { context in
                        MascotView(state: model.mascot.state(at: context.date, listening: true), size: 56)
                    }
                    ScrollView { Text(reply).font(.system(size: 13)).lineSpacing(3).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                        .frame(maxHeight: 110)
                }
                .padding(10).background(RoundedRectangle(cornerRadius: 10).fill(Color(hex: 0x0E0E10)))
            }

            if let next = model.nextScheduled, let at = next.task.nextRunAt {
                Button { model.showMainWindow(section: .schedules); controller.collapse() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "clock")
                        Text("Próxima: \(next.agent.name) · \(at.formatted(date: Calendar.current.isDateInToday(at) ? .omitted : .abbreviated, time: .shortened))")
                    }
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
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
                        pill("\(today.draftsToReview) por revisar", color: Theme.draft) { model.showMainWindow(section: .calendar); controller.collapse() }
                    }
                    if today.readyToPublish > 0 {
                        pill("\(today.readyToPublish) listos para publicar", color: Theme.approved) { model.showMainWindow(section: .calendar); controller.collapse() }
                    }
                    Spacer()
                    Button("Abrir Frontbot") { model.showMainWindow(section: .chat); controller.collapse() }
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 34).padding(.horizontal, 16).padding(.bottom, 12)
        .onAppear { focused = true }
        .onExitCommand { controller.collapse() }
    }

    private func pill(_ title: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) { StatusDot(color: color); Text(title) }
                .font(.system(size: 12)).foregroundStyle(color)
                .padding(.horizontal, 10).frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.1)))
        }
        .buttonStyle(.plain)
    }
}
