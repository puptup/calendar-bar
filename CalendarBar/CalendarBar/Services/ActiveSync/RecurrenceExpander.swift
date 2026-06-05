import Foundation

enum ActiveSyncDateParser {
    private static let isoWithFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parse(_ value: String) -> Date? {
        guard !value.isEmpty else { return nil }

        if let date = isoWithFraction.date(from: value) { return date }
        if let date = iso.date(from: value) { return date }

        let compactPattern = #"^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z?$"#
        if let regex = try? NSRegularExpression(pattern: compactPattern),
           let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..<value.endIndex, in: value)),
           let yearRange = Range(match.range(at: 1), in: value),
           let monthRange = Range(match.range(at: 2), in: value),
           let dayRange = Range(match.range(at: 3), in: value),
           let hourRange = Range(match.range(at: 4), in: value),
           let minuteRange = Range(match.range(at: 5), in: value),
           let secondRange = Range(match.range(at: 6), in: value) {
            var components = DateComponents()
            components.year = Int(value[yearRange])
            components.month = Int(value[monthRange])
            components.day = Int(value[dayRange])
            components.hour = Int(value[hourRange])
            components.minute = Int(value[minuteRange])
            components.second = Int(value[secondRange])
            components.timeZone = TimeZone(secondsFromGMT: 0)
            return Calendar(identifier: .gregorian).date(from: components)
        }

        return nil
    }

    static func format(_ date: Date) -> String {
        date.ISO8601Format()
    }
}

func expandRecurringEvents(
    _ events: [NormalizedCalendarEvent],
    from windowStart: Date,
    to windowEnd: Date,
    calendar: Calendar = .current
) -> [NormalizedCalendarEvent] {
    var expanded: [NormalizedCalendarEvent] = []

    for event in events {
        if event.recurrence == nil || isExpandedInstance(event) {
            expanded.append(event)
            continue
        }

        guard let masterStart = ActiveSyncDateParser.parse(event.startAt) else {
            expanded.append(event)
            continue
        }

        let masterEnd = ActiveSyncDateParser.parse(event.endAt.isEmpty ? event.startAt : event.endAt) ?? masterStart
        let duration = masterEnd.timeIntervalSince(masterStart)
        let normalizedRecurrence = normalizeRecurrenceRule(event.recurrence!, masterStart: masterStart, calendar: calendar)

        let instances: [NormalizedCalendarEvent]
        switch normalizedRecurrence.type {
        case "0":
            instances = generateDailyInstances(
                event: event, recurrence: normalizedRecurrence, masterStart: masterStart,
                duration: duration, from: windowStart, to: windowEnd, calendar: calendar
            )
        case "1":
            instances = generateWeeklyInstances(
                event: event, recurrence: normalizedRecurrence, masterStart: masterStart,
                duration: duration, from: windowStart, to: windowEnd, calendar: calendar
            )
        default:
            instances = generateRecurrenceInstancesByDay(
                event: event, recurrence: normalizedRecurrence, masterStart: masterStart,
                duration: duration, from: windowStart, to: windowEnd, calendar: calendar
            )
        }

        expanded.append(contentsOf: instances)
    }

    return expanded
}

private let maxInstancesPerSeries = 120

private func isExpandedInstance(_ event: NormalizedCalendarEvent) -> Bool {
    event.instanceType == "2" || event.instanceType == "3"
}

private func normalizeRecurrenceRule(
    _ recurrence: CalendarRecurrence,
    masterStart: Date,
    calendar: Calendar
) -> CalendarRecurrence {
    let trimmedType = recurrence.type.trimmingCharacters(in: .whitespacesAndNewlines)
    let inferredType: String

    if !trimmedType.isEmpty {
        inferredType = trimmedType
    } else if recurrence.dayOfWeek != nil {
        inferredType = "1"
    } else if recurrence.dayOfMonth != nil {
        inferredType = recurrence.weekOfMonth != nil ? "3" : "2"
    } else if recurrence.monthOfYear != nil {
        inferredType = recurrence.weekOfMonth != nil ? "6" : "5"
    } else {
        inferredType = "1"
    }

    let inferredDayOfWeek: Int?
    if inferredType == "1", (recurrence.dayOfWeek ?? 0) <= 0 {
        inferredDayOfWeek = activeSyncWeekdayBitValue(for: calendar.component(.weekday, from: masterStart))
    } else {
        inferredDayOfWeek = recurrence.dayOfWeek
    }

    return CalendarRecurrence(
        type: inferredType,
        interval: max(recurrence.interval, 1),
        occurrences: recurrence.occurrences,
        until: recurrence.until,
        dayOfWeek: inferredDayOfWeek,
        dayOfMonth: recurrence.dayOfMonth,
        weekOfMonth: recurrence.weekOfMonth,
        monthOfYear: recurrence.monthOfYear
    )
}

