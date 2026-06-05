import Foundation
import Combine

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private enum Keys {
        static let account = "accountSettings"
        static let isLoggedIn = "isLoggedIn"
        static let syncInterval = "syncIntervalMinutes"
        static let notifyMinutes = "notifyMinutesBefore"
    }

    @Published var account: AccountSettings {
        didSet { saveAccount() }
    }

    @Published var isLoggedIn: Bool {
        didSet { UserDefaults.standard.set(isLoggedIn, forKey: Keys.isLoggedIn) }
    }

    @Published var syncIntervalMinutes: Int {
        didSet { UserDefaults.standard.set(syncIntervalMinutes, forKey: Keys.syncInterval) }
    }

    @Published var notifyMinutesBefore: Int {
        didSet { UserDefaults.standard.set(notifyMinutesBefore, forKey: Keys.notifyMinutes) }
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Keys.account),
           var decoded = try? JSONDecoder().decode(AccountSettings.self, from: data) {
            if decoded.deviceId.isEmpty || !AccountSettings.isValidDeviceId(decoded.deviceId) {
                decoded.deviceId = AccountSettings.generateDeviceId()
            }
            account = decoded
        } else {
            account = .empty
        }
        isLoggedIn = UserDefaults.standard.bool(forKey: Keys.isLoggedIn)
        syncIntervalMinutes = UserDefaults.standard.object(forKey: Keys.syncInterval) as? Int ?? 5
        notifyMinutesBefore = UserDefaults.standard.object(forKey: Keys.notifyMinutes) as? Int ?? 15
    }

    private func saveAccount() {
        if let data = try? JSONEncoder().encode(account) {
            UserDefaults.standard.set(data, forKey: Keys.account)
        }
    }

    func logout() {
        ActiveSyncSyncKeyStore.shared.reset(accountKey: account.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        isLoggedIn = false
        KeychainService.deletePassword()
    }

    func saveCredentials(email: String, server: String, domain: String, username: String, password: String) throws {
        let deviceId = account.resolvedDeviceId.isEmpty || !AccountSettings.isValidDeviceId(account.deviceId)
            ? AccountSettings.generateDeviceId()
            : account.resolvedDeviceId
        account = AccountSettings(email: email, server: server, domain: domain, username: username, deviceId: deviceId)
        try KeychainService.savePassword(password)
        isLoggedIn = true
    }

    var password: String? {
        KeychainService.loadPassword()
    }
}
