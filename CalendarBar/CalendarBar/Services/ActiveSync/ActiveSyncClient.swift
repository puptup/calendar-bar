import Foundation

enum ExchangeError: LocalizedError {
    case invalidResponse
    case unauthorized
    case serverError(Int, String)
    case parseError
    case noEvents
    case activeSync(String)
    case folderResyncRequired

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Некорректный ответ сервера"
        case .unauthorized:
            return "Неверный логин или пароль"
        case .serverError(let code, _):
            return "Ошибка сервера (\(code))"
        case .parseError:
            return "Не удалось разобрать ответ календаря"
        case .noEvents:
            return "События не найдены"
        case .activeSync(let message):
            return message
        case .folderResyncRequired:
            return "Структура папок изменилась"
        }
    }
}

struct DiscoveryAttempt {
    let endpoint: String
    let status: Int?
    let code: String?
    let message: String?
}

struct DiscoveryResult {
    let endpoint: String
    let attempts: [DiscoveryAttempt]
}

final class ActiveSyncClient: NSObject, URLSessionDelegate, @unchecked Sendable {
    private var settings: AccountSettings
    private let password: String
    private var endpoint: String
    private var policyKey: String

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 120
        config.waitsForConnectivity = true
        config.httpShouldSetCookies = true
        config.httpCookieAcceptPolicy = .always
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    static let defaultUserAgent = "Apple-iPhone14C3/1704.10"
    static let defaultProtocolVersion = "14.1"
    static let defaultDeviceType = "iPhone"

    init(settings: AccountSettings, password: String) {
        self.settings = settings
        self.password = password
        self.endpoint = settings.activeSyncEndpoint
        self.policyKey = "0"
        super.init()
    }

    func testConnection() async throws {
        _ = try await getCalendarEvents(maxPages: 1, windowSize: 10)
    }

    func getCalendarEvents(maxPages: Int = 10, windowSize: Int = 50, reprovisionAttempts: Int = 0, deviceIdRetry: Bool = false, folderResyncAttempts: Int = 0) async throws -> [NormalizedCalendarEvent] {
        try await ensureEndpoint()

        if policyKey == "0" {
            try? await performProvisioning()
        }

        let folders = try await loadFolders(reprovisionAttempts: reprovisionAttempts, deviceIdRetry: deviceIdRetry)
        let calendarFolder = findCalendarFolder(folders)

        guard let calendarFolder else {
            throw ExchangeError.activeSync("Calendar folder not found in FolderSync response.")
        }

        do {
            var events = try await syncCalendarFolder(calendarFolder, maxPages: maxPages, windowSize: windowSize)

            if let inboxFolder = findInboxFolder(folders) {
                let invitations = try await syncInboxMeetingRequests(inboxFolder, maxPages: maxPages, windowSize: 100)
                events = mergeCalendarEventsWithInvitations(calendarEvents: events, inboxInvitations: invitations)
            }

            return events
        } catch ExchangeError.folderResyncRequired {
            guard folderResyncAttempts < 1 else {
                throw ExchangeError.activeSync("Calendar Sync failed: folder resync exceeded retry limit.")
            }
            ActiveSyncSyncKeyStore.shared.updateCalendar("0", accountKey: accountStorageKey)
            return try await getCalendarEvents(
                maxPages: maxPages,
                windowSize: windowSize,
                reprovisionAttempts: reprovisionAttempts,
                deviceIdRetry: deviceIdRetry,
                folderResyncAttempts: folderResyncAttempts + 1
            )
        }
    }

