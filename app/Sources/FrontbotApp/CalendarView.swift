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
        // Panel lateral propio en vez de `.inspector`: al redimensionar el inspector de AppKit la app
        // se cerraba (EXC_BAD_ACCESS en el layout de AppKit, macOS 26).
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                grid
                unscheduled
            }
            .frame(maxWidth: .infinity)
            if let post = editing {
                Theme.border.frame(width: 1)
                PostEditorView(model: model, post: post) { editing = nil }
                    .id(post.id)
                    .frame(width: 560)
                    .transition(.move(edge: .trailing))
            }
        }
        .background(Theme.background)
        .animation(.easeOut(duration: 0.18), value: editing?.id)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button { model.calendarDate = content.shift(model.calendarDate, scope: model.calendarScope, by: -1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(OutlineButtonStyle()).accessibilityLabel("Anterior")
            Button("Hoy") { model.calendarDate = Date() }.buttonStyle(OutlineButtonStyle(prominent: true))
            Button { model.calendarDate = content.shift(model.calendarDate, scope: model.calendarScope, by: 1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(OutlineButtonStyle()).accessibilityLabel("Siguiente")
            Text(title).font(.system(size: 17, weight: .semibold)).padding(.leading, 8)
            Spacer()
            Picker("Marca", selection: $model.calendarBrandId) {
                Text("Todas las marcas").tag(String?.none)
                ForEach(model.brands) { Text($0.name).tag(String?.some($0.id)) }
            }
            .labelsHidden().fixedSize()
            Picker("Red", selection: $model.calendarNetwork) {
                Text("Todas las redes").tag(Network?.none)
                ForEach(Network.allCases, id: \.self) { Text(Theme.networkName($0)).tag(Network?.some($0)) }
            }
            .labelsHidden().fixedSize()
            Picker("Vista", selection: $model.calendarScope) {
                Text("Semana").tag(CalendarScope.week)
                Text("Mes").tag(CalendarScope.month)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 150)
        }
        .padding(.horizontal, 20).frame(height: 56)
        .overlay(alignment: .bottom) { Theme.border.frame(height: 1) }
    }

    private var grid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
        return ScrollView {
            LazyVGrid(columns: columns, spacing: 0) {
                ForEach(Array(days.enumerated()), id: \.element.id) { index, day in
                    dayCell(day, showWeekday: model.calendarScope == .week || index < 7)
                }
            }
        }
        .frame(maxHeight: .infinity)
        .overlay(alignment: .bottom) { Theme.border.frame(height: 1) }
    }

    private func dayCell(_ day: CalendarDay, showWeekday: Bool) -> some View {
        let isToday = Calendar.current.isDateInToday(day.date)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if showWeekday {
                    Text(day.date.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                        .font(.system(size: 11)).foregroundStyle(isToday ? Theme.accent : Theme.muted)
                }
                Text(day.date.formatted(.dateTime.day())).font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isToday ? Theme.accent : Theme.text)
                if isToday { Text("hoy").font(.system(size: 11)).foregroundStyle(Theme.accent) }
            }
            ForEach(day.posts) { post in
                PostChip(model: model, post: post).onTapGesture { editing = post }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: model.calendarScope == .week ? 420 : 120, alignment: .topLeading)
        .background(isToday ? Color(hex: 0x0F0F12) : Color.clear)
        .overlay(alignment: .trailing) { Color(hex: 0x1C1C1F).frame(width: 1) }
        .overlay(alignment: .bottom) { if model.calendarScope == .month { Color(hex: 0x1C1C1F).frame(height: 1) } }
        .opacity(day.inScope ? 1 : 0.4)
    }

    private var unscheduled: some View {
        let pending = content.unscheduled(model.posts, brandId: model.calendarBrandId, network: model.calendarNetwork)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Text("Sin fecha").font(.system(size: 13, weight: .semibold))
                Text("\(pending.count) posts").font(Theme.mono()).foregroundStyle(Theme.muted)
                Spacer()
                ForEach([PostStatus.draft, .approved, .scheduled, .published], id: \.self) { status in
                    HStack(spacing: 6) {
                        StatusDot(color: Theme.statusColor(status))
                        Text(status == .scheduled ? String(localized: "Preparando / programado") : Theme.statusLabel(status))
                    }
                    .font(Theme.mono()).foregroundStyle(Theme.muted)
                }
            }
            if !pending.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(pending) { post in
                            PostChip(model: model, post: post, dashed: true).frame(width: 260).onTapGesture { editing = post }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    private var title: String {
        model.calendarScope == .week
            ? String(localized: "Semana del \(content.range(.week, containing: model.calendarDate).start.formatted(.dateTime.day().month(.wide)))")
            : model.calendarDate.formatted(.dateTime.month(.wide).year())
    }
}

struct PostChip: View {
    let model: AppModel
    let post: Post
    var dashed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                StatusDot(color: Theme.statusColor(post.status))
                Text(meta).lineLimit(1)
            }
            .font(Theme.mono(10)).foregroundStyle(Theme.muted)
            Text(post.body).font(.system(size: 12)).lineSpacing(2).lineLimit(3).foregroundStyle(Theme.text)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(dashed ? Theme.surface : Color(hex: 0x141417)))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(dashed ? Color(hex: 0x2F2F34) : Color(hex: 0x26262A),
                                                         style: StrokeStyle(lineWidth: 1, dash: dashed ? [4, 3] : [])))
        .contentShape(Rectangle())
    }

    private var meta: String {
        var parts: [String] = []
        if let at = post.scheduledFor { parts.append(at.formatted(date: .omitted, time: .shortened)) }
        else { parts.append(Theme.statusLabel(post.status)) }
        parts.append(Theme.networkShort(post.network))
        if let brand = model.brand(id: post.brandId) { parts.append(brand.name) }
        return parts.joined(separator: " · ")
    }
}
