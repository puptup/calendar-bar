import Foundation

// MARK: - Types

struct FolderRecord {
    let serverId: String
    let parentId: String?
    let displayName: String
    let type: String
}

struct FolderSyncResult {
    let syncKey: String
    let status: String
    let folders: [FolderRecord]
}

struct CalendarOrganizer {
    let name: String
    let email: String
}

struct CalendarAttendee {
    let name: String
    let email: String
    let role: String
}

struct CalendarRecurrence {
    let type: String
    let interval: Int
    let occurrences: Int?
    let until: String
    let dayOfWeek: Int?
    let dayOfMonth: Int?
    let weekOfMonth: Int?
    let monthOfYear: Int?
}

struct CalendarException {
    let deleted: Bool
    let exceptionStartAt: String
    let startAt: String
    let endAt: String
    let title: String
    let location: String
    let allDay: Bool?
    let description: String
}

struct NormalizedCalendarEvent {
    let serverId: String
    let uid: String
    let title: String
    let description: String
    let location: String
    let startAt: String
    let endAt: String
    let allDay: Bool
    let timeZone: String?
    let recurrence: CalendarRecurrence?
    let exceptions: [CalendarException]
    let attendees: [CalendarAttendee]
    let organizer: CalendarOrganizer?
    let reminderMinutes: Int?
    let responseStatus: MeetingResponseStatus
    let source: EventSource
    let instanceType: String
}

enum EventSource: String, Codable {
    case calendar
    case inboxInvitation
}

struct ParsedInboxMeetingRequest {
    let serverId: String
    let subject: String
    let from: String
    let startTime: String
    let endTime: String
    let location: String
    let allDayEvent: String
    let globalObjId: String
    let bodyData: String
}

struct InboxSyncResult {
    let syncKey: String
    let status: String
    let moreAvailable: Bool
    let meetingRequests: [ParsedInboxMeetingRequest]
}

struct ParsedCalendarEvent {
    let serverId: String
    let applicationData: ParsedCalendarApplicationData
}

struct ParsedCalendarApplicationData {
    let subject: String
    let startTime: String
    let endTime: String
    let location: String
    let uid: String
    let allDayEvent: String
    let timeZone: String
    let bodyType: String
    let bodyData: String
    let reminder: String
    let recurrence: ParsedCalendarRecurrence?
    let organizerName: String
    let organizerEmail: String
    let meetingStatus: String
    let responseType: String
    let attendees: [(name: String, email: String, type: String)]
    let exceptions: [ParsedCalendarException]
    let instanceType: String
}

struct ParsedCalendarRecurrence {
    let type: String
    let interval: String
    let occurrences: String
    let until: String
    let dayOfWeek: String
    let dayOfMonth: String
    let weekOfMonth: String
    let monthOfYear: String
}

struct ParsedCalendarException {
    let deleted: Bool
    let exceptionStartTime: String
    let startTime: String
    let endTime: String
    let subject: String
    let location: String
    let allDayEvent: String
    let bodyType: String
    let bodyData: String
}

struct CalendarSyncResult {
    let syncKey: String
    let status: String
    let moreAvailable: Bool
    let events: [ParsedCalendarEvent]
}

struct ProvisionResponse {
    let status: String
    let policyType: String
    let policyStatus: String
    let policyKey: String
    let remoteWipe: Bool
}

struct ProvisionRequestConfig {
    let deviceModel: String
    let deviceImei: String
    let deviceFriendlyName: String
    let deviceOs: String
    let deviceOsLanguage: String
    let devicePhoneNumber: String
    let deviceMobileOperator: String
    let userAgent: String
}

// MARK: - XML helpers

func getFirstTagText(_ xml: String, _ tagName: String) -> String {
    let pattern = "<\(tagName)(?:\\s[^>]*)?>([\\s\\S]*?)</\(tagName)>"
    guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
          let match = regex.firstMatch(in: xml, range: NSRange(xml.startIndex..<xml.endIndex, in: xml)),
          let textRange = Range(match.range(at: 1), in: xml) else {
        return ""
    }
    return decodeXml(String(xml[textRange]).trimmingCharacters(in: .whitespacesAndNewlines))
}

func getAllTagBlocks(_ xml: String, _ tagName: String) -> [String] {
    let pattern = "<\(tagName)(?:\\s[^>]*)?>([\\s\\S]*?)</\(tagName)>"
    guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
        return []
    }
    let range = NSRange(xml.startIndex..<xml.endIndex, in: xml)
    return regex.matches(in: xml, range: range).compactMap { match in
        guard let blockRange = Range(match.range(at: 1), in: xml) else { return nil }
        return String(xml[blockRange])
    }
}

