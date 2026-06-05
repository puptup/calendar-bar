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

        let folderSyncXml = try await executeCommand("FolderSync", xml: buildFolderSyncRequestXml(syncKey: "0"))
        let folderSync = parseFolderSyncXml(folderSyncXml)
        let calendarFolder = findCalendarFolder(folderSync.folders)

        if folderSync.status == "108", !deviceIdRetry {
            settings.deviceId = AccountSettings.generateDeviceId()
            return try await getCalendarEvents(
                maxPages: maxPages,
                windowSize: windowSize,
                reprovisionAttempts: reprovisionAttempts,
                deviceIdRetry: true,
                folderResyncAttempts: folderResyncAttempts
            )
        }

        if folderSync.status == "142" || folderSync.status == "144" {
            if reprovisionAttempts >= 1 {
                throw ExchangeError.activeSync("FolderSync failed with ActiveSync status \(folderSync.status) after reprovision retry.")
            }
            try await performProvisioning()
            return try await getCalendarEvents(maxPages: maxPages, windowSize: windowSize, reprovisionAttempts: reprovisionAttempts + 1, deviceIdRetry: deviceIdRetry, folderResyncAttempts: folderResyncAttempts)
        }

        guard folderSync.status == "1" else {
            let hint = activeSyncStatusHint(folderSync.status)
            throw ExchangeError.activeSync("FolderSync failed with ActiveSync status \(folderSync.status). \(hint)")
        }

        guard let calendarFolder else {
            throw ExchangeError.activeSync("Calendar folder not found in FolderSync response.")
        }

        do {
            var events = try await syncCalendarFolder(calendarFolder, maxPages: maxPages, windowSize: windowSize)

            if let inboxFolder = findInboxFolder(folderSync.folders) {
                let invitations = try await syncInboxMeetingRequests(inboxFolder, maxPages: maxPages, windowSize: 100)
                events = mergeCalendarEventsWithInvitations(calendarEvents: events, inboxInvitations: invitations)
            }

            return events
        } catch ExchangeError.folderResyncRequired {
            guard folderResyncAttempts < 1 else {
                throw ExchangeError.activeSync("Calendar Sync failed: folder resync exceeded retry limit.")
            }
            ActiveSyncSyncKeyStore.shared.reset(accountKey: accountStorageKey)
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
            let parsed = parseInboxSyncXml(xml)
            let status = parsed.status

            if status.isEmpty || status == "1" {
                return InboxSyncPageResult(
                    syncKey: parsed.syncKey,
                    meetingRequests: parsed.meetingRequests,
                    moreAvailable: parsed.moreAvailable,
                    failure: nil
                )
            }

            if ActiveSyncSyncStatus.requiresFullResync(status) {
                return InboxSyncPageResult(syncKey: parsed.syncKey, meetingRequests: [], moreAvailable: false, failure: .fullResync)
            }

            if ActiveSyncSyncStatus.requiresFolderResync(status) {
                return InboxSyncPageResult(syncKey: parsed.syncKey, meetingRequests: [], moreAvailable: false, failure: .folderResync)
            }

            if ActiveSyncSyncStatus.isTransient(status), transientAttempt == 0 {
                try await Task.sleep(nanoseconds: 500_000_000)
                continue
            }

            return InboxSyncPageResult(syncKey: parsed.syncKey, meetingRequests: [], moreAvailable: false, failure: .fatal(status))
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

        throw ExchangeError.activeSync("Unable to discover a working ActiveSync endpoint.")
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
            throw ExchangeError.activeSync("Network or TLS failure calling \(command): \(error.localizedDescription)")
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
