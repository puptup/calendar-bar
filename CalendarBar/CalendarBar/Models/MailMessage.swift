import Foundation

struct MailAddress: Codable, Hashable, Identifiable, Sendable {
    var id: String { email.isEmpty ? name : email.lowercased() }
    let name: String
    let email: String

    var displayName: String {
        if !name.isEmpty { return name }
        if !email.isEmpty { return email }
        return "Без отправителя"
    }
}

struct MailAttachment: Codable, Hashable, Identifiable, Sendable {
    var id: String { fileReference.isEmpty ? displayName : fileReference }
    let displayName: String
    let fileReference: String
    let estimatedSize: Int?
    let contentType: String?
    let isInline: Bool

    var sizeText: String {
        guard let estimatedSize, estimatedSize > 0 else { return "" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(estimatedSize))
    }
}

enum MailBodyType: String, Codable, Sendable {
    case plain
    case html
    case mime
    case unknown
}

struct MailBody: Codable, Hashable, Sendable {
    var type: MailBodyType
    var data: String
    var isTruncated: Bool
}

struct MailMessage: Codable, Hashable, Identifiable, Sendable {
    let serverId: String
    let collectionId: String
    var subject: String
    var from: MailAddress?
    var to: [MailAddress]
    var cc: [MailAddress]
    var replyTo: [MailAddress]
    var dateReceived: Date?
    var isRead: Bool
    var importance: String?
    var messageClass: String
    var conversationId: String
    var conversationIndex: String
    var threadTopic: String
    var body: MailBody?
    var preview: String?
    var attachments: [MailAttachment]

    var id: String { serverId }

    var displaySubject: String {
        subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "(без темы)" : subject
    }

    var threadKey: String {
        if !conversationId.isEmpty { return conversationId }
        if !conversationIndex.isEmpty { return conversationIndex }
        let normalizedSubject = displaySubject
            .lowercased()
            .replacingOccurrences(of: #"^(re|fw|fwd):\s*"#, with: "", options: .regularExpression)
        return "\(normalizedSubject)|\(from?.email.lowercased() ?? from?.name.lowercased() ?? "")"
    }

    var displayBodyText: String {
        guard let body else { return preview ?? "" }
        return TextContentFormatter.plainText(from: body.data)
    }

    var receivedText: String {
        guard let dateReceived else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        if Calendar.current.isDateInToday(dateReceived) {
            formatter.dateFormat = "HH:mm"
        } else {
            formatter.dateFormat = "d MMM, HH:mm"
        }
        return formatter.string(from: dateReceived)
    }
}

enum MailFolderKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case inbox
    case sent
    case drafts
    case trash

    var id: String { rawValue }

    var title: String {
        switch self {
        case .inbox: return "Входящие"
        case .sent: return "Отправленные"
        case .drafts: return "Черновики"
        case .trash: return "Корзина"
        }
    }
}

struct MailThread: Identifiable, Hashable, Sendable {
    let id: String
    var messages: [MailMessage]

    var latestMessage: MailMessage? {
        messages.sorted { ($0.dateReceived ?? .distantPast) > ($1.dateReceived ?? .distantPast) }.first
    }

    var unreadCount: Int {
        messages.filter { !$0.isRead }.count
    }

    var subject: String {
        latestMessage?.displaySubject ?? "(без темы)"
    }
}

struct MailSyncSnapshot: Sendable {
    let messages: [MailMessage]
    let deletedServerIds: [String]
}

enum MeetingAction: String, Sendable {
    case accept
    case tentative
    case decline

    var responseType: String {
        switch self {
        case .accept: return "1"
        case .tentative: return "2"
        case .decline: return "3"
        }
    }
}
