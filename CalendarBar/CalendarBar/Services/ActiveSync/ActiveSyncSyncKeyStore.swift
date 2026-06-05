import Foundation

struct ActiveSyncSyncKeys: Codable, Equatable {
    var calendar: String = "0"
    var inbox: String = "0"
}

final class ActiveSyncSyncKeyStore {
    static let shared = ActiveSyncSyncKeyStore()

    private let defaults = UserDefaults.standard
    private let prefix = "activeSyncSyncKeys."

    private init() {}

    func load(accountKey: String) -> ActiveSyncSyncKeys {
        guard !accountKey.isEmpty,
              let data = defaults.data(forKey: prefix + accountKey),
              let keys = try? JSONDecoder().decode(ActiveSyncSyncKeys.self, from: data) else {
            return ActiveSyncSyncKeys()
        }
        return keys
    }

    func save(_ keys: ActiveSyncSyncKeys, accountKey: String) {
        guard !accountKey.isEmpty,
              let data = try? JSONEncoder().encode(keys) else { return }
        defaults.set(data, forKey: prefix + accountKey)
    }

    func reset(accountKey: String) {
        guard !accountKey.isEmpty else { return }
        defaults.removeObject(forKey: prefix + accountKey)
    }
}

enum ActiveSyncSyncStatus {
    static func requiresFullResync(_ status: String) -> Bool {
        status == "3" || status == "132" || status == "6"
    }

    static func isTransient(_ status: String) -> Bool {
        status == "5" || status == "16"
    }

    static func requiresFolderResync(_ status: String) -> Bool {
        status == "12"
    }

    static func isSkippableItemStatus(_ status: String) -> Bool {
        status == "6"
    }

    static func userMessage(for status: String) -> String {
        switch status {
        case "3", "132":
            return "Сессия синхронизации устарела, выполняется повторная загрузка…"
        case "5", "16":
            return "Временная ошибка сервера, повторяем запрос…"
        case "6":
            return "Пропущено повреждённое событие, выполняется повторная загрузка…"
        case "12":
            return "Структура папок изменилась, обновляем календарь…"
        default:
            return activeSyncStatusHint(status)
        }
    }

    private static func activeSyncStatusHint(_ status: String) -> String {
        switch status {
        case "108":
            return "Некорректный DeviceId."
        case "142", "144":
            return "Требуется повторная регистрация устройства."
        case "132":
            return "Состояние синхронизации не найдено на сервере."
        case "3":
            return "Некорректный ключ синхронизации."
        default:
            return "ActiveSync status \(status)"
        }
    }
}
