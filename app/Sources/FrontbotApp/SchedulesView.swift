import SwiftUI
import FrontbotCore

/// Todas las tareas programadas, agrupadas por agente.
struct SchedulesView: View {
    @Bindable var model: AppModel
    @State private var creatingFor: Agent?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Programadas").font(.system(size: 17, weight: .semibold))
                Text("\(model.scheduledTasks.filter { $0.status == .active }.count) activas").font(Theme.mono()).foregroundStyle(Theme.muted)
                Spacer()
                if !model.launchAtLogin {
                    Text("Frontbot no arranca solo al iniciar sesión").font(.system(size: 12)).foregroundStyle(Theme.draft)
                    Button("Activar") { model.launchAtLogin = true }.buttonStyle(OutlineButtonStyle())
                }
            }
            .padding(.horizontal, 20).frame(height: 56)
            .overlay(alignment: .bottom) { Theme.border.frame(height: 1) }

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Las tareas corren mientras Frontbot está abierto (también solo en el notch). Si el Mac estaba dormido, lo pendiente corre una sola vez al volver. Solo te avisan cuando hay algo que merece tu atención.")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                    ForEach(model.agents.filter { $0.status == .active }) { agent in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                AgentAvatar(agent: agent, size: 18)
                                Text(agent.name).font(.system(size: 13, weight: .semibold))
                                Spacer()
                                Button("Nueva tarea") { creatingFor = agent }.buttonStyle(OutlineButtonStyle())
                            }
                            let tasks = model.tasks(agentId: agent.id)
                            if tasks.isEmpty {
                                Text("Sin tareas. También puedes pedírselo en el chat: «revisa esto cada mañana y avísame si…».")
                                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
                            }
                            ForEach(tasks) { TaskRow(model: model, task: $0) }
                        }
                    }
                }
                .frame(maxWidth: 900, alignment: .leading)
                .padding(22).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Theme.background)
        .sheet(item: $creatingFor) { agent in TaskEditorSheet(model: model, agent: agent, task: nil) }
    }
}

