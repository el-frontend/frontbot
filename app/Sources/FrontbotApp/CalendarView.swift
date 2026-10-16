import SwiftUI
import FrontbotCore

struct CalendarView: View {
    @Bindable var model: AppModel
    @State private var editing: Post?
    private let content = ContentCalendar()

    private var days: [CalendarDay] {
        content.days(model.calendarScope, containing: model.calendarDate, posts: model.posts,
                     brandId: model.calendarBrandId, network: model.calendarNetwork)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button { model.calendarDate = content.shift(model.calendarDate, scope: model.calendarScope, by: -1) } label: { Image(systemName: "chevron.left") }
                Button("Hoy") { model.calendarDate = Date() }
                Button { model.calendarDate = content.shift(model.calendarDate, scope: model.calendarScope, by: 1) } label: { Image(systemName: "chevron.right") }
                Text(title).font(.title2).bold()
                Spacer()
                Picker("Marca", selection: $model.calendarBrandId) {
                    Text("Todas las marcas").tag(String?.none)
                    ForEach(model.brands) { Text($0.name).tag(String?.some($0.id)) }
                }.frame(width: 180)
                Picker("Red", selection: $model.calendarNetwork) {
                    Text("Todas las redes").tag(Network?.none)
                    ForEach(Network.allCases, id: \.self) { Text($0.rawValue).tag(Network?.some($0)) }
                }.frame(width: 160)
                Picker("", selection: $model.calendarScope) {
                    Text("Semana").tag(CalendarScope.week)
                    Text("Mes").tag(CalendarScope.month)
                }.pickerStyle(.segmented).frame(width: 150)
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
                ForEach(["Lun", "Mar", "Mié", "Jue", "Vie", "Sáb", "Dom"], id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                ForEach(days) { day in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(day.date.formatted(.dateTime.day())).font(.caption).bold()
                            .foregroundStyle(Calendar.current.isDateInToday(day.date) ? Color.accentColor : .primary)
                        ForEach(day.posts) { post in PostChip(model: model, post: post).onTapGesture { editing = post } }
                        Spacer(minLength: 0)
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, minHeight: model.calendarScope == .week ? 220 : 90, alignment: .topLeading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(day.inScope ? Color.secondary.opacity(0.08) : Color.clear))
                    .opacity(day.inScope ? 1 : 0.5)
                }
            }

            let pending = content.unscheduled(model.posts, brandId: model.calendarBrandId, network: model.calendarNetwork)
            if !pending.isEmpty {
                Text("Sin fecha").font(.headline)
                ScrollView(.horizontal) {
                    HStack { ForEach(pending) { post in PostChip(model: model, post: post).frame(width: 200).onTapGesture { editing = post } } }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .sheet(item: $editing) { post in PostEditorView(model: model, post: post) }
    }

    private var title: String {
        model.calendarScope == .week
            ? "Semana del " + content.range(.week, containing: model.calendarDate).start.formatted(.dateTime.day().month(.wide))
            : model.calendarDate.formatted(.dateTime.month(.wide).year())
    }
}

struct PostChip: View {
    let model: AppModel
    let post: Post

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(model.brand(id: post.brandId)?.name ?? "").font(.caption2).bold()
                Text(post.network == .instagram ? "IG" : "in").font(.caption2).foregroundStyle(.secondary)
                if let at = post.scheduledFor { Text(at.formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundStyle(.secondary) }
            }
            Text(post.body).font(.caption).lineLimit(2)
        }
        .padding(5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
        .contentShape(Rectangle())
    }

    private var color: Color {
        switch post.status {
        case .draft: .orange
        case .approved: .green
        case .preparing, .scheduled: .blue
        case .published: .purple
        case .archived: .gray
        }
    }
}
