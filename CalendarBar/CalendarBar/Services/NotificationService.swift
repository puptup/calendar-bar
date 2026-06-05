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

    @Published private(set) var isAuthorized = false
    @Published private(set) var authorizationState: NotificationAuthorizationState = .notDetermined
    @Published private(set) var scheduledCount = 0

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
        UNUserNotificationCenter.current().setNotificationCategories([category])
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
        center.removeAllPendingNotificationRequests()

        guard authorizationState == .authorized else {
            scheduledCount = 0
            return
        }

        let now = Date()
        var scheduled = 0

        for event in events where event.startDate > now {
            let notifyAt = event.startDate.addingTimeInterval(-Double(minutesBefore * 60))
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

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.actionIdentifier == UNNotificationDismissActionIdentifier
            || response.actionIdentifier == "DISMISS" {
            center.removeDeliveredNotifications(withIdentifiers: [response.notification.request.identifier])
        }
        completionHandler()
    }

    private func applyPersistentNotificationOptions(to content: UNMutableNotificationContent) {
        content.interruptionLevel = .timeSensitive
        content.relevanceScore = 1.0
    }

    private func notificationIdentifier(for event: CalendarEvent) -> String {
        "event-\(event.id)"
    }

    private func payload(for event: CalendarEvent, minutesBefore: Int) -> [AnyHashable: Any] {
        [
            "eventId": event.id,
            "minutesBefore": minutesBefore,
            "subject": event.subject,
            "subtitle": "Через \(minutesBefore) мин · \(event.durationText)",
            "location": event.location ?? "",
        ]
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
}
