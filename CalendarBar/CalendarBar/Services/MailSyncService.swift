import AppKit
import Combine
import Foundation

@MainActor
final class MailSyncService: ObservableObject {
    static let shared = MailSyncService()

    @Published private(set) var messages: [MailMessage] = []
    @Published private(set) var syncState: SyncState = .idle
    @Published var selectedMessageId: String?
    @Published var actionError: String?
    @Published var selectedFolder: MailFolderKind = .inbox

    private var syncTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var syncInProgress = false
    private var pendingSync: (folder: MailFolderKind, notifyNew: Bool)?
    private var messagesByFolder: [MailFolderKind: [MailMessage]] = [:]
    private var knownInboxMessageIds = Set<String>()
    private var notifiedInboxMessageIds = Set<String>()
    private var inboxNotificationBaselineEstablished = false
    private let serviceStartDate = Date()

    private init() {
        Publishers.CombineLatest(SettingsStore.shared.$isLoggedIn, SettingsStore.shared.$mailEnabled)
            .sink { [weak self] loggedIn, mailEnabled in
                if loggedIn && mailEnabled {
                    MailStatusBarManager.shared.install()
                    self?.startPeriodicSync()
                } else {
                    self?.disableMail()
                }
            }
            .store(in: &cancellables)

        SettingsStore.shared.$syncIntervalMinutes
            .dropFirst()
            .sink { [weak self] _ in
                guard SettingsStore.shared.isLoggedIn else { return }
                self?.startPeriodicSync()
            }
            .store(in: &cancellables)
    }

    var threads: [MailThread] {
        Dictionary(grouping: messages, by: \.threadKey)
            .map { key, messages in
                MailThread(
                    id: key,
                    messages: messages.sorted { ($0.dateReceived ?? .distantPast) < ($1.dateReceived ?? .distantPast) }
                )
            }
            .sorted { ($0.latestMessage?.dateReceived ?? .distantPast) > ($1.latestMessage?.dateReceived ?? .distantPast) }
    }

    var unreadCount: Int {
        (messagesByFolder[.inbox] ?? messages).filter { !$0.isRead }.count
    }

    var selectedMessage: MailMessage? {
        guard let selectedMessageId else { return nil }
        return messages.first { $0.id == selectedMessageId }
    }