private func generateDailyInstances(
    event: NormalizedCalendarEvent,
    recurrence: CalendarRecurrence,
    masterStart: Date,
    duration: TimeInterval,
    from windowStart: Date,
    to windowEnd: Date,
    calendar: Calendar
) -> [NormalizedCalendarEvent] {
    let untilDate = ActiveSyncDateParser.parse(recurrence.until)
    let interval = max(recurrence.interval, 1)
    let masterDay = calendar.startOfDay(for: masterStart)
    let lastDay = calendar.startOfDay(for: windowEnd)

    var day = calendar.startOfDay(for: windowStart)
    if day < masterDay {
        day = masterDay
    } else {
        let daysFromMaster = calendar.dateComponents([.day], from: masterDay, to: day).day ?? 0
        let remainder = daysFromMaster % interval
        if remainder != 0, let aligned = calendar.date(byAdding: .day, value: interval - remainder, to: day) {
            day = aligned
        }
    }

    var instances: [NormalizedCalendarEvent] = []
    while day < lastDay {
        if let untilDate, day > calendar.startOfDay(for: untilDate) { break }

        let occurrenceStart = combine(date: day, timeFrom: masterStart, calendar: calendar)
        let occurrenceEnd = occurrenceStart.addingTimeInterval(duration)

        if occurrenceEnd > windowStart && occurrenceStart < windowEnd {
            if let instance = makeInstance(
                from: event,
                occurrenceStart: occurrenceStart,
                occurrenceEnd: occurrenceEnd,
                calendar: calendar
            ) {
                instances.append(instance)
                if instances.count >= maxInstancesPerSeries { return instances }
            }
        }

        guard let nextDay = calendar.date(byAdding: .day, value: interval, to: day) else { break }
        day = nextDay
    }

    return instances
}

private func generateWeeklyInstances(
    event: NormalizedCalendarEvent,
    recurrence: CalendarRecurrence,
    masterStart: Date,
    duration: TimeInterval,
    from windowStart: Date,
    to windowEnd: Date,
    calendar: Calendar
) -> [NormalizedCalendarEvent] {
    generateRecurrenceInstancesByDay(
        event: event,
        recurrence: recurrence,
        masterStart: masterStart,
        duration: duration,
        from: windowStart,
        to: windowEnd,
        calendar: calendar
    )
}

private func generateRecurrenceInstancesByDay(
    event: NormalizedCalendarEvent,
    recurrence: CalendarRecurrence,
    masterStart: Date,
    duration: TimeInterval,
    from windowStart: Date,
    to windowEnd: Date,
    calendar: Calendar
) -> [NormalizedCalendarEvent] {
    let untilDate = ActiveSyncDateParser.parse(recurrence.until)
    let maxOccurrences = recurrence.occurrences
    let interval = max(recurrence.interval, 1)

    var instances: [NormalizedCalendarEvent] = []
    var occurrenceIndex = 0

    let windowDay = calendar.startOfDay(for: windowStart)
    let lastDay = calendar.startOfDay(for: windowEnd)
    var day = calendar.date(byAdding: .day, value: -1, to: windowDay) ?? windowDay

    while day < lastDay {
        if let untilDate, day > calendar.startOfDay(for: untilDate) {
            break
        }

        if let maxOccurrences, occurrenceIndex >= maxOccurrences {
            break
        }

        if matchesRecurrence(day: day, masterStart: masterStart, recurrence: recurrence, calendar: calendar) {
            let occurrenceStart = combine(date: day, timeFrom: masterStart, calendar: calendar)
            let occurrenceEnd = occurrenceStart.addingTimeInterval(duration)

            if occurrenceEnd > windowStart && occurrenceStart < windowEnd {
                if let instance = makeInstance(
                    from: event,
                    occurrenceStart: occurrenceStart,
                    occurrenceEnd: occurrenceEnd,
                    calendar: calendar
                ) {
                    instances.append(instance)
                    if instances.count >= maxInstancesPerSeries {
                        return instances
                    }
                }
            }

            occurrenceIndex += 1
        }

        guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day) else { break }
        day = nextDay
    }

    return instances
}

