import Foundation
import Combine

@MainActor
final class CalendarSyncService: ObservableObject {
    static let shared = CalendarSyncService()

    @Published private(set) var events: [CalendarEvent] = []
    @Published private(set) var todayEvents: [CalendarEvent] = []
    @Published private(set) var syncState: SyncState = .idle
    @Published private(set) var statusRefreshTick = Date()

    private var syncTimer: Timer?
    private var menuBarRefreshTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var syncInProgress = false

    private init() {
        SettingsStore.shared.$isLoggedIn
            .sink { [weak self] loggedIn in
                if loggedIn {
                    self?.startPeriodicSync()
                } else {
                    self?.stopPeriodicSync()
                    self?.events = []
                    self?.todayEvents = []
                    StatusBarManager.shared.updateTitle("")
                }
                StatusBarManager.shared.updateIcon()
            }
            .store(in: &cancellables)

        SettingsStore.shared.$notifyMinutesBefore
            .dropFirst()
            .sink { _ in
                Task { @MainActor in
                    await NotificationService.shared.rescheduleFromCurrentEvents()
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

    func startPeriodicSync() {
        stopPeriodicSync()
        let interval = syncInterval
        syncTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.syncNow() }
        }
        menuBarRefreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshMenuBarTitle() }
        }
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            await syncNow()
        }
    }

    func stopPeriodicSync() {
        syncTimer?.invalidate()
        syncTimer = nil
        menuBarRefreshTimer?.invalidate()
        menuBarRefreshTimer = nil
    }

    private var syncInterval: TimeInterval {
        let minutes = SettingsStore.shared.syncIntervalMinutes
        return minutes <= 0 ? 30 : TimeInterval(minutes * 60)
    }

    func syncNow() async {
        let store = SettingsStore.shared
        guard store.isLoggedIn, let password = store.password else { return }
        guard !syncInProgress else { return }

        syncInProgress = true
        defer { syncInProgress = false }

        syncState = .syncing
        let account = store.account
        let accountKey = account.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        ActiveSyncSyncKeyStore.shared.updateCalendar("0", accountKey: accountKey)

        let start = Calendar.current.startOfDay(for: Date())
        let end = Calendar.current.date(byAdding: .day, value: 60, to: start) ?? start

        do {
            let fetched = try await Task.detached(priority: .userInitiated) {
                let client = ExchangeClient(settings: account, password: password)
                return try await client.fetchCalendarEvents(from: start, to: end)
            }.value

            let today = fetched.filter { $0.occurs(on: Date()) }
            events = fetched.filter(\.isUpcoming)
            todayEvents = today
            syncState = .success(Date())
            refreshMenuBarTitle()

            await NotificationService.shared.scheduleNotifications(
                for: events,
                minutesBefore: store.notifyMinutesBefore
            )
        } catch {
            syncState = .failure(error.localizedDescription)
        }
    }

    // MARK: - Menu bar

    var todayMeetingCount: Int {
        todayEvents.filter(\.isUpcoming).count
    }

    var nextTodayUpcoming: CalendarEvent? {
        todayEvents.filter(\.isFuture).sorted { $0.startDate < $1.startDate }.first
    }

    var footerStatusText: String? {
        guard let next = nextTodayUpcoming else { return nil }
        if next.isAllDay { return "Следующая встреча: весь день" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "HH:mm"
        return "Следующая встреча в \(formatter.string(from: next.startDate))"
    }

    var menuBarShowsSummary: Bool {
        todayMeetingCount > 0 && nextTodayUpcoming != nil
    }

    var menuBarCountText: String {
        guard todayMeetingCount > 0 else { return "" }
        return "\(todayMeetingCount)"
    }

    var menuBarTimeText: String {
        guard let next = nextTodayUpcoming else { return "" }
        if next.isAllDay { return "весь день" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: next.startDate)
    }

    var menuBarLabelText: String {
        guard menuBarShowsSummary else { return "" }
        return "\(menuBarCountText) · \(menuBarTimeText)"
    }

    func refreshMenuBarTitle() {
        statusRefreshTick = Date()
        StatusBarManager.shared.updateTitle(menuBarShowsSummary ? menuBarLabelText : "")
    }

    var nextEvent: CalendarEvent? {
        nextTodayUpcoming
    }

    func respond(to event: CalendarEvent, action: MeetingAction) async throws {
        let store = SettingsStore.shared
        guard store.isLoggedIn, let password = store.password else { return }
        try await ExchangeClient(settings: store.account, password: password)
            .respondToMeeting(eventId: event.id, action: action)
        await syncNow()
    }

    func delete(_ event: CalendarEvent) async throws {
        let store = SettingsStore.shared
        guard store.isLoggedIn, let password = store.password else { return }
        try await ExchangeClient(settings: store.account, password: password)
            .deleteCalendarEvent(eventId: event.id)
        events.removeAll { $0.id == event.id }
        todayEvents.removeAll { $0.id == event.id }
        await syncNow()
    }
}
