import Foundation

/// Thin wrapper around ActiveSyncClient preserving the public Exchange API.
final class ExchangeClient {
    private let client: ActiveSyncClient

    init(settings: AccountSettings, password: String) {
        client = ActiveSyncClient(settings: settings, password: password)
    }

    func fetchCalendarEvents(from start: Date, to end: Date) async throws -> [CalendarEvent] {
        let normalized = try await client.getCalendarEvents()
        let expanded = expandRecurringEvents(normalized, from: start, to: end)
        return mapAndFilterEvents(expanded, from: start, to: end)
    }

    func fetchEventDetails(itemId: String, changeKey: String?) async throws -> CalendarEvent? {
        nil
    }

    func testConnection() async throws {
        try await client.testConnection()
    }

    var deviceId: String {
        client.currentDeviceId
    }

    private func mapAndFilterEvents(_ events: [NormalizedCalendarEvent], from start: Date, to end: Date) -> [CalendarEvent] {
        return events.compactMap { event -> CalendarEvent? in
            guard let startDate = ActiveSyncDateParser.parse(event.startAt),
                  let endDate = ActiveSyncDateParser.parse(event.endAt.isEmpty ? event.startAt : event.endAt) else {
                return nil
            }

            guard startDate < end && endDate > start else { return nil }

            let organizer = event.organizer.map { org in
                org.name.isEmpty ? org.email : org.name
            }

            let attendees = event.attendees.map { attendee in
                EventAttendee(name: attendee.name, email: attendee.email, role: attendee.role)
            }

            return CalendarEvent(
                id: event.serverId.isEmpty ? event.uid : event.serverId,
                subject: event.title.isEmpty ? "Без названия" : event.title,
                startDate: startDate,
                endDate: endDate,
                location: event.location.isEmpty ? nil : event.location,
                body: event.description.isEmpty ? nil : event.description,
                organizer: organizer,
                attendees: attendees,
                isAllDay: event.allDay,
                reminderMinutes: event.reminderMinutes,
                responseStatus: event.responseStatus
            )
        }
        .sorted { $0.startDate < $1.startDate }
    }
}
