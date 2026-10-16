import SwiftUI
import FrontbotCore

struct TasksView: View {
    @Bindable var model: AppModel
    @State private var title = ""
    @State private var hasDate = true
    @State private var date = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tareas").font(.largeTitle).bold()
            HStack {
                TextField("Nueva tarea…", text: $title).onSubmit(add)
                Toggle("Fecha", isOn: $hasDate).toggleStyle(.checkbox)
                if hasDate { DatePicker("", selection: $date, displayedComponents: .date).labelsHidden().frame(width: 120) }
                Button("Añadir", action: add).disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            List {
                ForEach(TaskGrouping.group(model.tasks, now: Date()), id: \.0) { bucket, items in
                    Section(bucket.rawValue) {
                        ForEach(items) { task in
                            HStack {
                                Toggle(isOn: Binding(get: { task.done }, set: { model.setTaskDone(task, done: $0) })) {
                                    Text(task.title).strikethrough(task.done)
                                }
                                .toggleStyle(.checkbox)
                                Spacer()
                                if let due = task.dueDate {
                                    Text(due.formatted(date: .abbreviated, time: .omitted)).font(.caption)
                                        .foregroundStyle(bucket == .overdue ? .red : .secondary)
                                }
                            }
                            .contextMenu { Button("Eliminar", role: .destructive) { model.deleteTask(task) } }
                        }
                    }
                }
            }
            if model.tasks.isEmpty {
                Text("Sin tareas. También puedes pedírselas al agente: «recuérdame grabar el reel el jueves».")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
    }

    private func add() {
        let t = title.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        model.addTask(title: t, dueDate: hasDate ? Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: date) : nil)
        title = ""
    }
}