    func startPeriodicSync() {
        stopPeriodicSync()
        let interval = syncInterval
        syncTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.periodicSync() }
        }
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            await sync(folder: .inbox, notifyNew: false)
        }
    }

    func stopPeriodicSync() {
        syncTimer?.invalidate()
        syncTimer = nil
    }

    func disableMail() {
        stopPeriodicSync()
        messages = []
        messagesByFolder = [:]
        knownInboxMessageIds = []
        notifiedInboxMessageIds = []
        inboxNotificationBaselineEstablished = false
        selectedMessageId = nil
        selectedFolder = .inbox
        actionError = nil
        MailStatusBarManager.shared.updateTitle("")
        MailStatusBarManager.shared.uninstall()
    }

    private var syncInterval: TimeInterval {
        let minutes = SettingsStore.shared.syncIntervalMinutes
        return minutes <= 0 ? 30 : TimeInterval(minutes * 60)
    }

    func syncNow() async {
        await sync(folder: selectedFolder, notifyNew: true)
    }

    func syncInboxForNetworkRecovery() async {
        await sync(folder: .inbox, notifyNew: true)
    }

    func selectFolder(_ folder: MailFolderKind) {
        selectedFolder = folder
        selectedMessageId = nil
        messages = messagesByFolder[folder] ?? []
        Task { await sync(folder: folder, notifyNew: false) }
    }

    func focusMessage(id: String, folder: MailFolderKind = .inbox) {
        selectedFolder = folder
        messages = messagesByFolder[folder] ?? messages
        selectedMessageId = id
    }

    private func periodicSync() async {
        await sync(folder: .inbox, notifyNew: true)
        if selectedFolder != .inbox {
            await sync(folder: selectedFolder, notifyNew: false)
        }
    }

    private func sync(folder: MailFolderKind, notifyNew: Bool) async {
        let store = SettingsStore.shared
        guard store.isLoggedIn, let password = store.password else { return }
        guard !syncInProgress else {
            pendingSync = (folder, notifyNew)
            return
        }

        syncInProgress = true
        defer {
            syncInProgress = false
            if let pendingSync {
                self.pendingSync = nil
                Task { await sync(folder: pendingSync.folder, notifyNew: pendingSync.notifyNew) }
            }
        }

        syncState = .syncing
        actionError = nil

        do {
            let snapshot = try await ExchangeClient(settings: store.account, password: password).fetchMailMessages(folder: folder)
            let newUnreadMessages = newUnreadNotifications(from: snapshot, folder: folder, notifyNew: notifyNew)
            merge(snapshot: snapshot, folder: folder)
            syncState = .success(Date())
            refreshMenuBarTitle()
            for message in newUnreadMessages {
                await deliverNotification(for: message)
            }
        } catch {
            syncState = .failure(error.localizedDescription)
            actionError = error.localizedDescription
        }
    }

    func fetchFullBodyIfNeeded(for message: MailMessage) async {
        guard message.body?.isTruncated == true || message.body == nil else { return }
        await performAction {
            guard let password = SettingsStore.shared.password else { return }
            let client = ExchangeClient(settings: SettingsStore.shared.account, password: password)
            guard let body = try await client.fetchMessageBody(for: message) else { return }
            updateMessage(message.id) { $0.body = body }
        }
    }

    func setRead(_ message: MailMessage, read: Bool) async {
        await performAction {
            guard let password = SettingsStore.shared.password else { return }
            try await ExchangeClient(settings: SettingsStore.shared.account, password: password).setMessageRead(message, read: read)
            updateMessage(message.id) { $0.isRead = read }
            refreshMenuBarTitle()
        }
    }

    func reply(to message: MailMessage, body: String, replyAll: Bool) async {
        await performAction {
            guard let password = SettingsStore.shared.password else { return }
            try await ExchangeClient(settings: SettingsStore.shared.account, password: password)
                .reply(to: message, body: body, replyAll: replyAll)
            await syncNow()
        }
    }

    func forward(message: MailMessage, to rawRecipients: String, body: String) async {
        await performAction {
            guard let password = SettingsStore.shared.password else { return }
            let recipients = parseRecipients(rawRecipients)
            try await ExchangeClient(settings: SettingsStore.shared.account, password: password)
                .forward(message: message, to: recipients, body: body)
            await syncNow()
        }
    }

    func send(to rawRecipients: String, cc rawCc: String, subject: String, body: String) async {
        await performAction {
            guard let password = SettingsStore.shared.password else { return }
            try await ExchangeClient(settings: SettingsStore.shared.account, password: password)
                .sendMail(to: parseRecipients(rawRecipients), cc: parseRecipients(rawCc), subject: subject, body: body)
            await syncNow()
        }
    }

    func download(_ attachment: MailAttachment) async {
        await performAction {
            guard let password = SettingsStore.shared.password else { return }
            let result = try await ExchangeClient(settings: SettingsStore.shared.account, password: password).fetchAttachment(attachment)
            guard let data = result.data else {
                throw ExchangeError.activeSync("Вложение не содержит данных.")
            }
            let fileName = result.fileName?.isEmpty == false ? result.fileName! : attachment.displayName
            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            let url = (downloads ?? URL(fileURLWithPath: NSTemporaryDirectory())).appendingPathComponent(fileName)
            try data.write(to: url, options: .atomic)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    func refreshMenuBarTitle() {
        MailStatusBarManager.shared.updateTitle(unreadCount > 0 ? "\(unreadCount)" : "")
    }

    private func merge(snapshot: MailSyncSnapshot, folder: MailFolderKind) {
        var byId = Dictionary(uniqueKeysWithValues: (messagesByFolder[folder] ?? []).map { ($0.id, $0) })
        for deleted in snapshot.deletedServerIds {
            byId.removeValue(forKey: deleted)
        }
        for message in snapshot.messages {
            byId[message.id] = message
        }
        let folderMessages = byId.values.sorted { ($0.dateReceived ?? .distantPast) > ($1.dateReceived ?? .distantPast) }
        messagesByFolder[folder] = folderMessages
        if selectedFolder == folder {
            messages = folderMessages
        }
        if folder == .inbox {
            knownInboxMessageIds.formUnion(folderMessages.map(\.id))
            inboxNotificationBaselineEstablished = true
        }
    }

    private func newUnreadNotifications(from snapshot: MailSyncSnapshot, folder: MailFolderKind, notifyNew: Bool) -> [MailMessage] {
        guard notifyNew, folder == .inbox else { return [] }
        let previousMessages = Dictionary(uniqueKeysWithValues: (messagesByFolder[.inbox] ?? []).map { ($0.id, $0) })
        let existingIds = knownInboxMessageIds.union(previousMessages.keys)
        return snapshot.messages.filter { message in
            guard !message.isRead, !notifiedInboxMessageIds.contains(message.id) else { return false }
            if inboxNotificationBaselineEstablished {
                let isNewMessage = !existingIds.contains(message.id)
                let becameUnread = previousMessages[message.id]?.isRead == true
                return isNewMessage || becameUnread
            }
            guard let received = message.dateReceived else { return false }
            return received >= serviceStartDate
        }
    }

    private func deliverNotification(for message: MailMessage) async {
        do {
            try await NotificationService.shared.deliverNewMailNotification(for: message)
            notifiedInboxMessageIds.insert(message.id)
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func updateMessage(_ id: String, mutate: (inout MailMessage) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        mutate(&messages[index])
        messagesByFolder[selectedFolder] = messages
    }

    private func performAction(_ action: () async throws -> Void) async {
        actionError = nil
        do {
            try await action()
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func parseRecipients(_ raw: String) -> [MailAddress] {
        raw.split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { MailAddress(name: "", email: $0) }
    }
}
