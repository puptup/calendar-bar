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
        return dedupeEvents(mapAndFilterEvents(expanded, from: start, to: end))
    }

    func fetchEventDetails(itemId: String, changeKey: String?) async throws -> CalendarEvent? {
        nil
    }

    func testConnection() async throws {
        try await client.testConnection()
    }

    func fetchInboxMessages() async throws -> MailSyncSnapshot {
        try await client.getInboxMessages()
    }

    func fetchMailMessages(folder: MailFolderKind) async throws -> MailSyncSnapshot {
        try await client.getMailMessages(folder: folder)
    }

    func fetchMessageBody(for message: MailMessage) async throws -> MailBody? {
        try await client.fetchMessageBody(collectionId: message.collectionId, serverId: message.serverId)
    }

    func fetchAttachment(_ attachment: MailAttachment) async throws -> ItemOperationsFetchResult {
        try await client.fetchAttachment(fileReference: attachment.fileReference)
    }

    func setMessageRead(_ message: MailMessage, read: Bool) async throws {
        try await client.setMessageRead(collectionId: message.collectionId, serverId: message.serverId, read: read)
    }

    func sendMail(to: [MailAddress], cc: [MailAddress], subject: String, body: String) async throws {
        try await client.sendMail(to: to, cc: cc, subject: subject, body: body)
    }

    func reply(to message: MailMessage, body: String, replyAll: Bool) async throws {
        try await client.smartReply(message: message, body: body, replyAll: replyAll)
    }

    func forward(message: MailMessage, to: [MailAddress], body: String) async throws {
        try await client.smartForward(message: message, to: to, body: body)
    }

    func respondToMeeting(eventId: String, action: MeetingAction) async throws {
        try await client.respondToMeeting(serverId: eventId, action: action)
    }

    func deleteCalendarEvent(eventId: String) async throws {
        try await client.deleteCalendarEvent(serverId: eventId)
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

    private func dedupeEvents(_ events: [CalendarEvent]) -> [CalendarEvent] {
        var deduped: [CalendarEvent] = []

        for event in events {
            if let index = deduped.firstIndex(where: { calendarEventsMatch($0, event) }) {
                if eventQuality(event) > eventQuality(deduped[index]) {
                    deduped[index] = event
                }
            } else {
                deduped.append(event)
            }
        }

        return deduped.sorted { $0.startDate < $1.startDate }
    }

    private func calendarEventsMatch(_ lhs: CalendarEvent, _ rhs: CalendarEvent) -> Bool {
        normalizedCalendarTitle(lhs.subject) == normalizedCalendarTitle(rhs.subject)
            && abs(lhs.startDate.timeIntervalSince(rhs.startDate)) <= 120
            && abs(lhs.endDate.timeIntervalSince(rhs.endDate)) <= 120
    }

    private func eventQuality(_ event: CalendarEvent) -> Int {
        var score = 0
        if !(event.body ?? "").isEmpty { score += 1 }
        if !(event.location ?? "").isEmpty { score += 1 }
        if !(event.organizer ?? "").isEmpty { score += 2 }
        score += min(event.attendees.count, 10) * 2
        if event.responseStatus != .pending { score += 1 }
        return score
    }

    private func normalizedCalendarTitle(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }
}