func hasSelfClosingTag(_ xml: String, _ tagName: String) -> Bool {
    let pattern = "<\(tagName)(?:\\s[^>]*)?\\s*/>"
    guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
        return false
    }
    let range = NSRange(xml.startIndex..<xml.endIndex, in: xml)
    return regex.firstMatch(in: xml, range: range) != nil
}

func decodeXml(_ value: String) -> String {
    value
        .replacingOccurrences(of: "&lt;", with: "<")
        .replacingOccurrences(of: "&gt;", with: ">")
        .replacingOccurrences(of: "&quot;", with: "\"")
        .replacingOccurrences(of: "&apos;", with: "'")
        .replacingOccurrences(of: "&amp;", with: "&")
}

// MARK: - Folder sync

func parseFolderSyncXml(_ xml: String) -> FolderSyncResult {
    let addBlocks = getAllTagBlocks(xml, "Add")
    return FolderSyncResult(
        syncKey: getFirstTagText(xml, "SyncKey"),
        status: getFirstTagText(xml, "Status"),
        folders: addBlocks.map { block in
            FolderRecord(
                serverId: getFirstTagText(block, "ServerId"),
                parentId: getFirstTagText(block, "ParentId").isEmpty ? nil : getFirstTagText(block, "ParentId"),
                displayName: getFirstTagText(block, "DisplayName"),
                type: getFirstTagText(block, "Type")
            )
        }
    )
}

func findCalendarFolder(_ folders: [FolderRecord]) -> FolderRecord? {
    folders.first(where: { $0.type == "8" })
        ?? folders.first(where: { $0.displayName.trimmingCharacters(in: .whitespaces).lowercased() == "calendar" })
        ?? folders.first(where: { $0.serverId.lowercased().contains("calendar") })
}

func findInboxFolder(_ folders: [FolderRecord]) -> FolderRecord? {
    folders.first(where: { $0.type == "2" })
        ?? folders.first(where: { $0.displayName.trimmingCharacters(in: .whitespaces).lowercased() == "inbox" })
        ?? folders.first(where: { $0.serverId.lowercased().contains("inbox") })
}

func buildFolderSyncRequestXml(syncKey: String = "0") -> String {
    "<?xml version=\"1.0\" encoding=\"utf-8\"?><FolderSync xmlns=\"FolderHierarchy:\"><SyncKey>\(escapeXml(syncKey))</SyncKey></FolderSync>"
}

// MARK: - Calendar sync

func parseCalendarSyncXml(_ xml: String) -> CalendarSyncResult {
    let collectionBlock = getAllTagBlocks(xml, "Collection").first ?? ""
    let commandBlocks = getAllTagBlocks(collectionBlock, "Add") + getAllTagBlocks(collectionBlock, "Change")

    return CalendarSyncResult(
        syncKey: getFirstTagText(collectionBlock, "SyncKey"),
        status: getFirstTagText(collectionBlock, "Status").isEmpty ? getFirstTagText(xml, "Status") : getFirstTagText(collectionBlock, "Status"),
        moreAvailable: hasSelfClosingTag(collectionBlock, "MoreAvailable"),
        events: commandBlocks.compactMap(parseCalendarSyncCommand)
    )
}

