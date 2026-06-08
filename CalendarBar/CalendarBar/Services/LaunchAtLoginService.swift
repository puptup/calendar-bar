import Foundation
import ServiceManagement

enum LaunchAtLoginService {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    /// Applies stored user preference on app launch.
    static func applyStoredPreference(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        try? setEnabled(enabled)
    }
}
