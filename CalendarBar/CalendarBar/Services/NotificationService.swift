import Foundation
import AppKit
import UserNotifications

enum NotificationAuthorizationState: Equatable {
    case authorized
    case denied
    case notDetermined
}

@MainActor
final class NotificationService: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationService()

    static let eventCategoryIdentifier = "CALENDAR_EVENT"
    static let mailCategoryIdentifier = "MAIL_MESSAGE"

    @Published private(set) var isAuthorized = false
    @Published private(set) var authorizationState: NotificationAuthorizationState = .notDetermined
    @Published private(set) var scheduledCount = 0

    private let defaults = UserDefaults.standard
    private let deliveredReminderKeysKey = "deliveredCalendarReminderKeys"

    private override init() {
        super.init()
    }

    func configure() {
        UNUserNotificationCenter.current().delegate = self
        registerCategories()
    }

    func registerCategories() {
        let dismissAction = UNNotificationAction(
            identifier: "DISMISS",
            title: "Скрыть",
            options: [.destructive]
        )
        let category = UNNotificationCategory(
            identifier: Self.eventCategoryIdentifier,
            actions: [dismissAction],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        let mailCategory = UNNotificationCategory(
            identifier: Self.mailCategoryIdentifier,
            actions: [dismissAction],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        UNUserNotificationCenter.current().setNotificationCategories([category, mailCategory])
    }

    func refreshAuthorizationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            authorizationState = .authorized
            isAuthorized = true
        case .denied:
            authorizationState = .denied
            isAuthorized = false
        case .notDetermined:
            authorizationState = .notDetermined
            isAuthorized = false
        @unknown default:
            authorizationState = .denied
            isAuthorized = false
        }
    }

    func requestAuthorization() async {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            isAuthorized = granted
            await refreshAuthorizationStatus()
        } catch {
            isAuthorized = false
            authorizationState = .denied
        }
    }

    func openSystemNotificationSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.notifications",
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    func scheduleNotifications(for events: [CalendarEvent], minutesBefore: Int) async {
        await refreshAuthorizationStatus()

        let center = UNUserNotificationCenter.current()
        await removePendingCalendarNotifications(center: center)

        guard authorizationState == .authorized else {
            scheduledCount = 0
            return
        }

        let now = Date()
        let deliveredKeys = deliveredReminderKeys()
        var scheduledKeys = Set<String>()
        var scheduled = 0

        for event in events where event.startDate > now {
            let notifyAt = event.startDate.addingTimeInterval(-Double(minutesBefore * 60))
            let reminderKey = reminderKey(for: event, minutesBefore: minutesBefore)
            guard scheduledKeys.insert(reminderKey).inserted else {
                continue
            }
            guard notifyAt > now || !deliveredKeys.contains(reminderKey) else {
                continue
            }

            guard let trigger = makeTrigger(notifyAt: notifyAt, eventStart: event.startDate, now: now) else {
                continue
            }

            let content = UNMutableNotificationContent()
            content.title = event.subject
            content.body = notificationBody(for: event, minutesBefore: minutesBefore)
            content.sound = .default
            content.categoryIdentifier = Self.eventCategoryIdentifier
            content.userInfo = payload(for: event, minutesBefore: minutesBefore)
            applyPersistentNotificationOptions(to: content)

            let request = UNNotificationRequest(
                identifier: notificationIdentifier(for: event),
                content: content,
                trigger: trigger
            )

            do {
                try await center.add(request)
                if notifyAt <= now {
                    markReminderDelivered(reminderKey)
                }
                scheduled += 1
            } catch {
                continue
            }
        }

        scheduledCount = scheduled
    }

    func rescheduleFromCurrentEvents() async {
        await scheduleNotifications(
            for: CalendarSyncService.shared.events,
            minutesBefore: SettingsStore.shared.notifyMinutesBefore
        )
    }

    func deliverNewMailNotification(for message: MailMessage) async throws {
        await refreshAuthorizationStatus()
        guard authorizationState == .authorized else {
            throw ExchangeError.activeSync("Уведомления CalendarBar не разрешены в macOS.")
        }

        let content = UNMutableNotificationContent()
        content.title = message.displaySubject
        content.subtitle = message.from?.displayName ?? "Новое письмо"
        content.body = mailNotificationBody(for: message)
        content.sound = .default
        content.categoryIdentifier = Self.mailCategoryIdentifier
        content.userInfo = [
            "kind": "mail",
            "messageId": message.id,
            "folder": MailFolderKind.inbox.rawValue,
            "subject": message.displaySubject
        ]
        applyPersistentNotificationOptions(to: content)

        let request = UNNotificationRequest(
            identifier: mailNotificationIdentifier(for: message),
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )

        try await UNUserNotificationCenter.current().add(request)
    }

    func cancelAllPendingNotifications() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        scheduledCount = 0
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        if notification.request.content.categoryIdentifier == Self.eventCategoryIdentifier,
           let reminderKey = notification.request.content.userInfo["reminderKey"] as? String {
            markReminderDelivered(reminderKey)
        }
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.notification.request.content.categoryIdentifier == Self.eventCategoryIdentifier,
           let reminderKey = response.notification.request.content.userInfo["reminderKey"] as? String {
            markReminderDelivered(reminderKey)
        }

        if response.actionIdentifier == UNNotificationDismissActionIdentifier
            || response.actionIdentifier == "DISMISS" {
            center.removeDeliveredNotifications(withIdentifiers: [response.notification.request.identifier])
        } else if response.notification.request.content.categoryIdentifier == Self.mailCategoryIdentifier,
                  let messageId = response.notification.request.content.userInfo["messageId"] as? String {
            Task { @MainActor in
                MailSyncService.shared.focusMessage(id: messageId, folder: .inbox)
                MailStatusBarManager.shared.showPanel()
            }
        }
        completionHandler()
    }

    private func applyPersistentNotificationOptions(to content: UNMutableNotificationContent) {
        content.interruptionLevel = .timeSensitive
        content.relevanceScore = 1.0
    }

    private func notificationIdentifier(for event: CalendarEvent) -> String {
        "event-\(reminderKey(for: event, minutesBefore: SettingsStore.shared.notifyMinutesBefore))"
    }

    private func reminderKey(for event: CalendarEvent, minutesBefore: Int) -> String {
        let start = Int(event.startDate.timeIntervalSince1970)
        let subject = event.subject
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        let location = (event.location ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return "\(start)|\(minutesBefore)|\(subject.prefix(120))|\(location.prefix(80))"
    }

    private func mailNotificationIdentifier(for message: MailMessage) -> String {
        "mail-\(message.id)"
    }

    private func payload(for event: CalendarEvent, minutesBefore: Int) -> [AnyHashable: Any] {
        [
            "eventId": event.id,
            "minutesBefore": minutesBefore,
            "subject": event.subject,
            "subtitle": "Через \(minutesBefore) мин · \(event.durationText)",
            "location": event.location ?? "",
            "reminderKey": reminderKey(for: event, minutesBefore: minutesBefore),
        ]
    }

    private func removePendingCalendarNotifications(center: UNUserNotificationCenter) async {
        let pending = await center.pendingNotificationRequests()
        let calendarIds = pending
            .map(\.identifier)
            .filter { $0.hasPrefix("event-") }
        if !calendarIds.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: calendarIds)
        }
    }

    private func deliveredReminderKeys() -> Set<String> {
        Set(defaults.stringArray(forKey: deliveredReminderKeysKey) ?? [])
    }

    private func markReminderDelivered(_ key: String) {
        var keys = deliveredReminderKeys()
        keys.insert(key)
        defaults.set(Array(keys), forKey: deliveredReminderKeysKey)
    }

    private func makeTrigger(notifyAt: Date, eventStart: Date, now: Date) -> UNNotificationTrigger? {
        if notifyAt <= now {
            guard eventStart > now else { return nil }
            return UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        }

        let interval = notifyAt.timeIntervalSince(now)
        if interval < 7 * 24 * 3600 {
            return UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        }

        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: notifyAt
        )
        return UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
    }

    private func notificationBody(for event: CalendarEvent, minutesBefore: Int) -> String {
        var parts: [String] = []
        parts.append("Через \(minutesBefore) мин · \(event.durationText)")
        if let location = event.location, !location.isEmpty {
            parts.append(location)
        }
        return parts.joined(separator: "\n")
    }

    private func mailNotificationBody(for message: MailMessage) -> String {
        let text = message.displayBodyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "Откройте письмо в CalendarBar" }
        return String(text.prefix(180))
    }
}