private func parseCalendarSyncCommand(_ xml: String) -> ParsedCalendarEvent? {
    let itemStatus = getFirstTagText(xml, "Status")
    if !itemStatus.isEmpty && itemStatus != "1" {
        return nil
    }

    let applicationData = getAllTagBlocks(xml, "ApplicationData").first ?? ""
    let bodyBlock = getAllTagBlocks(applicationData, "Body").first ?? ""
    let recurrenceBlock = getAllTagBlocks(applicationData, "Recurrence").first ?? ""
    let exceptionBlocks = getAllTagBlocks(applicationData, "Exception")

    let recurrence: ParsedCalendarRecurrence? = recurrenceBlock.isEmpty ? nil : ParsedCalendarRecurrence(
        type: getFirstTagText(recurrenceBlock, "Type"),
        interval: getFirstTagText(recurrenceBlock, "Interval"),
        occurrences: getFirstTagText(recurrenceBlock, "Occurrences"),
        until: getFirstTagText(recurrenceBlock, "Until"),
        dayOfWeek: getFirstTagText(recurrenceBlock, "DayOfWeek"),
        dayOfMonth: getFirstTagText(recurrenceBlock, "DayOfMonth"),
        weekOfMonth: getFirstTagText(recurrenceBlock, "WeekOfMonth"),
        monthOfYear: getFirstTagText(recurrenceBlock, "MonthOfYear")
    )

    return ParsedCalendarEvent(
        serverId: getFirstTagText(xml, "ServerId"),
        applicationData: ParsedCalendarApplicationData(
            subject: getFirstTagText(applicationData, "Subject"),
            startTime: getFirstTagText(applicationData, "StartTime"),
            endTime: getFirstTagText(applicationData, "EndTime"),
            location: getFirstTagText(applicationData, "Location"),
            uid: getFirstTagText(applicationData, "UID"),
            allDayEvent: getFirstTagText(applicationData, "AllDayEvent"),
            timeZone: getFirstTagText(applicationData, "TimeZone"),
            bodyType: getFirstTagText(bodyBlock, "Type"),
            bodyData: getFirstTagText(bodyBlock, "Data"),
            reminder: getFirstTagText(applicationData, "Reminder"),
            recurrence: recurrence,
            organizerName: getFirstTagText(applicationData, "OrganizerName"),
            organizerEmail: getFirstTagText(applicationData, "OrganizerEmail"),
            meetingStatus: getFirstTagText(applicationData, "MeetingStatus"),
            responseType: getFirstTagText(applicationData, "ResponseType"),
            attendees: getAllTagBlocks(applicationData, "Attendee").map { block in
                (name: getFirstTagText(block, "Name"), email: getFirstTagText(block, "Email"), type: getFirstTagText(block, "AttendeeType"))
            },
            exceptions: exceptionBlocks.map { block in
                let exceptionBody = getAllTagBlocks(block, "Body").first ?? ""
                return ParsedCalendarException(
                    deleted: getFirstTagText(block, "Deleted") == "1",
                    exceptionStartTime: getFirstTagText(block, "ExceptionStartTime"),
                    startTime: getFirstTagText(block, "StartTime"),
                    endTime: getFirstTagText(block, "EndTime"),
                    subject: getFirstTagText(block, "Subject"),
                    location: getFirstTagText(block, "Location"),
                    allDayEvent: getFirstTagText(block, "AllDayEvent"),
                    bodyType: getFirstTagText(exceptionBody, "Type"),
                    bodyData: getFirstTagText(exceptionBody, "Data")
                )
            },
            instanceType: getFirstTagText(applicationData, "InstanceType")
        )
    )
}

func buildCalendarSyncRequestXml(
    protocolVersion: String = "14.1",
    syncKey: String,
    collectionId: String,
    windowSize: Int = 50
) -> String {
    let classElement = usesLegacyClass(protocolVersion) ? "<Class>Calendar</Class>" : ""

    if syncKey == "0" {
        return "<?xml version=\"1.0\" encoding=\"utf-8\"?><Sync xmlns=\"AirSync:\"><Collections><Collection>\(classElement)<SyncKey>\(escapeXml(syncKey))</SyncKey><CollectionId>\(escapeXml(collectionId))</CollectionId></Collection></Collections></Sync>"
    }

    return "<?xml version=\"1.0\" encoding=\"utf-8\"?><Sync xmlns=\"AirSync:\" xmlns:airsyncbase=\"AirSyncBase:\"><Collections><Collection>\(classElement)<SyncKey>\(escapeXml(syncKey))</SyncKey><CollectionId>\(escapeXml(collectionId))</CollectionId><DeletesAsMoves>0</DeletesAsMoves><GetChanges>1</GetChanges><WindowSize>\(windowSize)</WindowSize><Options><FilterType>5</FilterType><airsyncbase:BodyPreference><airsyncbase:Type>1</airsyncbase:Type><airsyncbase:TruncationSize>32768</airsyncbase:TruncationSize></airsyncbase:BodyPreference></Options></Collection></Collections></Sync>"
}