private func matchesRecurrence(
    day: Date,
    masterStart: Date,
    recurrence: CalendarRecurrence,
    calendar: Calendar
) -> Bool {
    let masterDay = calendar.startOfDay(for: masterStart)
    if day < masterDay { return false }

    let interval = max(recurrence.interval, 1)

    switch recurrence.type {
    case "0":
        let days = calendar.dateComponents([.day], from: masterDay, to: day).day ?? 0
        return days % interval == 0

    case "1":
        let mask = (recurrence.dayOfWeek ?? 0) > 0
            ? recurrence.dayOfWeek!
            : activeSyncWeekdayBitValue(for: calendar.component(.weekday, from: masterStart))

        guard activeSyncWeekdayBit(for: calendar.component(.weekday, from: day), mask: mask) else {
            return false
        }

        let weeksDiff = weekOrdinal(day, calendar: calendar) - weekOrdinal(masterDay, calendar: calendar)
        return weeksDiff >= 0 && weeksDiff % interval == 0

    case "2":
        guard let dayOfMonth = recurrence.dayOfMonth else { return false }
        guard calendar.component(.day, from: day) == dayOfMonth else { return false }
        let months = calendar.dateComponents([.month], from: masterDay, to: day).month ?? 0
        return months >= 0 && months % interval == 0

    case "3":
        return matchesRelativeMonthly(day: day, masterStart: masterStart, recurrence: recurrence, calendar: calendar)

    case "5":
        guard let dayOfMonth = recurrence.dayOfMonth,
              let monthOfYear = recurrence.monthOfYear else { return false }
        let components = calendar.dateComponents([.month, .day], from: day)
        guard components.month == monthOfYear, components.day == dayOfMonth else { return false }
        let years = calendar.dateComponents([.year], from: masterDay, to: day).year ?? 0
        return years >= 0 && years % interval == 0

    case "6":
        return matchesRelativeYearly(day: day, masterStart: masterStart, recurrence: recurrence, calendar: calendar)

    default:
        if let mask = recurrence.dayOfWeek, mask > 0 {
            guard activeSyncWeekdayBit(for: calendar.component(.weekday, from: day), mask: mask) else {
                return false
            }
            let weeksDiff = weekOrdinal(day, calendar: calendar) - weekOrdinal(masterDay, calendar: calendar)
            return weeksDiff >= 0 && weeksDiff % interval == 0
        }
        return calendar.isDate(day, inSameDayAs: masterStart)
    }
}

private func weekOrdinal(_ date: Date, calendar: Calendar) -> Int {
    let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
    return (components.yearForWeekOfYear ?? 0) * 100 + (components.weekOfYear ?? 0)
}

private func activeSyncWeekdayBitValue(for weekday: Int) -> Int {
    switch weekday {
    case 1: return 1
    case 2: return 2
    case 3: return 4
    case 4: return 8
    case 5: return 16
    case 6: return 32
    case 7: return 64
    default: return 0
    }
}

private func activeSyncWeekdayBit(for weekday: Int, mask: Int) -> Bool {
    (mask & activeSyncWeekdayBitValue(for: weekday)) != 0
}

private func matchesRelativeMonthly(
    day: Date,
    masterStart: Date,
    recurrence: CalendarRecurrence,
    calendar: Calendar
) -> Bool {
    guard let mask = recurrence.dayOfWeek,
          let weekOfMonth = recurrence.weekOfMonth else { return false }

    let interval = max(recurrence.interval, 1)
    let masterDay = calendar.startOfDay(for: masterStart)
    let months = calendar.dateComponents([.month], from: masterDay, to: day).month ?? 0
    guard months >= 0, months % interval == 0 else { return false }

    guard activeSyncWeekdayBit(for: calendar.component(.weekday, from: day), mask: mask) else {
        return false
    }

    return weekOfMonthInMonth(day: day, weekOfMonth: weekOfMonth, calendar: calendar)
}