/// Una tarea con su estado, acciones e historial plegable.
struct TaskRow: View {
    let model: AppModel
    let task: ScheduledTask
    @State private var expanded = false
    @State private var editing = false
    @State private var confirmingDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                statusPill
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.name).font(.system(size: 13, weight: .medium))
                    Text(subtitle).font(Theme.mono(11)).foregroundStyle(Theme.muted)
                }
                Spacer()
                if model.isTaskRunning(task) {
                    ProgressView().controlSize(.small)
                    Button { model.cancelTaskRun(task) } label: { Image(systemName: "stop.fill") }
                        .buttonStyle(OutlineButtonStyle()).help("Cancelar esta ejecución")
                } else {
                    Button { model.runTaskNow(task) } label: { Image(systemName: "play.fill") }
                        .buttonStyle(OutlineButtonStyle()).help("Ejecutar ahora")
                }
                switch task.status {
                case .draft: Button("Activar") { model.setTaskStatus(task, .active) }.buttonStyle(AccentButtonStyle())
                case .active: Button("Pausar") { model.setTaskStatus(task, .paused) }.buttonStyle(OutlineButtonStyle())
                case .paused: Button("Reanudar") { model.setTaskStatus(task, .active) }.buttonStyle(OutlineButtonStyle(prominent: true))
                }
                Menu {
                    Button("Editar…") { editing = true }
                    Button(expanded ? "Ocultar historial" : "Ver historial") { expanded.toggle() }
                    Divider()
                    Button("Borrar", role: .destructive) { confirmingDelete = true }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.button).buttonStyle(OutlineButtonStyle()).menuIndicator(.hidden).fixedSize()
            }
            if task.status == .draft, let author = model.agent(id: task.createdByAgentId) {
                Text("\(author.name) propuso esta tarea. Revisa la instrucción y la frecuencia antes de activarla.")
                    .font(.system(size: 12)).foregroundStyle(Theme.draft)
            }
            if let agent = model.agent(id: task.agentId), agent.trading, model.mandate(agentId: agent.id).mode == .auto, task.status != .paused {
                Text("⚠️ \(agent.name) opera en modo automático: esta tarea puede ejecutar trades sin que estés mirando (siempre dentro del mandato y con stop loss).")
                    .font(.system(size: 12)).foregroundStyle(Theme.draft).fixedSize(horizontal: false, vertical: true)
            }
            Text(task.instruction).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).lineLimit(expanded ? nil : 2)
            if !expanded, let last = model.taskRuns(task).first, last.status != .running {
                HStack(alignment: .top, spacing: 8) {
                    Text(last.status == .failed ? "✗" : last.notified ? "🔔" : "✓").foregroundStyle(last.status == .failed ? Theme.danger : Theme.approved)
                    Text("Último resultado · \(last.startedAt.formatted(.relative(presentation: .named))): \(last.summary ?? "sin resumen")")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).lineLimit(2)
                    Spacer()
                    if let conversationId = last.conversationId {
                        Button("Abrir") { model.openConversation(id: conversationId) }.buttonStyle(OutlineButtonStyle())
                    }
                }
                .padding(8).frame(maxWidth: .infinity, alignment: .leading).panel(radius: 8, fill: Theme.raised)
            }
            if expanded { history }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading).panel(radius: 10)
        .sheet(isPresented: $editing) {
            if let agent = model.agent(id: task.agentId) { TaskEditorSheet(model: model, agent: agent, task: task) }
        }
        .confirmationDialog("¿Borrar «\(task.name)»?", isPresented: $confirmingDelete) {
            Button("Borrar tarea", role: .destructive) { model.deleteTask(task) }
        }
    }

    private var subtitle: String {
        var parts = [task.schedule.summary, AgentModel.shortName(task.model)]
        if let next = task.nextRunAt, task.status == .active { parts.append("próxima " + next.formatted(date: .abbreviated, time: .shortened)) }
        if let last = task.lastRunAt { parts.append("última " + last.formatted(.relative(presentation: .named))) }
        return parts.joined(separator: " · ")
    }

    private var statusPill: some View {
        let (label, color): (String, Color) = switch task.status {
        case .draft: ("Borrador", Theme.draft)
        case .active: ("Activa", Theme.approved)
        case .paused: ("Pausada", Theme.muted)
        }
        return Text(label).font(.system(size: 10)).foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(color.opacity(0.12)))
    }

    private var history: some View {
        let runs = model.taskRuns(task)
        return VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Historial")
            if runs.isEmpty { Text("Aún no se ha ejecutado.").font(.system(size: 12)).foregroundStyle(Theme.muted) }
            ForEach(runs) { run in
                HStack(alignment: .top, spacing: 10) {
                    Text(run.startedAt.formatted(date: .abbreviated, time: .shortened)).font(Theme.mono(10)).foregroundStyle(Theme.muted)
                        .frame(width: 120, alignment: .leading)
                    Text(run.status == .running ? "…" : run.status == .failed ? "✗" : run.notified ? "🔔" : "✓")
                        .foregroundStyle(run.status == .failed ? Theme.danger : Theme.muted)
                    Text(run.summary ?? (run.status == .running ? "En curso" : "")).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                        .lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                    if run.costUsd > 0 { Text(String(format: "$%.3f", run.costUsd)).font(Theme.mono(10)).foregroundStyle(Theme.muted) }
                    if let conversationId = run.conversationId {
                        Button("Abrir") { model.openConversation(id: conversationId) }.buttonStyle(OutlineButtonStyle())
                    }
                }
            }
        }
        .padding(.top, 4)
    }
}

/// Crear o editar una tarea: nombre, instrucción, frecuencia, modelo y límite diario.
struct TaskEditorSheet: View {
    let model: AppModel
    let agent: Agent
    let task: ScheduledTask?
    @Environment(\.dismiss) private var dismiss

    enum Kind: String, CaseIterable { case interval, daily, weekly }
    @State private var name = ""
    @State private var instruction = ""
    @State private var kind: Kind = .interval
    @State private var everyMinutes = 240
    @State private var useWindow = false
    @State private var windowStart = Self.time(8, 0)
    @State private var windowEnd = Self.time(22, 0)
    @State private var time = Self.time(9, 0)
    @State private var days: Set<Int> = [2, 3, 4, 5, 6]
    @State private var modelId = AgentConfig.defaultModel
    @State private var maxRuns = 24