func normalizeCalendarEvents(_ events: [ParsedCalendarEvent]) -> [NormalizedCalendarEvent] {
    events.map { event in
        let data = event.applicationData
        let reminder = Int(data.reminder)

        return NormalizedCalendarEvent(
            serverId: event.serverId,
            uid: data.uid.isEmpty ? event.serverId : data.uid,
            title: data.subject,
            description: data.bodyData,
            location: data.location,
            startAt: normalizeActiveSyncDateTime(data.startTime),
            endAt: normalizeActiveSyncDateTime(data.endTime),
            allDay: data.allDayEvent == "1",
            timeZone: decodeActiveSyncTimeZone(data.timeZone),
            recurrence: data.recurrence.map { r in
                CalendarRecurrence(
                    type: r.type,
                    interval: parseInteger(r.interval, fallback: 1),
                    occurrences: parseIntegerOptional(r.occurrences),
                    until: normalizeActiveSyncDateTime(r.until),
                    dayOfWeek: parseIntegerOptional(r.dayOfWeek),
                    dayOfMonth: parseIntegerOptional(r.dayOfMonth),
                    weekOfMonth: parseIntegerOptional(r.weekOfMonth),
                    monthOfYear: parseIntegerOptional(r.monthOfYear)
                )
            },
            exceptions: data.exceptions.map { ex in
                CalendarException(
                    deleted: ex.deleted,
                    exceptionStartAt: normalizeActiveSyncDateTime(ex.exceptionStartTime),
                    startAt: normalizeActiveSyncDateTime(ex.startTime),
                    endAt: normalizeActiveSyncDateTime(ex.endTime),
                    title: ex.subject,
                    location: ex.location,
                    allDay: ex.allDayEvent.isEmpty ? nil : ex.allDayEvent == "1",
                    description: ex.bodyData
                )
            },
            attendees: data.attendees.map { a in
                CalendarAttendee(name: a.name, email: a.email, role: normalizeAttendeeType(a.type))
            },
            organizer: (data.organizerEmail.isEmpty && data.organizerName.isEmpty)
                ? nil
                : CalendarOrganizer(name: data.organizerName, email: data.organizerEmail),
            reminderMinutes: reminder,
            responseStatus: mapResponseStatus(responseType: data.responseType, meetingStatus: data.meetingStatus),
            source: .calendar,
            instanceType: data.instanceType
        )
    }
}

func parseInboxSyncXml(_ xml: String) -> InboxSyncResult {
    let collectionBlock = getAllTagBlocks(xml, "Collection").first ?? ""
    let commandBlocks = getAllTagBlocks(collectionBlock, "Add") + getAllTagBlocks(collectionBlock, "Change")

    let meetingRequests = commandBlocks.compactMap(parseInboxMeetingRequest)

    return InboxSyncResult(
        syncKey: getFirstTagText(collectionBlock, "SyncKey"),
        status: getFirstTagText(collectionBlock, "Status").isEmpty ? getFirstTagText(xml, "Status") : getFirstTagText(collectionBlock, "Status"),
        moreAvailable: hasSelfClosingTag(collectionBlock, "MoreAvailable"),
        meetingRequests: meetingRequests
    )
}

private func parseInboxMeetingRequest(_ xml: String) -> ParsedInboxMeetingRequest? {
    let applicationData = getAllTagBlocks(xml, "ApplicationData").first ?? ""
    let messageClass = getFirstTagText(applicationData, "MessageClass")
    guard messageClass.localizedCaseInsensitiveContains("Meeting.Request") else { return nil }

    let meetingBlock = getAllTagBlocks(applicationData, "MeetingRequest").first ?? applicationData
    let bodyBlock = getAllTagBlocks(applicationData, "Body").first ?? ""
    let startTime = getFirstTagText(meetingBlock, "StartTime")
    guard !startTime.isEmpty else { return nil }

    return ParsedInboxMeetingRequest(
        serverId: getFirstTagText(xml, "ServerId"),
        subject: getFirstTagText(applicationData, "Subject"),
        from: getFirstTagText(applicationData, "From"),
        startTime: startTime,
        endTime: getFirstTagText(meetingBlock, "EndTime"),
        location: getFirstTagText(meetingBlock, "Location"),
        allDayEvent: getFirstTagText(meetingBlock, "AllDayEvent"),
        globalObjId: getFirstTagText(meetingBlock, "GlobalObjId"),
        bodyData: getFirstTagText(bodyBlock, "Data")
    )
}