private func matchesRelativeYearly(
    day: Date,
    masterStart: Date,
    recurrence: CalendarRecurrence,
    calendar: Calendar
) -> Bool {
    guard let mask = recurrence.dayOfWeek,
          let weekOfMonth = recurrence.weekOfMonth,
          let monthOfYear = recurrence.monthOfYear else { return false }

    let interval = max(recurrence.interval, 1)
    let masterDay = calendar.startOfDay(for: masterStart)
    let years = calendar.dateComponents([.year], from: masterDay, to: day).year ?? 0
    guard years >= 0, years % interval == 0 else { return false }
    guard calendar.component(.month, from: day) == monthOfYear else { return false }
    guard activeSyncWeekdayBit(for: calendar.component(.weekday, from: day), mask: mask) else { return false }

    return weekOfMonthInMonth(day: day, weekOfMonth: weekOfMonth, calendar: calendar)
}

private func weekOfMonthInMonth(day: Date, weekOfMonth: Int, calendar: Calendar) -> Bool {
    if weekOfMonth == 5 {
        guard let nextMonth = calendar.date(byAdding: .month, value: 1, to: calendar.startOfDay(for: day)),
              let lastDay = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: nextMonth)) else {
            return false
        }
        let weekday = calendar.component(.weekday, from: day)
        guard calendar.component(.weekday, from: lastDay) == weekday else { return false }
        guard let nextWeek = calendar.date(byAdding: .day, value: 7, to: day) else { return true }
        return nextWeek > lastDay
    }

    let week = calendar.component(.weekOfMonth, from: day)
    return week == weekOfMonth
}

private func combine(date day: Date, timeFrom reference: Date, calendar: Calendar) -> Date {
    let time = calendar.dateComponents([.hour, .minute, .second], from: reference)
    var components = calendar.dateComponents([.year, .month, .day], from: day)
    components.hour = time.hour
    components.minute = time.minute
    components.second = time.second
    return calendar.date(from: components) ?? day
}

private func matchingException(
    for occurrenceStart: Date,
    in exceptions: [CalendarException],
    calendar: Calendar
) -> CalendarException? {
    exceptions.first { exception in
        guard let exceptionStart = ActiveSyncDateParser.parse(exception.exceptionStartAt) else { return false }
        return calendar.isDate(exceptionStart, equalTo: occurrenceStart, toGranularity: .minute)
            || calendar.isDate(exceptionStart, inSameDayAs: occurrenceStart)
    }
}

private func makeInstance(
    from event: NormalizedCalendarEvent,
    occurrenceStart: Date,
    occurrenceEnd: Date,
    calendar: Calendar
) -> NormalizedCalendarEvent? {
    if let exception = matchingException(for: occurrenceStart, in: event.exceptions, calendar: calendar) {
        if exception.deleted { return nil }

        let start = ActiveSyncDateParser.parse(exception.startAt) ?? occurrenceStart
        let end = ActiveSyncDateParser.parse(exception.endAt) ?? occurrenceEnd
        return event.asInstance(
            serverId: "\(event.serverId)-\(Int(occurrenceStart.timeIntervalSince1970))",
            startAt: ActiveSyncDateParser.format(start),
            endAt: ActiveSyncDateParser.format(end),
            title: exception.title.isEmpty ? event.title : exception.title,
            location: exception.location.isEmpty ? event.location : exception.location,
            description: exception.description.isEmpty ? event.description : exception.description,
            allDay: exception.allDay ?? event.allDay
        )
    }

    return event.asInstance(
        serverId: "\(event.serverId)-\(Int(occurrenceStart.timeIntervalSince1970))",
        startAt: ActiveSyncDateParser.format(occurrenceStart),
        endAt: ActiveSyncDateParser.format(occurrenceEnd)
    )
}

private extension NormalizedCalendarEvent {
    func asInstance(
        serverId: String,
        startAt: String,
        endAt: String,
        title: String? = nil,
        location: String? = nil,
        description: String? = nil,
        allDay: Bool? = nil
    ) -> NormalizedCalendarEvent {
        NormalizedCalendarEvent(
            serverId: serverId,
            uid: uid,
            title: title ?? self.title,
            description: description ?? self.description,
            location: location ?? self.location,
            startAt: startAt,
            endAt: endAt,
            allDay: allDay ?? self.allDay,
            timeZone: timeZone,
            recurrence: nil,
            exceptions: [],
            attendees: attendees,
            organizer: organizer,
            reminderMinutes: reminderMinutes,
            responseStatus: responseStatus,
            source: source,
            instanceType: "2"
        )
    }
}
