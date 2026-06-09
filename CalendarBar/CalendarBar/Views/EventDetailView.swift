import SwiftUI

struct AggregatedEventsSidePanel: View {
    let events: [CalendarEvent]
    var onSelect: (CalendarEvent) -> Void
    var onClose: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 8) {
                    Text(TimedEventLayout.meetingsLabel(count: events.count))
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                ForEach(events) { event in
                    Button(action: { onSelect(event) }) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(event.subject)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(timeText(for: event))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(10)
                        .background(Color.primary.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: .infinity)
    }

    private func timeText(for event: CalendarEvent) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "HH:mm"
        return "\(formatter.string(from: event.startDate))–\(formatter.string(from: event.endDate))"
    }
}

struct EventDetailSidePanel: View {
    let event: CalendarEvent
    var onClose: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 8) {
                    Text(event.subject)
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                if event.responseStatus.isHighlighted {
                    Label(event.responseStatus.displayName, systemImage: "envelope.badge")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.orange)
                }

                detailRow(icon: "clock", title: "Время", value: timeText)

                if let location = event.location, !location.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Место", systemImage: "mappin.and.ellipse")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        LinkDetectingText(text: location)
                    }
                }

                if let organizer = event.organizer, !organizer.isEmpty {
                    detailRow(icon: "person.crop.circle", title: "Организатор", value: organizer)
                }

                if !event.attendees.isEmpty {
                    attendeesSection
                }

                if let body = event.body, !body.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Описание", systemImage: "text.alignleft")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        LinkDetectingText(text: body)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: .infinity)
    }

    private var attendeesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Участники", systemImage: "person.2")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(event.attendees) { attendee in
                VStack(alignment: .leading, spacing: 2) {
                    Text(attendee.displayName)
                        .font(.body)
                    if !attendee.email.isEmpty, attendee.email != attendee.name {
                        Text(attendee.email)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(attendee.roleLabel)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var timeText: String {
        if event.isAllDay {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "ru_RU")
            formatter.dateFormat = "d MMMM yyyy"
            return "Весь день · \(formatter.string(from: event.startDate))"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "d MMM yyyy, HH:mm"
        let start = formatter.string(from: event.startDate)
        formatter.dateFormat = "HH:mm"
        return "\(start) – \(formatter.string(from: event.endDate))"
    }

    private func detailRow(icon: String, title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body)
                .textSelection(.enabled)
        }
    }
}