func buildInboxSyncRequestXml(
    protocolVersion: String = "14.1",
    syncKey: String,
    collectionId: String,
    windowSize: Int = 100
) -> String {
    let classElement = usesLegacyClass(protocolVersion) ? "<Class>Email</Class>" : ""

    if syncKey == "0" {
        return "<?xml version=\"1.0\" encoding=\"utf-8\"?><Sync xmlns=\"AirSync:\"><Collections><Collection>\(classElement)<SyncKey>\(escapeXml(syncKey))</SyncKey><CollectionId>\(escapeXml(collectionId))</CollectionId></Collection></Collections></Sync>"
    }

    return "<?xml version=\"1.0\" encoding=\"utf-8\"?><Sync xmlns=\"AirSync:\" xmlns:airsyncbase=\"AirSyncBase:\"><Collections><Collection>\(classElement)<SyncKey>\(escapeXml(syncKey))</SyncKey><CollectionId>\(escapeXml(collectionId))</CollectionId><DeletesAsMoves>0</DeletesAsMoves><GetChanges>1</GetChanges><WindowSize>\(windowSize)</WindowSize><Options><FilterType>5</FilterType><airsyncbase:BodyPreference><airsyncbase:Type>1</airsyncbase:Type><airsyncbase:TruncationSize>20000</airsyncbase:TruncationSize></airsyncbase:BodyPreference></Options></Collection></Collections></Sync>"
}

func normalizeInboxMeetingRequests(_ requests: [ParsedInboxMeetingRequest]) -> [NormalizedCalendarEvent] {
    requests.map { request in
        let organizer = parseEmailContact(request.from)
        return NormalizedCalendarEvent(
            serverId: "inbox:\(request.serverId)",
            uid: request.globalObjId.isEmpty ? request.serverId : request.globalObjId,
            title: request.subject,
            description: request.bodyData,
            location: request.location,
            startAt: normalizeActiveSyncDateTime(request.startTime),
            endAt: normalizeActiveSyncDateTime(request.endTime.isEmpty ? request.startTime : request.endTime),
            allDay: request.allDayEvent == "1",
            timeZone: nil,
            recurrence: nil,
            exceptions: [],
            attendees: [],
            organizer: organizer,
            reminderMinutes: nil,
            responseStatus: .pending,
            source: .inboxInvitation,
            instanceType: ""
        )
    }
}

func mergeCalendarEventsWithInvitations(
    calendarEvents: [NormalizedCalendarEvent],
    inboxInvitations: [NormalizedCalendarEvent]
) -> [NormalizedCalendarEvent] {
    var merged = calendarEvents

    for invitation in inboxInvitations {
        let duplicate = merged.contains { existing in
            eventsMatch(existing, invitation)
        }
        if !duplicate {
            merged.append(invitation)
        }
    }

    return sortCalendarEventsByStart(merged)
}

private func eventsMatch(_ lhs: NormalizedCalendarEvent, _ rhs: NormalizedCalendarEvent) -> Bool {
    if !lhs.uid.isEmpty, lhs.uid == rhs.uid { return true }
    if !lhs.title.isEmpty,
       lhs.title.caseInsensitiveCompare(rhs.title) == .orderedSame,
       lhs.startAt == rhs.startAt {
        return true
    }
    return false
}

func mapResponseStatus(responseType: String, meetingStatus: String) -> MeetingResponseStatus {
    switch responseType {
    case "1": return .organizer
    case "2": return .tentative
    case "3": return .accepted
    case "4": return .declined
    case "5": return .pending
    default:
        if meetingStatus == "1" { return .organizer }
        if meetingStatus == "3" { return .pending }
        return .accepted
    }
}

private func parseEmailContact(_ raw: String) -> CalendarOrganizer? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    if let regex = try? NSRegularExpression(pattern: #"\"([^\"]+)\"\s*<([^>]+)>"#),
       let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)),
       let nameRange = Range(match.range(at: 1), in: trimmed),
       let emailRange = Range(match.range(at: 2), in: trimmed) {
        return CalendarOrganizer(name: String(trimmed[nameRange]), email: String(trimmed[emailRange]))
    }

    if trimmed.contains("@") {
        return CalendarOrganizer(name: trimmed, email: trimmed)
    }
    return CalendarOrganizer(name: trimmed, email: "")
}

func sortCalendarEventsByStart(_ events: [NormalizedCalendarEvent]) -> [NormalizedCalendarEvent] {
    events.sorted { left, right in
        let leftDate = ISO8601DateFormatter().date(from: left.startAt) ?? Date.distantPast
        let rightDate = ISO8601DateFormatter().date(from: right.startAt) ?? Date.distantPast
        return leftDate < rightDate
    }
}

// MARK: - Provision

private let policyType = "MS-EAS-Provisioning-WBXML"

