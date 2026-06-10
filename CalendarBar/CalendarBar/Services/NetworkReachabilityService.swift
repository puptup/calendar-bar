import Foundation
import Network

@MainActor
final class NetworkReachabilityService: ObservableObject {
    static let shared = NetworkReachabilityService()

    @Published private(set) var isOnline = true

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "CalendarBar.NetworkReachability")
    private var hasSeenInitialPath = false
    private var wasOffline = false
    private var recoverySyncInProgress = false

    private init() {}

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.handle(path)
            }
        }
        monitor.start(queue: queue)
    }

    func stop() {
        monitor.cancel()
    }

    private func handle(_ path: NWPath) {
        let online = path.status == .satisfied
        isOnline = online

        guard hasSeenInitialPath else {
            hasSeenInitialPath = true
            wasOffline = !online
            return
        }

        if !online {
            wasOffline = true
            return
        }

        guard wasOffline else { return }
        wasOffline = false
        triggerRecoverySync()
    }

    private func triggerRecoverySync() {
        guard SettingsStore.shared.isLoggedIn, !recoverySyncInProgress else { return }
        recoverySyncInProgress = true

        Task { @MainActor in
            await CalendarSyncService.shared.syncNow()
            if SettingsStore.shared.mailEnabled {
                await MailSyncService.shared.syncInboxForNetworkRecovery()
            }
            recoverySyncInProgress = false
        }
    }
}
