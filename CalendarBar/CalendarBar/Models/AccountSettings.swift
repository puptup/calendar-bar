import Foundation

struct AccountSettings: Codable, Equatable {
    var email: String
    var server: String
    var domain: String
    var username: String
    var deviceId: String

    enum CodingKeys: String, CodingKey {
        case email, server, domain, username, deviceId
    }

    init(email: String, server: String, domain: String, username: String, deviceId: String) {
        self.email = email
        self.server = server
        self.domain = domain
        self.username = username
        self.deviceId = deviceId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        email = try container.decode(String.self, forKey: .email)
        server = try container.decode(String.self, forKey: .server)
        domain = try container.decode(String.self, forKey: .domain)
        username = try container.decode(String.self, forKey: .username)
        deviceId = try container.decodeIfPresent(String.self, forKey: .deviceId) ?? ""
    }

    static let defaultServer = ""

    static var empty: AccountSettings {
        AccountSettings(email: "", server: defaultServer, domain: "", username: "", deviceId: "")
    }

    var isConfigured: Bool {
        !email.isEmpty && !server.isEmpty && !username.isEmpty
    }

    /// Формат логина для Exchange EWS (legacy): DOMAIN\username или username@domain
    var exchangeUsername: String {
        activeSyncAuthUsername
    }

    /// Basic auth username for ActiveSync: DOMAIN\username or email
    var activeSyncAuthUsername: String {
        if !domain.isEmpty {
            return "\(domain)\\\(username)"
        }
        if !email.isEmpty {
            return email
        }
        return username
    }

    /// Email for ActiveSync URL User= query parameter
    var activeSyncUserParam: String {
        email
    }

    /// Explicit endpoint override; empty uses server-based discovery
    var activeSyncEndpoint: String {
        ""
    }

    var ewsURL: URL {
        URL(string: "https://\(server)/EWS/Exchange.asmx")!
    }

    var activeSyncURL: URL {
        URL(string: "https://\(server)/Microsoft-Server-ActiveSync")!
    }

    static func generateDeviceId() -> String {
        // Exchange ожидает alphanumeric ID в стиле iPhone (см. MS-ASCMD 108)
        let hex = UUID().uuidString.replacingOccurrences(of: "-", with: "").uppercased()
        return "Appl" + String(hex.prefix(28))
    }

    /// Валидный DeviceId для ActiveSync: только буквы/цифры, 8–64 символа
    var resolvedDeviceId: String {
        let candidate = deviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.isValidDeviceId(candidate) {
            return candidate
        }
        return Self.generateDeviceId()
    }

    static func isValidDeviceId(_ value: String) -> Bool {
        guard (8...64).contains(value.count) else { return false }
        return value.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
    }
}

enum SyncState: Equatable {
    case idle
    case syncing
    case success(Date)
    case failure(String)

    var statusText: String {
        switch self {
        case .idle:
            return "Ожидание"
        case .syncing:
            return "Синхронизация…"
        case .success(let date):
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "ru_RU")
            if Calendar.current.isDateInToday(date) {
                formatter.dateFormat = "'Последняя синхронизация в' HH:mm"
            } else {
                formatter.dateFormat = "'Последняя синхронизация' d MMM 'в' HH:mm"
            }
            return formatter.string(from: date)
        case .failure(let message):
            return message
        }
    }
}
