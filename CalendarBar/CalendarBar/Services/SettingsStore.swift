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
        static let launchAtLogin = "launchAtLogin"
        static let mailEnabled = "mailEnabled"
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

    @Published private(set) var launchAtLogin = false

    @Published var mailEnabled: Bool {
        didSet { UserDefaults.standard.set(mailEnabled, forKey: Keys.mailEnabled) }
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
        let storedSyncInterval = UserDefaults.standard.object(forKey: Keys.syncInterval) as? Int ?? 5
        syncIntervalMinutes = storedSyncInterval <= 0 ? 5 : storedSyncInterval
        notifyMinutesBefore = UserDefaults.standard.object(forKey: Keys.notifyMinutes) as? Int ?? 15
        launchAtLogin = UserDefaults.standard.object(forKey: Keys.launchAtLogin) as? Bool ?? false
        mailEnabled = UserDefaults.standard.object(forKey: Keys.mailEnabled) as? Bool ?? true
    }

    func refreshLaunchAtLoginStatus() {
        launchAtLogin = LaunchAtLoginService.isEnabled
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLoginService.setEnabled(enabled)
            launchAtLogin = LaunchAtLoginService.isEnabled
            UserDefaults.standard.set(launchAtLogin, forKey: Keys.launchAtLogin)
        } catch {
            launchAtLogin = LaunchAtLoginService.isEnabled
        }
    }

    func applyLaunchAtLoginPreference() {
        let preferred = UserDefaults.standard.object(forKey: Keys.launchAtLogin) as? Bool ?? false
        LaunchAtLoginService.applyStoredPreference(preferred)
        launchAtLogin = LaunchAtLoginService.isEnabled
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
