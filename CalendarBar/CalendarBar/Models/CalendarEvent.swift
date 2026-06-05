import Foundation

enum MeetingResponseStatus: String, Codable, Hashable, Sendable {
    case organizer
    case accepted
    case tentative
    case declined
    case pending

    var displayName: String {
        switch self {
        case .organizer: return "Организатор"
        case .accepted: return "Принято"
        case .tentative: return "Под вопросом"
        case .declined: return "Отклонено"
        case .pending: return "Ожидает ответа"
        }
    }

    var isHighlighted: Bool {
        self == .pending || self == .tentative
    }
}

struct EventAttendee: Codable, Hashable, Identifiable, Sendable {
    var id: String { email.isEmpty ? name : email }
    let name: String
    let email: String
    let role: String

    var displayName: String {
        if !name.isEmpty { return name }
        if !email.isEmpty { return email }
        return "Участник"
    }

    var roleLabel: String {
        switch role {
        case "optional": return "Необязательный"
        case "resource": return "Ресурс"
        default: return "Обязательный"
        }
    }
}

struct CalendarEvent: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var subject: String
    var startDate: Date
    var endDate: Date
    var location: String?
    var body: String?
    var organizer: String?
    var attendees: [EventAttendee]
    var isAllDay: Bool
    var reminderMinutes: Int?
    var responseStatus: MeetingResponseStatus

    var durationText: String {
        if isAllDay { return "Весь день" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "HH:mm"
        return "\(formatter.string(from: startDate)) – \(formatter.string(from: endDate))"
    }

    var relativeStartText: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(startDate) {
            if isAllDay { return "Сегодня, весь день" }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "ru_RU")
            formatter.dateFormat = "HH:mm"
            return "Сегодня в \(formatter.string(from: startDate))"
        }
        if calendar.isDateInTomorrow(startDate) {
            if isAllDay { return "Завтра, весь день" }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "ru_RU")
            formatter.dateFormat = "HH:mm"
            return "Завтра в \(formatter.string(from: startDate))"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "d MMM, HH:mm"
        return formatter.string(from: startDate)
    }

    var isUpcoming: Bool {
        endDate > Date()
    }

    var isFuture: Bool {
        startDate > Date()
    }

    var minutesUntilStart: Int {
        Int(startDate.timeIntervalSinceNow / 60)
    }

    var isToday: Bool {
        occurs(on: Date())
    }

    func occurs(on date: Date = Date(), calendar: Calendar = .current) -> Bool {
        let dayStart = calendar.startOfDay(for: date)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return false }
        return startDate < dayEnd && endDate > dayStart
    }
}