    private var accountStorageKey: String {
        settings.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func getInboxMessages(maxPages: Int = 5, windowSize: Int = 50, folderResyncAttempts: Int = 0) async throws -> MailSyncSnapshot {
        try await getMailMessages(folder: .inbox, maxPages: maxPages, windowSize: windowSize, folderResyncAttempts: folderResyncAttempts)
    }

    func getMailMessages(folder kind: MailFolderKind, maxPages: Int = 5, windowSize: Int = 50, folderResyncAttempts: Int = 0) async throws -> MailSyncSnapshot {
        try await ensureEndpoint()

        if policyKey == "0" {
            try? await performProvisioning()
        }

        let folders = try await loadFolders()
        guard let folder = findMailFolder(folders, kind: kind) else {
            throw ExchangeError.activeSync("Mail folder \(kind.title) not found in FolderSync response.")
        }

        do {
            return try await syncMailMessages(folder, maxPages: maxPages, windowSize: windowSize)
        } catch ExchangeError.folderResyncRequired {
            guard folderResyncAttempts < 1 else {
                throw ExchangeError.activeSync("\(kind.title) Sync failed: folder resync exceeded retry limit.")
            }
            ActiveSyncSyncKeyStore.shared.updateMailFolder("0", accountKey: accountStorageKey, collectionId: folder.serverId)
            if kind == .inbox {
                ActiveSyncSyncKeyStore.shared.updateInbox("0", accountKey: accountStorageKey)
            }
            return try await getMailMessages(folder: kind, maxPages: maxPages, windowSize: windowSize, folderResyncAttempts: folderResyncAttempts + 1)
        }
    }

    func fetchMessageBody(collectionId: String, serverId: String, preferredBodyType: MailBodyType = .html, reprovisionAttempts: Int = 0) async throws -> MailBody? {
        let xml = try await executeCommand(
            "ItemOperations",
            xml: buildItemOperationsFetchMessageXml(collectionId: collectionId, serverId: serverId, bodyType: preferredBodyType)
        )
        let result = parseItemOperationsFetchXml(xml)
        if commandNeedsReprovision(result.status), reprovisionAttempts < 1 {
            try await performProvisioning()
            return try await fetchMessageBody(
                collectionId: collectionId,
                serverId: serverId,
                preferredBodyType: preferredBodyType,
                reprovisionAttempts: reprovisionAttempts + 1
            )
        }
        guard result.status.isEmpty || result.status == "1" else {
            throw ExchangeError.activeSync("ItemOperations Fetch failed with ActiveSync status \(result.status).")
        }
        return result.body
    }

    func fetchAttachment(fileReference: String, reprovisionAttempts: Int = 0) async throws -> ItemOperationsFetchResult {
        let xml = try await executeCommand(
            "ItemOperations",
            xml: buildItemOperationsFetchAttachmentXml(fileReference: fileReference)
        )
        let result = parseItemOperationsFetchXml(xml)
        if commandNeedsReprovision(result.status), reprovisionAttempts < 1 {
            try await performProvisioning()
            return try await fetchAttachment(fileReference: fileReference, reprovisionAttempts: reprovisionAttempts + 1)
        }
        guard result.status.isEmpty || result.status == "1" else {
            throw ExchangeError.activeSync("Attachment fetch failed with ActiveSync status \(result.status).")
        }
        return result
    }

    func setMessageRead(collectionId: String, serverId: String, read: Bool, reprovisionAttempts: Int = 0) async throws {
        let syncKey = ActiveSyncSyncKeyStore.shared.mailFolderSyncKey(accountKey: accountStorageKey, collectionId: collectionId)
        guard syncKey != "0" else {
            throw ExchangeError.activeSync("Mail folder sync key is not ready yet. Refresh mail first.")
        }
        let xml = try await executeCommand(
            "Sync",
            xml: buildInboxReadChangeRequestXml(syncKey: syncKey, collectionId: collectionId, serverId: serverId, read: read)
        )
        let status = parseSyncCommandStatusXml(xml)
        if commandNeedsReprovision(status.status), reprovisionAttempts < 1 {
            try await performProvisioning()
            return try await setMessageRead(
                collectionId: collectionId,
                serverId: serverId,
                read: read,
                reprovisionAttempts: reprovisionAttempts + 1
            )
        }
        guard status.status.isEmpty || status.status == "1" else {
            throw ExchangeError.activeSync("Read state update failed with ActiveSync status \(status.status).")
        }
        if !status.syncKey.isEmpty {
            ActiveSyncSyncKeyStore.shared.updateMailFolder(status.syncKey, accountKey: accountStorageKey, collectionId: collectionId)
        }
    }

    func sendMail(to: [MailAddress], cc: [MailAddress], subject: String, body: String) async throws {
        let mime = buildMimeMessage(to: to, cc: cc, subject: subject, body: body)
        let xml = try await executeCommand(
            "SendMail",
            xml: buildSendMailRequestXml(clientId: UUID().uuidString, mime: mime)
        )
        let status = parseSimpleCommandStatusXml(xml)
        guard status.status.isEmpty || status.status == "1" else {
            throw ExchangeError.activeSync("SendMail failed with ActiveSync status \(status.status).")
        }
    }

    func smartReply(message: MailMessage, body: String, replyAll: Bool) async throws {
        let recipients = replyRecipients(for: message, replyAll: replyAll)
        let mime = buildMimeMessage(to: recipients.to, cc: recipients.cc, subject: replySubject(message.subject), body: body)
        let xml = try await executeCommand(
            "SmartReply",
            xml: buildSmartReplyRequestXml(collectionId: message.collectionId, serverId: message.serverId, mime: mime)
        )
        let status = parseSimpleCommandStatusXml(xml)
        guard status.status.isEmpty || status.status == "1" else {
            throw ExchangeError.activeSync("SmartReply failed with ActiveSync status \(status.status).")
        }
    }

    func smartForward(message: MailMessage, to: [MailAddress], body: String) async throws {
        let mime = buildMimeMessage(to: to, cc: [], subject: forwardSubject(message.subject), body: body)
        let xml = try await executeCommand(
            "SmartForward",
            xml: buildSmartForwardRequestXml(collectionId: message.collectionId, serverId: message.serverId, mime: mime)
        )
        let status = parseSimpleCommandStatusXml(xml)
        guard status.status.isEmpty || status.status == "1" else {
            throw ExchangeError.activeSync("SmartForward failed with ActiveSync status \(status.status).")
        }
    }

    func respondToMeeting(requestId: String, collectionId: String, action: MeetingAction) async throws {
        let xml = try await executeCommand(
            "MeetingResponse",
            xml: buildMeetingResponseRequestXml(requestId: requestId, collectionId: collectionId, action: action)
        )
        let status = parseSimpleCommandStatusXml(xml)
        guard status.status.isEmpty || status.status == "1" else {
            throw ExchangeError.activeSync("MeetingResponse failed with ActiveSync status \(status.status).")
        }
    }

    func respondToMeeting(serverId: String, action: MeetingAction) async throws {
        let folders = try await loadFolders()
        let isInboxInvitation = serverId.hasPrefix("inbox:")
        let requestId = isInboxInvitation ? String(serverId.dropFirst("inbox:".count)) : serverId
        let folder = isInboxInvitation ? findInboxFolder(folders) : findCalendarFolder(folders)
        guard let folder else {
            throw ExchangeError.activeSync("Exchange folder for meeting response was not found.")
        }
        try await respondToMeeting(requestId: requestId, collectionId: folder.serverId, action: action)
    }

    func deleteCalendarEvent(collectionId: String, serverId: String) async throws {
        let keys = ActiveSyncSyncKeyStore.shared.load(accountKey: accountStorageKey)
        guard keys.calendar != "0" else {
            throw ExchangeError.activeSync("Calendar sync key is not ready yet. Refresh calendar first.")
        }
        let xml = try await executeCommand(
            "Sync",
            xml: buildCalendarDeleteRequestXml(syncKey: keys.calendar, collectionId: collectionId, serverId: serverId)
        )
        let status = parseSyncCommandStatusXml(xml)
        guard status.status.isEmpty || status.status == "1" else {
            throw ExchangeError.activeSync("Calendar delete failed with ActiveSync status \(status.status).")
        }
        if !status.syncKey.isEmpty {
            ActiveSyncSyncKeyStore.shared.updateCalendar(status.syncKey, accountKey: accountStorageKey)
        }
    }

    func deleteCalendarEvent(serverId: String) async throws {
        let rawServerId = serverId.hasPrefix("inbox:") ? String(serverId.dropFirst("inbox:".count)) : serverId
        let folders = try await loadFolders()
        guard let calendarFolder = findCalendarFolder(folders) else {
            throw ExchangeError.activeSync("Calendar folder was not found.")
        }
        try await deleteCalendarEvent(collectionId: calendarFolder.serverId, serverId: rawServerId)
    }

    private func loadFolders(reprovisionAttempts: Int = 0, deviceIdRetry: Bool = false, transientRetry: Bool = false) async throws -> [FolderRecord] {
        try await ensureEndpoint()
        if policyKey == "0" {
            try? await performProvisioning()
        }
        let xml = try await executeCommand("FolderSync", xml: buildFolderSyncRequestXml(syncKey: "0"))
        let folderSync = parseFolderSyncXml(xml)

        if folderSync.status == "108", !deviceIdRetry {
            settings.deviceId = AccountSettings.generateDeviceId()
            return try await loadFolders(reprovisionAttempts: reprovisionAttempts, deviceIdRetry: true, transientRetry: transientRetry)
        }

        if folderSync.status == "142" || folderSync.status == "144" || folderSync.status == "6" {
            if folderSync.status == "6", !transientRetry {
                try? await Task.sleep(nanoseconds: 500_000_000)
                return try await loadFolders(reprovisionAttempts: reprovisionAttempts, deviceIdRetry: deviceIdRetry, transientRetry: true)
            }
            if reprovisionAttempts >= 1 {
                throw ExchangeError.activeSync("FolderSync failed with ActiveSync status \(folderSync.status) after reprovision retry.")
            }
            try await performProvisioning()
            return try await loadFolders(reprovisionAttempts: reprovisionAttempts + 1, deviceIdRetry: deviceIdRetry, transientRetry: transientRetry)
        }

        guard folderSync.status == "1" else {
            let hint = activeSyncStatusHint(folderSync.status)
            throw ExchangeError.activeSync("FolderSync failed with ActiveSync status \(folderSync.status). \(hint)")
        }
        return folderSync.folders
    }

    private func syncCalendarFolder(_ calendarFolder: FolderRecord, maxPages: Int, windowSize: Int) async throws -> [NormalizedCalendarEvent] {
        var fullResyncAttempts = 0
        let maxFullResyncs = 2

        while fullResyncAttempts <= maxFullResyncs {
            var events: [NormalizedCalendarEvent] = []
            var syncKey = "0"
            var needsFullResync = false

            for page in 0..<maxPages {
                let requestSyncKey = syncKey
                let parsed = try await performCalendarSyncPage(
                    syncKey: syncKey,
                    collectionId: calendarFolder.serverId,
                    windowSize: windowSize
                )

                if let failure = parsed.failure {
                    switch failure {
                    case .fullResync:
                        needsFullResync = true
                    case .folderResync:
                        throw ExchangeError.folderResyncRequired
                    case .fatal(let status):
                        throw ExchangeError.activeSync(
                            "Calendar Sync failed with ActiveSync status \(status). \(ActiveSyncSyncStatus.userMessage(for: status))"
                        )
                    }
                    break
                }

                syncKey = parsed.syncKey.isEmpty ? syncKey : parsed.syncKey
                ActiveSyncSyncKeyStore.shared.updateCalendar(syncKey, accountKey: accountStorageKey)
                events.append(contentsOf: normalizeCalendarEvents(parsed.events))

                if requestSyncKey == "0" && parsed.events.isEmpty && syncKey != "0" {
                    continue
                }

                if !parsed.moreAvailable {
                    break
                }
            }

            if needsFullResync {
                fullResyncAttempts += 1
                continue
            }

            return sortCalendarEventsByStart(events)
        }

        throw ExchangeError.activeSync("Calendar Sync failed after resync retries.")
    }

    private enum SyncFailureKind {
        case fullResync
        case folderResync
        case fatal(String)
    }

    private struct CalendarSyncPageResult {
        let syncKey: String
        let events: [ParsedCalendarEvent]
        let moreAvailable: Bool
        let failure: SyncFailureKind?
    }

    private func performCalendarSyncPage(syncKey: String, collectionId: String, windowSize: Int) async throws -> CalendarSyncPageResult {
        for transientAttempt in 0..<2 {
            let xml = try await executeCommand(
                "Sync",
                xml: buildCalendarSyncRequestXml(
                    protocolVersion: Self.defaultProtocolVersion,
                    syncKey: syncKey,
                    collectionId: collectionId,
                    windowSize: windowSize
                )
            )
            let parsed = parseCalendarSyncXml(xml)
            let status = parsed.status

            if status.isEmpty || status == "1" {
                return CalendarSyncPageResult(
                    syncKey: parsed.syncKey,
                    events: parsed.events,
                    moreAvailable: parsed.moreAvailable,
                    failure: nil
                )
            }

            if ActiveSyncSyncStatus.requiresFullResync(status) {
                return CalendarSyncPageResult(syncKey: parsed.syncKey, events: [], moreAvailable: false, failure: .fullResync)
            }

            if ActiveSyncSyncStatus.requiresFolderResync(status) {
                return CalendarSyncPageResult(syncKey: parsed.syncKey, events: [], moreAvailable: false, failure: .folderResync)
            }

            if ActiveSyncSyncStatus.isTransient(status), transientAttempt == 0 {
                try await Task.sleep(nanoseconds: 500_000_000)
                continue
            }

            return CalendarSyncPageResult(syncKey: parsed.syncKey, events: [], moreAvailable: false, failure: .fatal(status))
        }

        throw ExchangeError.activeSync("Calendar Sync failed after transient retries.")
    }

    private struct InboxSyncPageResult {
        let syncKey: String
        let meetingRequests: [ParsedInboxMeetingRequest]
        let messages: [MailMessage]
        let deletedServerIds: [String]
        let moreAvailable: Bool
        let failure: SyncFailureKind?
    }

    private func performInboxSyncPage(syncKey: String, collectionId: String, windowSize: Int) async throws -> InboxSyncPageResult {
        for transientAttempt in 0..<2 {
            let xml = try await executeCommand(
                "Sync",
                xml: buildInboxSyncRequestXml(
                    protocolVersion: Self.defaultProtocolVersion,
                    syncKey: syncKey,
                    collectionId: collectionId,
                    windowSize: windowSize
                )
            )
            let parsed = parseInboxSyncXml(xml, collectionIdFallback: collectionId)
            let status = parsed.status

            if status.isEmpty || status == "1" {
                return InboxSyncPageResult(
                    syncKey: parsed.syncKey,
                    meetingRequests: parsed.meetingRequests,
                    messages: parsed.messages,
                    deletedServerIds: parsed.deletedServerIds,
                    moreAvailable: parsed.moreAvailable,
                    failure: nil
                )
            }

            if ActiveSyncSyncStatus.requiresFullResync(status) {
                return InboxSyncPageResult(syncKey: parsed.syncKey, meetingRequests: [], messages: [], deletedServerIds: [], moreAvailable: false, failure: .fullResync)
            }

            if ActiveSyncSyncStatus.requiresFolderResync(status) {
                return InboxSyncPageResult(syncKey: parsed.syncKey, meetingRequests: [], messages: [], deletedServerIds: [], moreAvailable: false, failure: .folderResync)
            }

            if ActiveSyncSyncStatus.isTransient(status), transientAttempt == 0 {
                try await Task.sleep(nanoseconds: 500_000_000)
                continue
            }

            return InboxSyncPageResult(syncKey: parsed.syncKey, meetingRequests: [], messages: [], deletedServerIds: [], moreAvailable: false, failure: .fatal(status))
        }

        throw ExchangeError.activeSync("Inbox Sync failed after transient retries.")
    }

    private func syncInboxMeetingRequests(_ inboxFolder: FolderRecord, maxPages: Int, windowSize: Int) async throws -> [NormalizedCalendarEvent] {
        var fullResyncAttempts = 0
        let maxFullResyncs = 2

        while fullResyncAttempts <= maxFullResyncs {
            var requests: [ParsedInboxMeetingRequest] = []
            var syncKey = "0"
            var needsFullResync = false

            for page in 0..<maxPages {
                let requestSyncKey = syncKey
                let parsed = try await performInboxSyncPage(
                    syncKey: syncKey,
                    collectionId: inboxFolder.serverId,
                    windowSize: windowSize
                )

                if let failure = parsed.failure {
                    switch failure {
                    case .fullResync:
                        needsFullResync = true
                    case .folderResync:
                        throw ExchangeError.folderResyncRequired
                    case .fatal(let status):
                        throw ExchangeError.activeSync(
                            "Inbox Sync failed with ActiveSync status \(status). \(ActiveSyncSyncStatus.userMessage(for: status))"
                        )
                    }
                    break
                }

                syncKey = parsed.syncKey.isEmpty ? syncKey : parsed.syncKey
                requests.append(contentsOf: parsed.meetingRequests)

                if requestSyncKey == "0" && parsed.meetingRequests.isEmpty && syncKey != "0" {
                    continue
                }

                if !parsed.moreAvailable {
                    break
                }
            }

            if needsFullResync {
                fullResyncAttempts += 1
                continue
            }

            return normalizeInboxMeetingRequests(requests)
        }

        throw ExchangeError.activeSync("Inbox Sync failed after resync retries.")
    }

    private func syncMailMessages(_ mailFolder: FolderRecord, maxPages: Int, windowSize: Int) async throws -> MailSyncSnapshot {
        var fullResyncAttempts = 0
        let maxFullResyncs = 2

        while fullResyncAttempts <= maxFullResyncs {
            var messages: [MailMessage] = []
            var deletedServerIds: [String] = []
            var syncKey = ActiveSyncSyncKeyStore.shared.mailFolderSyncKey(accountKey: accountStorageKey, collectionId: mailFolder.serverId)
            var needsFullResync = false

            for _ in 0..<maxPages {
                let requestSyncKey = syncKey
                let parsed = try await performInboxSyncPage(
                    syncKey: syncKey,
                    collectionId: mailFolder.serverId,
                    windowSize: windowSize
                )

                if let failure = parsed.failure {
                    switch failure {
                    case .fullResync:
                        ActiveSyncSyncKeyStore.shared.updateMailFolder("0", accountKey: accountStorageKey, collectionId: mailFolder.serverId)
                        syncKey = "0"
                        needsFullResync = true
                    case .folderResync:
                        throw ExchangeError.folderResyncRequired
                    case .fatal(let status):
                        throw ExchangeError.activeSync(
                            "Inbox Sync failed with ActiveSync status \(status). \(ActiveSyncSyncStatus.userMessage(for: status))"
                        )
                    }
                    break
                }

                syncKey = parsed.syncKey.isEmpty ? syncKey : parsed.syncKey
                ActiveSyncSyncKeyStore.shared.updateMailFolder(syncKey, accountKey: accountStorageKey, collectionId: mailFolder.serverId)
                if findInboxFolder([mailFolder]) != nil {
                    ActiveSyncSyncKeyStore.shared.updateInbox(syncKey, accountKey: accountStorageKey)
                }
                messages.append(contentsOf: parsed.messages)
                deletedServerIds.append(contentsOf: parsed.deletedServerIds)

                if requestSyncKey == "0" && parsed.messages.isEmpty && parsed.deletedServerIds.isEmpty && syncKey != "0" {
                    continue
                }

                if !parsed.moreAvailable {
                    break
                }
            }

            if needsFullResync {
                fullResyncAttempts += 1
                continue
            }

            return MailSyncSnapshot(
                messages: messages.sorted { ($0.dateReceived ?? .distantPast) > ($1.dateReceived ?? .distantPast) },
                deletedServerIds: deletedServerIds
            )
        }

        throw ExchangeError.activeSync("Inbox Sync failed after resync retries.")
    }

    private func buildMimeMessage(to: [MailAddress], cc: [MailAddress], subject: String, body: String) -> String {
        var lines: [String] = [
            "To: \(formatAddresses(to))",
            "Subject: \(encodedHeader(subject))",
            "MIME-Version: 1.0",
            "Content-Type: text/plain; charset=utf-8",
            "Content-Transfer-Encoding: 8bit"
        ]
        if !cc.isEmpty {
            lines.insert("Cc: \(formatAddresses(cc))", at: 1)
        }
        lines.append("")
        lines.append(body)
        return lines.joined(separator: "\r\n")
    }

    private func formatAddresses(_ addresses: [MailAddress]) -> String {
        addresses
            .filter { !$0.email.isEmpty || !$0.name.isEmpty }
            .map { address in
                if address.email.isEmpty { return address.name }
                if address.name.isEmpty { return address.email }
                return "\"\(address.name.replacingOccurrences(of: "\"", with: ""))\" <\(address.email)>"
            }
            .joined(separator: ", ")
    }

    private func encodedHeader(_ value: String) -> String {
        guard value.canBeConverted(to: .ascii) else {
            return "=?utf-8?B?\(Data(value.utf8).base64EncodedString())?="
        }
        return value
    }

    private func replyRecipients(for message: MailMessage, replyAll: Bool) -> (to: [MailAddress], cc: [MailAddress]) {
        let selfEmail = settings.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let primary = message.replyTo.isEmpty ? message.from.map { [$0] } ?? [] : message.replyTo
        guard replyAll else { return (primary.filter { $0.email.lowercased() != selfEmail }, []) }

        let to = (primary + message.to).filter { $0.email.lowercased() != selfEmail }
        let cc = message.cc.filter { $0.email.lowercased() != selfEmail }
        return (dedupeAddresses(to), dedupeAddresses(cc))
    }

    private func dedupeAddresses(_ addresses: [MailAddress]) -> [MailAddress] {
        var seen = Set<String>()
        return addresses.filter { address in
            let key = address.email.isEmpty ? address.name.lowercased() : address.email.lowercased()
            return seen.insert(key).inserted
        }
    }

    private func commandNeedsReprovision(_ status: String) -> Bool {
        status == "142" || status == "144"
    }

    private func replySubject(_ subject: String) -> String {
        subject.lowercased().hasPrefix("re:") ? subject : "Re: \(subject)"
    }

    private func forwardSubject(_ subject: String) -> String {
        subject.lowercased().hasPrefix("fw:") || subject.lowercased().hasPrefix("fwd:") ? subject : "Fw: \(subject)"
    }

    func performProvisioning() async throws {
        let provisionConfig = ProvisionRequestConfig(
            deviceModel: Self.defaultDeviceType,
            deviceImei: "000000000000000",
            deviceFriendlyName: "CalendarBar iPhone",
            deviceOs: "iOS 18.0",
            deviceOsLanguage: "en-us",
            devicePhoneNumber: "0000000000",
            deviceMobileOperator: "Unknown",
            userAgent: Self.defaultUserAgent
        )

        let initialXml = try await executeCommand(
            "Provision",
            xml: buildInitialProvisionRequestXml(provisionConfig),
            policyKeyOverride: "0"
        )
        let initial = parseProvisionResponseXml(initialXml)

        guard initial.status == "1", !initial.policyKey.isEmpty else {
            throw ExchangeError.activeSync("Provision phase 1 failed.")
        }

        let ackXml = try await executeCommand(
            "Provision",
            xml: buildProvisionAckRequestXml(policyKey: initial.policyKey, status: "1"),
            policyKeyOverride: initial.policyKey
        )
        let ack = parseProvisionResponseXml(ackXml)

        guard ack.status == "1", ack.policyStatus == "1", !ack.policyKey.isEmpty else {
            throw ExchangeError.activeSync("Provision phase 2 failed.")
        }

        policyKey = ack.policyKey
    }

    // MARK: - HTTP

    private func ensureEndpoint() async throws {
        if !endpoint.isEmpty { return }
        let result = try await discoverEndpoint()
        endpoint = result.endpoint
    }

    private func discoverEndpoint() async throws -> DiscoveryResult {
        let candidates = createDiscoveryCandidates()
        var attempts: [DiscoveryAttempt] = []

        for candidate in candidates {
            var request = URLRequest(url: URL(string: candidate)!)
            request.httpMethod = "OPTIONS"
            request.timeoutInterval = 15
            request.setValue(Self.defaultUserAgent, forHTTPHeaderField: "User-Agent")
            request.setValue(Self.defaultProtocolVersion, forHTTPHeaderField: "MS-ASProtocolVersion")
            request.setValue(basicAuthHeader(), forHTTPHeaderField: "Authorization")

            do {
                let (_, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode
                attempts.append(DiscoveryAttempt(endpoint: candidate, status: status, code: nil, message: nil))

                if let status, [200, 401, 403, 451].contains(status) {
                    return DiscoveryResult(endpoint: candidate, attempts: attempts)
                }
            } catch {
                attempts.append(DiscoveryAttempt(
                    endpoint: candidate,
                    status: nil,
                    code: "network-error",
                    message: error.localizedDescription
                ))
            }
        }

        if let fallback = candidates.first {
            return DiscoveryResult(endpoint: fallback, attempts: attempts)
        }

        throw ExchangeError.activeSync("Не удалось определить ActiveSync endpoint.")
    }

    private func createDiscoveryCandidates() -> [String] {
        if !settings.activeSyncEndpoint.isEmpty {
            return [settings.activeSyncEndpoint]
        }

        var candidates: [String] = []
        let domain = settings.server.isEmpty ? settings.email.split(separator: "@").last.map(String.init) ?? "" : settings.server

        guard !domain.isEmpty else { return candidates }

        candidates.append(defaultEndpoint(for: domain))

        if !domain.hasPrefix("autodiscover.") {
            candidates.append(defaultEndpoint(for: "autodiscover.\(domain)"))
        }

        if !domain.hasPrefix("mail.") {
            candidates.append(defaultEndpoint(for: "mail.\(domain)"))
        }

        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }

    private func defaultEndpoint(for host: String) -> String {
        "https://\(host)/Microsoft-Server-ActiveSync"
    }

    private func executeCommand(_ command: String, xml: String, policyKeyOverride: String? = nil) async throws -> String {
        try await ensureEndpoint()

        let body = try WBXMLCodec.encode(xml)
        guard var components = URLComponents(string: endpoint) else {
            throw ExchangeError.invalidResponse
        }

        let deviceId = settings.resolvedDeviceId
        let user = settings.activeSyncUserParam

        guard !deviceId.isEmpty else {
            throw ExchangeError.activeSync("DeviceId отсутствует.")
        }
        guard !user.isEmpty else {
            throw ExchangeError.activeSync("Укажите email для синхронизации.")
        }

        var queryItems = [
            URLQueryItem(name: "Cmd", value: command),
            URLQueryItem(name: "User", value: user),
            URLQueryItem(name: "DeviceId", value: deviceId),
            URLQueryItem(name: "DeviceType", value: Self.defaultDeviceType)
        ]
        components.queryItems = queryItems

        guard let url = components.url else {
            throw ExchangeError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue(basicAuthHeader(), forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.ms-sync.wbxml", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.defaultProtocolVersion, forHTTPHeaderField: "MS-ASProtocolVersion")
        request.setValue(Self.defaultUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(policyKeyOverride ?? policyKey, forHTTPHeaderField: "X-MS-PolicyKey")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ExchangeError.activeSync(networkMessage(for: error))
        }

        guard let http = response as? HTTPURLResponse else {
            throw ExchangeError.invalidResponse
        }

        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 401 {
                throw ExchangeError.unauthorized
            }
            let classification = classifyHttpError(status: http.statusCode)
            throw ExchangeError.activeSync("ActiveSync \(command) failed with HTTP \(http.statusCode) (\(classification))")
        }

        return try WBXMLCodec.decode(data)
    }

    private func basicAuthHeader() -> String {
        let credentials = "\(settings.activeSyncAuthUsername):\(password)"
        let encoded = Data(credentials.utf8).base64EncodedString()
        return "Basic \(encoded)"
    }

    private func classifyHttpError(status: Int) -> String {
        switch status {
        case 401: return "bad-credentials"
        case 403: return "device-blocked"
        case 404: return "endpoint-not-found"
        default: return status >= 400 ? "protocol-error" : "unknown"
        }
    }

    private func networkMessage(for error: Error) -> String {
        let nsError = error as NSError
        switch nsError.code {
        case NSURLErrorNotConnectedToInternet,
             NSURLErrorNetworkConnectionLost,
             NSURLErrorTimedOut,
             NSURLErrorCannotFindHost,
             NSURLErrorCannotConnectToHost,
             NSURLErrorDNSLookupFailed:
            return error.localizedDescription
        default:
            return error.localizedDescription
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        if challenge.previousFailureCount > 2 {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        let credential = URLCredential(
            user: settings.activeSyncAuthUsername,
            password: password,
            persistence: .forSession
        )
        completionHandler(.useCredential, credential)
    }

    var currentDeviceId: String {
        settings.resolvedDeviceId
    }

    private func activeSyncStatusHint(_ status: String) -> String {
        switch status {
        case "108":
            return "Некорректный DeviceId. Попробуйте перезапустить приложение."
        case "109":
            return "Некорректный тип устройства."
        case "142", "144":
            return "Требуется повторная регистрация устройства."
        case "177":
            return "Достигнут лимит устройств на аккаунте. Удалите старые устройства в OWA."
        default:
            return ""
        }
    }
}