func buildInitialProvisionRequestXml(_ config: ProvisionRequestConfig) -> String {
    """
    <?xml version="1.0" encoding="utf-8"?><Provision xmlns="Provision:" xmlns:settings="Settings:"><settings:DeviceInformation><settings:Set><settings:Model>\(escapeXml(config.deviceModel))</settings:Model><settings:IMEI>\(escapeXml(config.deviceImei))</settings:IMEI><settings:FriendlyName>\(escapeXml(config.deviceFriendlyName))</settings:FriendlyName><settings:OS>\(escapeXml(config.deviceOs))</settings:OS><settings:OSLanguage>\(escapeXml(config.deviceOsLanguage))</settings:OSLanguage><settings:PhoneNumber>\(escapeXml(config.devicePhoneNumber))</settings:PhoneNumber><settings:MobileOperator>\(escapeXml(config.deviceMobileOperator))</settings:MobileOperator><settings:UserAgent>\(escapeXml(config.userAgent))</settings:UserAgent></settings:Set></settings:DeviceInformation><Policies><Policy><PolicyType>\(policyType)</PolicyType></Policy></Policies></Provision>
    """
}

func buildProvisionAckRequestXml(policyKey: String, status: String = "1") -> String {
    "<?xml version=\"1.0\" encoding=\"utf-8\"?><Provision xmlns=\"Provision:\"><Policies><Policy><PolicyType>\(policyType)</PolicyType><PolicyKey>\(escapeXml(policyKey))</PolicyKey><Status>\(escapeXml(status))</Status></Policy></Policies></Provision>"
}

func parseProvisionResponseXml(_ xml: String) -> ProvisionResponse {
    let policyBlock: String
    if let regex = try? NSRegularExpression(pattern: "<Policy(?:\\s[^>]*)?>([\\s\\S]*?)</Policy>", options: .caseInsensitive),
       let match = regex.firstMatch(in: xml, range: NSRange(xml.startIndex..<xml.endIndex, in: xml)),
       let blockRange = Range(match.range(at: 1), in: xml) {
        policyBlock = String(xml[blockRange])
    } else {
        policyBlock = ""
    }

    return ProvisionResponse(
        status: getFirstTagText(xml, "Status"),
        policyType: getFirstTagText(policyBlock, "PolicyType"),
        policyStatus: getFirstTagText(policyBlock, "Status"),
        policyKey: getFirstTagText(policyBlock, "PolicyKey"),
        remoteWipe: xml.contains("<RemoteWipe")
    )
}

// MARK: - Helpers

private func usesLegacyClass(_ protocolVersion: String) -> Bool {
    ["2.5", "12.0", "12.1"].contains(protocolVersion)
}

private func normalizeActiveSyncDateTime(_ value: String) -> String {
    guard !value.isEmpty else { return "" }

    let compactPattern = #"^\d{8}T\d{6}Z?$"#
    if let regex = try? NSRegularExpression(pattern: compactPattern),
       regex.firstMatch(in: value, range: NSRange(value.startIndex..<value.endIndex, in: value)) != nil {
        let year = value.prefix(4)
        let month = value.dropFirst(4).prefix(2)
        let day = value.dropFirst(6).prefix(2)
        let hour = value.dropFirst(9).prefix(2)
        let minute = value.dropFirst(11).prefix(2)
        let second = value.dropFirst(13).prefix(2)
        return "\(year)-\(month)-\(day)T\(hour):\(minute):\(second).000Z"
    }

    if let date = ISO8601DateFormatter().date(from: value) {
        return date.ISO8601Format()
    }

    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) {
        return date.ISO8601Format()
    }

    return ""
}

private func parseInteger(_ value: String, fallback: Int) -> Int {
    Int(value) ?? fallback
}

private func parseIntegerOptional(_ value: String) -> Int? {
    guard !value.isEmpty else { return nil }
    return Int(value)
}

private func decodeActiveSyncTimeZone(_ value: String) -> String? {
    guard !value.isEmpty,
          let data = Data(base64Encoded: value),
          let decoded = String(data: data, encoding: .utf16LittleEndian) else {
        return nil
    }
    let cleaned = decoded.unicodeScalars.filter { $0.value > 31 }.map(Character.init)
    let result = String(cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
    return result.isEmpty ? nil : result
}

private func normalizeAttendeeType(_ type: String) -> String {
    if type == "2" { return "optional" }
    if type == "3" { return "resource" }
    return "required"
}

func escapeXml(_ value: String) -> String {
    value
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&apos;")
}
