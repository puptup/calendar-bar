import SwiftUI

extension Notification.Name {
    static let timelineScrollRequested = Notification.Name("timelineScrollRequested")
}

struct DayTimelineView: View {
    let day: Date
    let events: [CalendarEvent]
    @Binding var selectedEventId: String?

    private let calendar = Calendar.current
    private let hourHeight: CGFloat = 52
    private let timeColumnWidth: CGFloat = 44
    private let minEventHeight: CGFloat = 22
    private let timelineTopInset: CGFloat = 10

    private var allDayEvents: [CalendarEvent] {
        events.filter(\.isAllDay).sorted { $0.startDate < $1.startDate }
    }

    private var timedEvents: [CalendarEvent] {
        events.filter { !$0.isAllDay }.sorted { $0.startDate < $1.startDate }
    }

    private var gridStartHour: Int { 0 }

    private var gridEndHour: Int { 24 }

    private var gridHeight: CGFloat {
        CGFloat(gridEndHour - gridStartHour) * hourHeight
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !allDayEvents.isEmpty {
                        allDaySection
                        Divider().padding(.leading, timeColumnWidth + 8)
                    }

                    if timedEvents.isEmpty {
                        if allDayEvents.isEmpty {
                            emptyDay
                        }
                    } else {
                        timelineGrid
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 8)
            }
            .scrollContentBackground(.hidden)
            .onAppear { scrollToAnchor(proxy: proxy) }
            .onChange(of: day) { _, _ in scrollToAnchor(proxy: proxy) }
            .onChange(of: scrollTrigger) { _, _ in scrollToAnchor(proxy: proxy) }
            .onReceive(NotificationCenter.default.publisher(for: .timelineScrollRequested)) { _ in
                scrollToAnchor(proxy: proxy)
            }
        }
    }

    private var allDaySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Весь день")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, timeColumnWidth + 12)

            HStack(spacing: 4) {
                ForEach(allDayEvents) { event in
                    AllDayEventChip(event: event, isSelected: selectedEventId == event.id)
                        .frame(maxWidth: .infinity)
                        .onTapGesture { toggleSelection(event) }
                }
            }
            .padding(.horizontal, 12)
            .padding(.leading, timeColumnWidth - 4)
        }
        .padding(.vertical, 8)
    }

    private var emptyDay: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 40)
            Image(systemName: "calendar")
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text("Нет событий")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 40)
        }
        .frame(maxWidth: .infinity)
    }

    private var timelineGrid: some View {
        ZStack(alignment: .topLeading) {
            hourGrid
                .padding(.top, timelineTopInset)
            eventBlocks
            if calendar.isDateInToday(day) {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    currentTimeIndicator(at: context.date)
                }
            }
        }
        .frame(height: gridHeight + timelineTopInset)
        .padding(.trailing, 12)
    }

    /// Changes when the set of events or scroll target moves — triggers re-scroll after sync.
    private var scrollTrigger: String {
        let anchor = scrollAnchorEvent?.id ?? "now"
        return "\(day.timeIntervalSince1970)-\(anchor)-\(timedEvents.count)"
    }

    private var scrollTargetHour: Int {
        if let event = scrollAnchorEvent {
            let hour = calendar.component(.hour, from: event.startDate)
            return max(gridStartHour, min(hour, gridEndHour - 1))
        }
        if calendar.isDateInToday(day) {
            return max(gridStartHour, calendar.component(.hour, from: Date()))
        }
        return gridStartHour
    }

    /// Nearest relevant point on the timeline: next upcoming event today, first event on other days, or current time.
    private var scrollAnchorEvent: CalendarEvent? {
        if calendar.isDateInToday(day) {
            let now = Date()
            return timedEvents.first { $0.endDate > now }
        }
        return timedEvents.first
    }

    private var hourGrid: some View {
        VStack(spacing: 0) {
            ForEach(gridStartHour..<gridEndHour, id: \.self) { hour in
                HStack(alignment: .top, spacing: 0) {
                    Text(hourLabel(hour))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: timeColumnWidth, alignment: .trailing)
                        .padding(.trailing, 8)
                        .offset(y: -4)

                    VStack(spacing: 0) {
                        Divider()
                        Spacer(minLength: hourHeight - 1)
                    }
                }
                .frame(height: hourHeight)
                .id("hour-\(hour)")
            }
        }
    }

    private var timedEventLayouts: [TimedEventLayout] {
        Self.layoutTimedEvents(timedEvents)
    }

    private var eventBlocks: some View {
        let columnGap: CGFloat = 3
        let totalWidth = eventColumnWidth

        return ForEach(timedEventLayouts) { layout in
            let columnCount = CGFloat(max(layout.columnCount, 1))
            let colWidth = (totalWidth - columnGap * (columnCount - 1)) / columnCount
            let x = timeColumnWidth + 8 + CGFloat(layout.column) * (colWidth + columnGap)

            TimelineEventBlock(
                event: layout.event,
                minHeight: minEventHeight,
                isSelected: selectedEventId == layout.event.id
            )
                .frame(width: colWidth, height: eventHeight(for: layout.event), alignment: .topLeading)
                .offset(x: x, y: eventYOffset(for: layout.event) + timelineTopInset)
                .onTapGesture { toggleSelection(layout.event) }
        }
    }

    @ViewBuilder
    private func currentTimeIndicator(at now: Date) -> some View {
        if calendar.isDateInToday(day),
           let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart),
           now >= dayStart,
           now < dayEnd {
            let y = CGFloat(minutesFromMidnight(now) - gridStartHour * 60) / 60 * hourHeight
            HStack(spacing: 3) {
                Text(timeLabel(for: now))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.red)
                    .monospacedDigit()
                    .frame(width: timeColumnWidth - 2, alignment: .trailing)
                    .offset(y: -5)
                Circle()
                    .fill(.red)
                    .frame(width: 6, height: 6)
                Rectangle()
                    .fill(.red)
                    .frame(height: 1)
                    .frame(maxWidth: .infinity)
            }
            .padding(.trailing, 12)
            .offset(y: y + timelineTopInset)
        }
    }

    private func toggleSelection(_ event: CalendarEvent) {
        if selectedEventId == event.id {
            selectedEventId = nil
        } else {
            selectedEventId = event.id
        }
    }

    private func timeLabel(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private var dayStart: Date {
        calendar.startOfDay(for: day)
    }

    private var eventColumnWidth: CGFloat {
        340 - timeColumnWidth - 24
    }

    private func hourLabel(_ hour: Int) -> String {
        var components = calendar.dateComponents([.year, .month, .day], from: day)
        components.hour = hour
        components.minute = 0
        guard let date = calendar.date(from: components) else { return "\(hour)" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private func minutesFromMidnight(_ date: Date) -> Int {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }

    private func eventYOffset(for event: CalendarEvent) -> CGFloat {
        let startMinutes = minutesFromMidnight(event.startDate)
        let offsetMinutes = startMinutes - gridStartHour * 60
        return CGFloat(offsetMinutes) / 60 * hourHeight
    }

    private func eventHeight(for event: CalendarEvent) -> CGFloat {
        let durationMinutes = max(15, Int(event.endDate.timeIntervalSince(event.startDate) / 60))
        return max(minEventHeight, CGFloat(durationMinutes) / 60 * hourHeight - 2)
    }

    private func scrollToAnchor(proxy: ScrollViewProxy) {
        guard !timedEvents.isEmpty || calendar.isDateInToday(day) else { return }

        let targetHour = max(gridStartHour, scrollTargetHour - 1)
        let targetID = "hour-\(targetHour)"

        func performScroll(animated: Bool) {
            if animated {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(targetID, anchor: .top)
                }
            } else {
                proxy.scrollTo(targetID, anchor: .top)
            }
        }

        performScroll(animated: false)
        DispatchQueue.main.async { performScroll(animated: false) }
    }

    private static func layoutTimedEvents(_ events: [CalendarEvent]) -> [TimedEventLayout] {
        let sorted = events.sorted { $0.startDate < $1.startDate }
        guard !sorted.isEmpty else { return [] }

        var layouts: [TimedEventLayout] = []
        var cluster: [CalendarEvent] = []

        func clusterEndTime() -> Date {
            cluster.map(\.endDate).max() ?? .distantPast
        }

        func flushCluster() {
            guard !cluster.isEmpty else { return }
            layouts.append(contentsOf: layoutOverlapCluster(cluster))
            cluster.removeAll()
        }

        for event in sorted {
            if cluster.isEmpty {
                cluster.append(event)
            } else if event.startDate < clusterEndTime() {
                cluster.append(event)
            } else {
                flushCluster()
                cluster.append(event)
            }
        }
        flushCluster()
        return layouts
    }

    private static func layoutOverlapCluster(_ events: [CalendarEvent]) -> [TimedEventLayout] {
        let sorted = events.sorted { $0.startDate < $1.startDate }
        var columnEnds: [Date] = []
        var assignments: [(CalendarEvent, Int)] = []

        for event in sorted {
            var column = columnEnds.firstIndex(where: { $0 <= event.startDate })
            if let existing = column {
                columnEnds[existing] = event.endDate
                assignments.append((event, existing))
            } else {
                let newColumn = columnEnds.count
                columnEnds.append(event.endDate)
                assignments.append((event, newColumn))
            }
        }

        let columnCount = max(columnEnds.count, 1)
        return assignments.map { event, column in
            TimedEventLayout(event: event, column: column, columnCount: columnCount)
        }
    }
}

private struct TimedEventLayout: Identifiable {
    var id: String { event.id }
    let event: CalendarEvent
    let column: Int
    let columnCount: Int
}

private struct AllDayEventChip: View {
    let event: CalendarEvent
    var isSelected: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2)
                .fill(eventColor)
                .frame(width: 3)
            Text(event.subject)
                .font(.caption.weight(.medium))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(eventColor.opacity(isSelected ? 0.28 : 0.15))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(isSelected ? eventColor : .clear, lineWidth: 1.5)
        )
    }

    private var eventColor: Color {
        event.responseStatus == .pending ? .orange : .accentColor
    }
}

private struct TimelineEventBlock: View {
    let event: CalendarEvent
    let minHeight: CGFloat
    var isSelected: Bool = false

    var body: some View {
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 2)
                .fill(eventColor)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 2) {
                Text(event.subject)
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)
                Text(event.durationText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let location = event.location, !location.isEmpty, minHeight > 36 {
                    Text(location)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(eventColor.opacity(0.18))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(isSelected ? eventColor : eventColor.opacity(0.35), lineWidth: isSelected ? 2 : 0.5)
        )
        .opacity(isSelected ? 1 : 0.92)
    }

    private var eventColor: Color {
        switch event.responseStatus {
        case .pending: return .orange
        case .tentative: return .yellow
        case .declined: return .red.opacity(0.8)
        default: return .accentColor
        }
    }
}
