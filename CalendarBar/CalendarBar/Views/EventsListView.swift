import SwiftUI
import AppKit

struct EventsListView: View {
    @ObservedObject private var sync = CalendarSyncService.shared
    @ObservedObject private var store = SettingsStore.shared
    @ObservedObject private var notifications = NotificationService.shared
    @State private var selectedEventId: String?
    @State private var showAbout = false
    @State private var selectedDay = Calendar.current.startOfDay(for: Date())

    private let calendar = Calendar.current

    var body: some View {
        mainList
            .background(Color.clear)
            .sheet(isPresented: $showAbout) {
                AboutView()
            }
    }

    private var mainList: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if sync.events.isEmpty {
                emptyState
            } else {
                HStack(alignment: .top, spacing: 0) {
                    DayTimelineView(
                        day: selectedDay,
                        events: events(on: selectedDay),
                        selectedEventId: $selectedEventId
                    )
                    .frame(width: PopoverMetrics.timelineWidth)

                    if let event = selectedEvent {
                        Divider()
                        EventDetailSidePanel(event: event, onClose: { selectedEventId = nil })
                            .frame(width: PopoverMetrics.detailWidth)
                            .transaction { $0.animation = nil }
                    }
                }
                .frame(maxHeight: .infinity)
                .onChange(of: sync.events.count) { _, _ in
                    requestTimelineScroll()
                }
                .onChange(of: selectedDay) { _, _ in
                    selectedEventId = nil
                }
            }
            Divider()
            footer
        }
        .frame(width: panelWidth, height: PopoverMetrics.height)
        .background(Color.clear)
        .animation(.easeInOut(duration: 0.2), value: selectedEventId != nil)
        .onAppear { updatePopoverSize() }
        .onChange(of: selectedEventId != nil) { _, _ in updatePopoverSize() }
    }

    private var panelWidth: CGFloat {
        PopoverMetrics.totalWidth(showingDetail: selectedEventId != nil)
    }

    private var selectedEvent: CalendarEvent? {
        guard let selectedEventId else { return nil }
        return events(on: selectedDay).first { $0.id == selectedEventId }
    }

    private var compactDateNavigation: some View {
        HStack(spacing: 0) {
            dayNavButton(
                systemImage: "chevron.left",
                isEnabled: canGoToPreviousDay,
                action: goToPreviousDay
            )

            Text(compactDayTitle)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(minWidth: 56, maxWidth: 88)

            dayNavButton(
                systemImage: "chevron.right",
                isEnabled: true,
                action: goToNextDay
            )
        }
    }

    private func dayNavButton(systemImage: String, isEnabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .frame(width: 32, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .foregroundStyle(isEnabled ? .primary : .tertiary)
    }

    private var toolbar: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(store.account.email.isEmpty ? "Календарь" : store.account.email)
                    .font(.headline)
                    .lineLimit(1)
                Text(sync.syncState.statusText)
                    .font(.caption)
                    .foregroundStyle(sync.syncState.isError ? .red : .secondary)
                if notifications.authorizationState == .denied {
                    Text("Уведомления отключены в macOS")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                } else if notifications.authorizationState == .notDetermined {
                    Text("Разрешите уведомления для CalendarBar")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }

            Spacer(minLength: 4)

            compactDateNavigation

            Button(action: { Task { await sync.syncNow() } }) {
                Image(systemName: "arrow.clockwise")
                    .font(.caption.weight(.semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Обновить")
            .disabled(sync.syncState == .syncing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "calendar")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Нет предстоящих событий")
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var footer: some View {
        HStack {
            Menu {
                Picker("Уведомление за", selection: $store.notifyMinutesBefore) {
                    Text("5 мин").tag(5)
                    Text("10 мин").tag(10)
                    Text("15 мин").tag(15)
                    Text("30 мин").tag(30)
                    Text("1 час").tag(60)
                }
                Divider()
                Button("Разрешить уведомления…") {
                    Task {
                        await notifications.requestAuthorization()
                        await notifications.rescheduleFromCurrentEvents()
                        if notifications.authorizationState == .denied {
                            notifications.openSystemNotificationSettings()
                        }
                    }
                }
                if notifications.authorizationState == .denied {
                    Button("Настройки уведомлений macOS…") {
                        notifications.openSystemNotificationSettings()
                    }
                } else if notifications.authorizationState == .authorized {
                    Button("Стиль «Предупреждения» в macOS…") {
                        notifications.openSystemNotificationSettings()
                    }
                }
                Divider()
                Toggle("Запускать при входе", isOn: Binding(
                    get: { store.launchAtLogin },
                    set: { store.setLaunchAtLogin($0) }
                ))
                Divider()
                Button("О приложении") {
                    showAbout = true
                }
                Divider()
                Button("Выйти из аккаунта", role: .destructive) {
                    store.logout()
                }
                Divider()
                Button("Закрыть CalendarBar") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: .command)
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)

            Spacer()

            if let status = sync.footerStatusText {
                Text(status)
                    .id(sync.statusRefreshTick)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var canGoToPreviousDay: Bool {
        !calendar.isDateInToday(selectedDay)
    }

    private var compactDayTitle: String {
        if calendar.isDateInToday(selectedDay) {
            return "Сегодня"
        }
        if calendar.isDateInTomorrow(selectedDay) {
            return "Завтра"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "d MMM"
        return formatter.string(from: selectedDay)
    }

    private func events(on day: Date) -> [CalendarEvent] {
        sync.events.filter { $0.occurs(on: day) }
    }

    private func goToPreviousDay() {
        guard canGoToPreviousDay,
              let previous = calendar.date(byAdding: .day, value: -1, to: selectedDay) else { return }
        selectedDay = calendar.startOfDay(for: previous)
    }

    private func goToNextDay() {
        guard let next = calendar.date(byAdding: .day, value: 1, to: selectedDay) else { return }
        selectedDay = calendar.startOfDay(for: next)
    }

    private func requestTimelineScroll() {
        NotificationCenter.default.post(name: .timelineScrollRequested, object: nil)
    }

    private func updatePopoverSize() {
        NotificationCenter.default.post(
            name: .popoverSizeChanged,
            object: nil,
            userInfo: ["width": panelWidth, "height": PopoverMetrics.height]
        )
    }
}

private extension SyncState {
    var isError: Bool {
        if case .failure = self { return true }
        return false
    }
}