    static func time(_ h: Int, _ m: Int) -> Date { Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: Date()) ?? Date() }
    static let intervals = [15, 30, 60, 120, 240, 360, 720, 1440]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(task == nil ? "Nueva tarea para \(agent.name)" : "Editar tarea").font(.system(size: 16, weight: .semibold))
            labeled("Nombre") { TextField("Revisión de mercado", text: $name).textFieldStyle(.plain).padding(.horizontal, 10).frame(height: 32).panel(radius: 8) }
            labeled("Instrucción (autocontenida: nadie podrá aclararla)") {
                TextEditor(text: $instruction).font(.system(size: 13)).scrollContentBackground(.hidden)
                    .padding(8).frame(minHeight: 110).panel(radius: 8)
            }
            labeled("Frecuencia") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("", selection: $kind) {
                        Text("Cada cierto tiempo").tag(Kind.interval)
                        Text("Diaria").tag(Kind.daily)
                        Text("Días de la semana").tag(Kind.weekly)
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    switch kind {
                    case .interval:
                        HStack(spacing: 12) {
                            Picker("Cada", selection: $everyMinutes) {
                                ForEach(Array(Set(Self.intervals + [everyMinutes])).sorted(), id: \.self) { m in Text(m % 60 == 0 ? "\(m / 60) h" : "\(m) min").tag(m) }
                            }
                            .fixedSize()
                            Toggle("Solo de", isOn: $useWindow).toggleStyle(.checkbox)
                            DatePicker("", selection: $windowStart, displayedComponents: .hourAndMinute).labelsHidden().disabled(!useWindow)
                            Text("a").foregroundStyle(Theme.muted)
                            DatePicker("", selection: $windowEnd, displayedComponents: .hourAndMinute).labelsHidden().disabled(!useWindow)
                        }
                    case .daily:
                        DatePicker("A las", selection: $time, displayedComponents: .hourAndMinute).fixedSize()
                    case .weekly:
                        HStack(spacing: 6) {
                            ForEach([2, 3, 4, 5, 6, 7, 1], id: \.self) { d in
                                Toggle(Schedule.dayNames[d - 1], isOn: Binding(get: { days.contains(d) }, set: { if $0 { days.insert(d) } else { days.remove(d) } }))
                                    .toggleStyle(.button)
                            }
                            DatePicker("a las", selection: $time, displayedComponents: .hourAndMinute).fixedSize()
                        }
                    }
                }
            }
            HStack(spacing: 16) {
                labeled("Modelo") {
                    Picker("", selection: $modelId) { ForEach(AgentModel.all, id: \.id) { Text($0.label).tag($0.id) } }.labelsHidden().fixedSize()
                }
                labeled("Máx. ejecuciones al día") {
                    Stepper("\(maxRuns)", value: $maxRuns, in: 1...96).fixedSize()
                }
                Spacer()
            }
            if let error = model.errorMessage { Text(error).font(.system(size: 12)).foregroundStyle(Theme.danger) }
            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }.buttonStyle(OutlineButtonStyle())
                Button(task == nil ? "Crear y activar" : "Guardar") {
                    model.errorMessage = nil
                    let draft = TaskDraft(name: name, instruction: instruction, schedule: schedule, model: modelId, maxRunsPerDay: maxRuns)
                    let ok = task.map { model.updateTask($0, draft: draft) } ?? model.createTask(agentId: agent.id, draft: draft)
                    if ok { dismiss() }
                }
                .buttonStyle(AccentButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22).frame(width: 620).background(Theme.sidebar)
        .onAppear(perform: load)
        .onDisappear { model.errorMessage = nil }
    }

    private var schedule: Schedule {
        func tod(_ d: Date) -> TimeOfDay {
            let c = Calendar.current.dateComponents([.hour, .minute], from: d)
            return TimeOfDay(c.hour ?? 0, c.minute ?? 0)
        }
        switch kind {
        case .interval: return .interval(minutes: everyMinutes, window: useWindow ? TimeWindow(start: tod(windowStart), end: tod(windowEnd)) : nil)
        case .daily: return .daily(tod(time))
        case .weekly: return .weekly(days: days.sorted(), tod(time))
        }
    }

    private func load() {
        modelId = agent.model
        guard let task else { return }
        name = task.name
        instruction = task.instruction
        modelId = task.model
        maxRuns = task.maxRunsPerDay
        switch task.schedule {
        case .interval(let minutes, let window):
            kind = .interval
            everyMinutes = minutes // también valores que no están en la lista (p. ej. 20 min de un borrador del agente)
            if let window {
                useWindow = true
                windowStart = Self.time(window.start.hour, window.start.minute)
                windowEnd = Self.time(window.end.hour, window.end.minute)
            }
        case .daily(let t):
            kind = .daily
            time = Self.time(t.hour, t.minute)
        case .weekly(let d, let t):
            kind = .weekly
            days = Set(d)
            time = Self.time(t.hour, t.minute)
        }
    }

    private func labeled(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) { SectionLabel(label); content() }
    }
}
