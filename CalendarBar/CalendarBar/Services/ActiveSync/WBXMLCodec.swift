import Foundation

enum WBXMLCodec {
    private static let switchPage: UInt8 = 0x00
    private static let end: UInt8 = 0x01
    private static let strI: UInt8 = 0x03
    private static let opaque: UInt8 = 0xc3
    private static let tagContent: UInt8 = 0x40

    private struct CodePage {
        let namespace: String
        let tokens: [String: UInt8]
        let names: [UInt8: String]

        init(namespace: String, tokens: [String: UInt8]) {
            self.namespace = namespace
            self.tokens = tokens
            var names: [UInt8: String] = [:]
            for (name, token) in tokens {
                names[token] = name
            }
            self.names = names
        }
    }

    private struct XMLNode {
        enum Kind {
            case element(name: String, namespace: String, children: [XMLNode])
            case text(String)
        }

        let kind: Kind
    }

    private struct ParseState {
        var currentPage: Int = 0
    }

    private struct Cursor {
        var offset: Int = 0
    }

    private static let codePages: [CodePage] = [
        CodePage(namespace: "AirSync", tokens: [
            "Sync": 0x05, "Responses": 0x06, "Add": 0x07, "Change": 0x08, "Delete": 0x09,
            "Fetch": 0x0a, "SyncKey": 0x0b, "ClientId": 0x0c, "ServerId": 0x0d, "Status": 0x0e,
            "Collection": 0x0f, "Class": 0x10, "CollectionId": 0x12, "GetChanges": 0x13,
            "MoreAvailable": 0x14, "WindowSize": 0x15, "Commands": 0x16, "Options": 0x17,
            "FilterType": 0x18, "Conflict": 0x1b, "Collections": 0x1c, "ApplicationData": 0x1d,
            "DeletesAsMoves": 0x1e, "Supported": 0x20, "SoftDelete": 0x21, "MIMESupport": 0x22,
            "MIMETruncation": 0x23, "Wait": 0x24, "Limit": 0x25, "Partial": 0x26,
            "ConversationMode": 0x27, "MaxItems": 0x28, "HeartbeatInterval": 0x29
        ]),
        CodePage(namespace: "Contacts", tokens: [:]),
        CodePage(namespace: "Email", tokens: [
            "Attachment": 0x05, "Attachments": 0x06, "AttName": 0x07, "AttSize": 0x08,
            "Att0id": 0x09, "AttMethod": 0x0a, "Body": 0x0c, "BodySize": 0x0d,
            "BodyTruncated": 0x0e, "DateReceived": 0x0f, "DisplayName": 0x10, "DisplayTo": 0x11,
            "Importance": 0x12, "MessageClass": 0x13, "Subject": 0x14, "Read": 0x15, "To": 0x16,
            "Cc": 0x17, "From": 0x18, "ReplyTo": 0x19, "AllDayEvent": 0x1a, "Categories": 0x1b,
            "Category": 0x1c, "DtStamp": 0x1d, "EndTime": 0x1e, "InstanceType": 0x1f,
            "BusyStatus": 0x20, "Location": 0x21, "MeetingRequest": 0x22, "Organizer": 0x23,
            "RecurrenceId": 0x24, "Reminder": 0x25, "ResponseRequested": 0x26, "Recurrences": 0x27,
            "Recurrence": 0x28, "Type": 0x29, "Until": 0x2a, "Occurrences": 0x2b, "Interval": 0x2c,
            "DayOfWeek": 0x2d, "DayOfMonth": 0x2e, "WeekOfMonth": 0x2f, "MonthOfYear": 0x30,
            "StartTime": 0x31, "Sensitivity": 0x32, "TimeZone": 0x33, "GlobalObjId": 0x34,
            "ThreadTopic": 0x35, "MIMEData": 0x36, "MIMETruncated": 0x37, "MIMESize": 0x38,
            "InternetCPID": 0x39, "Flag": 0x3a, "Status": 0x3b, "ContentClass": 0x3c,
            "FlagType": 0x3d, "CompleteTime": 0x3e, "DisallowNewTimeProposal": 0x3f
        ]),
        CodePage(namespace: "", tokens: [:]),
        CodePage(namespace: "Calendar", tokens: [
            "TimeZone": 0x05, "AllDayEvent": 0x06, "Attendees": 0x07, "Attendee": 0x08,
            "Email": 0x09, "Name": 0x0a, "Body": 0x0b, "BodyTruncated": 0x0c, "BusyStatus": 0x0d,
            "Categories": 0x0e, "Category": 0x0f, "Rtf": 0x10, "DtStamp": 0x11, "EndTime": 0x12,
            "Exception": 0x13, "Exceptions": 0x14, "Deleted": 0x15, "ExceptionStartTime": 0x16,
            "Location": 0x17, "MeetingStatus": 0x18, "OrganizerEmail": 0x19, "OrganizerName": 0x1a,
            "Recurrence": 0x1b, "Type": 0x1c, "Until": 0x1d, "Occurrences": 0x1e, "Interval": 0x1f,
            "DayOfWeek": 0x20, "DayOfMonth": 0x21, "WeekOfMonth": 0x22, "MonthOfYear": 0x23,
            "Reminder": 0x24, "Sensitivity": 0x25, "Subject": 0x26, "StartTime": 0x27, "UID": 0x28,
            "AttendeeStatus": 0x29, "AttendeeType": 0x2a, "DisallowNewTimeProposal": 0x33,
            "ResponseRequested": 0x34, "AppointmentReplyTime": 0x35, "ResponseType": 0x36,
            "CalendarType": 0x37, "IsLeapMonth": 0x38, "FirstDayOfWeek": 0x39,
            "OnlineMeetingConfLink": 0x3a, "OnlineMeetingExternalLink": 0x3b, "ClientUid": 0x3c
        ]),
        CodePage(namespace: "Move", tokens: [:]),
        CodePage(namespace: "GetItemEstimate", tokens: [
            "GetItemEstimate": 0x05, "Version": 0x06, "Collections": 0x07, "Collection": 0x08,
            "Class": 0x09, "CollectionId": 0x0a, "DateTime": 0x0b, "Estimate": 0x0c,
            "Response": 0x0d, "Status": 0x0e
        ]),
        CodePage(namespace: "FolderHierarchy", tokens: [
            "DisplayName": 0x07, "ServerId": 0x08, "ParentId": 0x09, "Type": 0x0a, "Status": 0x0c,
            "Changes": 0x0e, "Add": 0x0f, "Delete": 0x10, "Update": 0x11, "SyncKey": 0x12,
            "FolderCreate": 0x13, "FolderDelete": 0x14, "FolderUpdate": 0x15, "FolderSync": 0x16,
            "Count": 0x17
        ]),
        CodePage(namespace: "MeetingResponse", tokens: [
            "CalendarId": 0x05, "CollectionId": 0x06, "MeetingResponse": 0x07,
            "RequestId": 0x08, "Request": 0x09, "Result": 0x0a, "Status": 0x0b,
            "UserResponse": 0x0c, "InstanceId": 0x0e
        ]),
        CodePage(namespace: "Tasks", tokens: [:]),
        CodePage(namespace: "ResolveRecipients", tokens: [:]),
        CodePage(namespace: "ValidateCert", tokens: [:]),
        CodePage(namespace: "Contacts2", tokens: [:]),
        CodePage(namespace: "Ping", tokens: [:]),
        CodePage(namespace: "Provision", tokens: [
            "Provision": 0x05, "Policies": 0x06, "Policy": 0x07, "PolicyType": 0x08,
            "PolicyKey": 0x09, "Data": 0x0a, "Status": 0x0b, "RemoteWipe": 0x0c,
            "EASProvisionDoc": 0x0d, "DevicePasswordEnabled": 0x0e,
            "AlphanumericDevicePasswordRequired": 0x0f, "RequireStorageCardEncryption": 0x10,
            "PasswordRecoveryEnabled": 0x11, "AttachmentsEnabled": 0x13,
            "MinDevicePasswordLength": 0x14, "MaxInactivityTimeDeviceLock": 0x15,
            "MaxDevicePasswordFailedAttempts": 0x16, "MaxAttachmentSize": 0x17,
            "AllowSimpleDevicePassword": 0x18, "DevicePasswordExpiration": 0x19,
            "DevicePasswordHistory": 0x1a, "AllowStorageCard": 0x1b, "AllowCamera": 0x1c,
            "RequireDeviceEncryption": 0x1d, "AllowUnsignedApplications": 0x1e,
            "AllowUnsignedInstallationPackages": 0x1f, "MinDevicePasswordComplexCharacters": 0x20,
            "AllowWiFi": 0x21, "AllowTextMessaging": 0x22, "AllowPOPIMAPEmail": 0x23,
            "AllowBluetooth": 0x24, "AllowIrDA": 0x25, "RequireManualSyncWhenRoaming": 0x26,
            "AllowDesktopSync": 0x27, "MaxCalendarAgeFilter": 0x28, "AllowHTMLEmail": 0x29,
            "MaxEmailAgeFilter": 0x2a, "MaxEmailBodyTruncationSize": 0x2b,
            "MaxEmailHTMLBodyTruncationSize": 0x2c, "RequireSignedSMIMEMessages": 0x2d,
            "RequireEncryptedSMIMEMessages": 0x2e, "RequireSignedSMIMEAlgorithm": 0x2f,
            "RequireEncryptionSMIMEAlgorithm": 0x30,
            "AllowSMIMEEncryptionAlgorithmNegotiation": 0x31, "AllowSMIMESoftCerts": 0x32,
            "AllowBrowser": 0x33, "AllowConsumerEmail": 0x34, "AllowRemoteDesktop": 0x35,
            "AllowInternetSharing": 0x36, "UnapprovedInROMApplicationList": 0x37,
            "ApplicationName": 0x38, "ApprovedApplicationList": 0x39, "Hash": 0x3a
        ]),
        CodePage(namespace: "Search", tokens: [:]),
        CodePage(namespace: "Gal", tokens: [:]),
        CodePage(namespace: "AirSyncBase", tokens: [
            "BodyPreference": 0x05, "Type": 0x06, "TruncationSize": 0x07, "AllOrNone": 0x08,
            "Body": 0x0a, "Data": 0x0b, "EstimatedDataSize": 0x0c, "Truncated": 0x0d,
            "Attachments": 0x0e, "Attachment": 0x0f, "DisplayName": 0x10, "FileReference": 0x11,
            "Method": 0x12, "ContentId": 0x13, "ContentLocation": 0x14, "IsInline": 0x15,
            "NativeBodyType": 0x16, "ContentType": 0x17, "Preview": 0x18,
            "BodyPartPreference": 0x19, "BodyPart": 0x1a, "Status": 0x1b
        ]),
        CodePage(namespace: "Settings", tokens: [
            "Settings": 0x05, "Status": 0x06, "Get": 0x07, "Set": 0x08, "DeviceInformation": 0x16,
            "Model": 0x17, "IMEI": 0x18, "FriendlyName": 0x19, "OS": 0x1a, "OSLanguage": 0x1b,
            "PhoneNumber": 0x1c, "UserAgent": 0x20, "MobileOperator": 0x22
        ]),
        CodePage(namespace: "DocumentLibrary", tokens: [:]),
        CodePage(namespace: "ItemOperations", tokens: [
            "ItemOperations": 0x05, "Fetch": 0x06, "Store": 0x07, "Options": 0x08,
            "Range": 0x09, "Total": 0x0a, "Properties": 0x0b, "Data": 0x0c,
            "Status": 0x0d, "Response": 0x0e, "Version": 0x0f, "Schema": 0x10,
            "Part": 0x11, "EmptyFolderContents": 0x12, "DeleteSubFolders": 0x13,
            "UserName": 0x14, "Password": 0x15, "Move": 0x16, "DstFldId": 0x17,
            "ConversationId": 0x18, "MoveAlways": 0x19
        ]),
        CodePage(namespace: "ComposeMail", tokens: [
            "SendMail": 0x05, "SmartForward": 0x06, "SmartReply": 0x07,
            "SaveInSentItems": 0x08, "ReplaceMime": 0x09, "Type": 0x0a,
            "Source": 0x0b, "FolderId": 0x0c, "ItemId": 0x0d, "LongId": 0x0e,
            "InstanceId": 0x0f, "MIME": 0x10, "ClientId": 0x11, "Status": 0x12,
            "AccountId": 0x13
        ]),
        CodePage(namespace: "Email2", tokens: [
            "UmCallerID": 0x05, "UmUserNotes": 0x06, "UmAttDuration": 0x07, "UmAttOrder": 0x08,
            "ConversationId": 0x09, "ConversationIndex": 0x0a, "LastVerbExecuted": 0x0b,
            "LastVerbExecutionTime": 0x0c, "ReceivedAsBcc": 0x0d, "Sender": 0x0e,
            "CalendarType": 0x0f, "IsLeapMonth": 0x10, "AccountId": 0x11, "FirstDayOfWeek": 0x12,
            "MeetingMessageType": 0x13
        ]),
        CodePage(namespace: "Notes", tokens: [:]),
        CodePage(namespace: "RightsManagement", tokens: [:])
    ]

    private static let namespaceToPage: [String: Int] = {
        var map: [String: Int] = [:]
        for (index, page) in codePages.enumerated() {
            map[page.namespace] = index
        }
        return map
    }()

    /// ActiveSync xmlns values include a trailing colon, e.g. `FolderHierarchy:`.
    private static func normalizeNamespace(_ value: String) -> String {
        var ns = value.trimmingCharacters(in: .whitespaces)
        if ns.hasSuffix(":") {
            ns.removeLast()
        }
        return ns
    }

    private static func pageIndex(for namespace: String) -> Int? {
        namespaceToPage[normalizeNamespace(namespace)]
    }

    static func encode(_ xml: String) throws -> Data {
        let nodes = try parseXml(xml)
        var bytes: [UInt8] = [0x03, 0x01, 0x6a, 0x00]
        var state = ParseState()

        for node in nodes {
            try appendNode(to: &bytes, node: node, inheritedNamespace: "AirSync", state: &state)
        }

        return Data(bytes)
    }

    static func decode(_ data: Data) throws -> String {
        let bytes = [UInt8](data)
        var cursor = Cursor(offset: 4)
        var state = ParseState()

        guard let root = parseDocument(bytes: bytes, cursor: &cursor, state: &state) else {
            return "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
        }

        return "<?xml version=\"1.0\" encoding=\"utf-8\"?>" + renderNode(root, includeXmlns: true)
    }

    // MARK: - Encode helpers

    private static func appendNode(
        to bytes: inout [UInt8],
        node: XMLNode,
        inheritedNamespace: String,
        state: inout ParseState
    ) throws {
        switch node.kind {
        case .text(let value):
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            bytes.append(strI)
            bytes.append(contentsOf: Array(text.utf8))
            bytes.append(0x00)

        case .element(let name, let namespace, let children):
            let resolvedNamespace = normalizeNamespace(namespace.isEmpty ? inheritedNamespace : namespace)
            guard let pageIndex = pageIndex(for: resolvedNamespace) else {
                throw WBXMLError.unsupportedNamespace(resolvedNamespace)
            }

            if state.currentPage != pageIndex {
                bytes.append(switchPage)
                bytes.append(UInt8(pageIndex))
                state.currentPage = pageIndex
            }

            let page = codePages[pageIndex]
            guard let token = page.tokens[name] else {
                throw WBXMLError.unsupportedTag("\(resolvedNamespace):\(name)")
            }

            let hasContent = !children.isEmpty
            bytes.append(hasContent ? token | tagContent : token)

            if hasContent {
                for child in children {
                    try appendNode(to: &bytes, node: child, inheritedNamespace: resolvedNamespace, state: &state)
                }
                bytes.append(end)
            }
        }
    }

    // MARK: - Decode helpers

    private static func parseDocument(bytes: [UInt8], cursor: inout Cursor, state: inout ParseState) -> XMLNode? {
        var stack: [XMLNode] = []
        var root: XMLNode?

        while cursor.offset < bytes.count {
            let token = bytes[cursor.offset]
            cursor.offset += 1

            if token == switchPage {
                state.currentPage = Int(bytes[cursor.offset])
                cursor.offset += 1
                continue
            }

            if token == end {
                guard let completed = stack.popLast() else { continue }
                if let last = stack.last {
                    appendChild(completed, to: &stack[stack.count - 1])
                } else {
                    root = completed
                }
                continue
            }

            if token == strI {
                let value = readInlineString(bytes: bytes, cursor: &cursor)
                if var last = stack.popLast() {
                    appendChild(XMLNode(kind: .text(value)), to: &last)
                    stack.append(last)
                }
                continue
            }

            if token == opaque {
                let length = readMultiByteInt(bytes: bytes, cursor: &cursor)
                let value = String(bytes: bytes[cursor.offset..<(cursor.offset + length)], encoding: .utf8) ?? ""
                cursor.offset += length
                if var last = stack.popLast() {
                    appendChild(XMLNode(kind: .text(value)), to: &last)
                    stack.append(last)
                }
                continue
            }

            let hasContent = (token & tagContent) != 0
            let tagToken = token & 0x3f
            let page = codePages[state.currentPage]
            guard let name = page.names[tagToken] else {
                return root
            }

            let element = XMLNode(kind: .element(name: name, namespace: page.namespace, children: []))

            if hasContent {
                stack.append(element)
            } else if var last = stack.popLast() {
                appendChild(element, to: &last)
                stack.append(last)
            } else {
                root = element
            }
        }

        return root
    }

    private static func appendChild(_ child: XMLNode, to parent: inout XMLNode) {
        guard case .element(let name, let namespace, var children) = parent.kind else { return }
        children.append(child)
        parent = XMLNode(kind: .element(name: name, namespace: namespace, children: children))
    }

    private static func renderNode(_ node: XMLNode, includeXmlns: Bool) -> String {
        switch node.kind {
        case .text(let value):
            return escapeXml(value)

        case .element(let name, let namespace, let children):
            let xmlns = includeXmlns ? " xmlns=\"\(namespace):\"" : ""
            if children.isEmpty {
                return "<\(name)\(xmlns)/>"
            }
            let childText = children.map { renderNode($0, includeXmlns: false) }.joined()
            return "<\(name)\(xmlns)>\(childText)</\(name)>"
        }
    }

    // MARK: - XML parsing for encode

    private static func parseXml(_ xml: String) throws -> [XMLNode] {
        let document = xml
            .replacingOccurrences(of: #"<\?xml[\s\S]*?\?>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r\n", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var stack: [XMLNode] = []
        var roots: [XMLNode] = []
        var index = document.startIndex

        while index < document.endIndex {
            if document[index] == "<" {
                guard let endRange = document[index...].range(of: ">") else {
                    throw WBXMLError.malformedXml
                }
                let rawTag = String(document[document.index(after: index)..<endRange.lowerBound]).trimmingCharacters(in: .whitespaces)

                if rawTag.hasPrefix("/") {
                    guard let closed = stack.popLast() else {
                        throw WBXMLError.malformedXml
                    }
                    if var parent = stack.popLast() {
                        appendChild(closed, to: &parent)
                        stack.append(parent)
                    } else {
                        roots.append(closed)
                    }
                } else {
                    let selfClosing = rawTag.hasSuffix("/")
                    let tagContent = selfClosing ? String(rawTag.dropLast().trimmingCharacters(in: .whitespaces)) : rawTag
                    let parts = splitTag(tagContent)
                    let rawName = parts.first ?? ""
                    let attributes = parts.dropFirst().joined(separator: " ")

                    var namespace = "AirSync"
                    if let extracted = extractXmlnsNamespace(from: attributes) {
                        namespace = extracted
                    } else if rawName.contains(":") {
                        let prefix = String(rawName.split(separator: ":").first ?? "")
                        namespace = prefixToNamespace(prefix)
                    } else if let parent = stack.last, case .element(_, let parentNs, _) = parent.kind, !parentNs.isEmpty {
                        namespace = parentNs
                    }

                    let localName: String
                    if rawName.contains(":") {
                        localName = String(rawName.split(separator: ":").last ?? Substring(rawName))
                    } else {
                        localName = rawName
                    }

                    let element = XMLNode(kind: .element(name: localName, namespace: namespace, children: []))

                    if selfClosing {
                        if var parent = stack.popLast() {
                            appendChild(element, to: &parent)
                            stack.append(parent)
                        } else {
                            roots.append(element)
                        }
                    } else {
                        stack.append(element)
                    }
                }

                index = document.index(after: endRange.lowerBound)
                continue
            }

            let remaining = document[index...]
            let nextTag = remaining.firstIndex(of: "<") ?? document.endIndex
            let text = String(document[index..<nextTag])
            if !text.trimmingCharacters(in: .whitespaces).isEmpty, var parent = stack.popLast() {
                appendChild(XMLNode(kind: .text(decodeEntities(text.trimmingCharacters(in: .whitespaces)))), to: &parent)
                stack.append(parent)
            }
            index = nextTag
        }

        while let node = stack.popLast() {
            if var parent = stack.popLast() {
                appendChild(node, to: &parent)
                stack.append(parent)
            } else {
                roots.append(node)
            }
        }

        return roots
    }

    private static func splitTag(_ value: String) -> [String] {
        let pattern = #"(?:[^\s"]+|"[^"]*")+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.matches(in: value, range: range).compactMap { match in
            guard let r = Range(match.range, in: value) else { return nil }
            return String(value[r])
        }
    }

    private static func prefixToNamespace(_ prefix: String) -> String {
        if prefix == "airsync" { return "AirSync" }
        if prefix == "airsyncbase" { return "AirSyncBase" }
        if prefix == "composemail" { return "ComposeMail" }
        if prefix == "settings" { return "Settings" }
        guard let first = prefix.first else { return prefix }
        return String(first).uppercased() + prefix.dropFirst()
    }

    private static func extractXmlnsNamespace(from attributes: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: #"xmlns(?::[\w-]+)?="([^"]+):""#,
            options: .caseInsensitive
        ) else { return nil }

        let range = NSRange(attributes.startIndex..<attributes.endIndex, in: attributes)
        guard let match = regex.firstMatch(in: attributes, range: range),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: attributes) else {
            return nil
        }

        return normalizeNamespace(String(attributes[captureRange]))
    }

    private static func readInlineString(bytes: [UInt8], cursor: inout Cursor) -> String {
        let start = cursor.offset
        while cursor.offset < bytes.count, bytes[cursor.offset] != 0x00 {
            cursor.offset += 1
        }
        let value = String(bytes: bytes[start..<cursor.offset], encoding: .utf8) ?? ""
        cursor.offset += 1
        return value
    }

    private static func readMultiByteInt(bytes: [UInt8], cursor: inout Cursor) -> Int {
        var result = 0
        var current: UInt8 = 0
        repeat {
            current = bytes[cursor.offset]
            cursor.offset += 1
            result = (result << 7) | Int(current & 0x7f)
        } while (current & 0x80) != 0
        return result
    }

    private static func escapeXml(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func decodeEntities(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

enum WBXMLError: LocalizedError {
    case unsupportedNamespace(String)
    case unsupportedTag(String)
    case malformedXml

    var errorDescription: String? {
        switch self {
        case .unsupportedNamespace(let ns):
            return "Unsupported WBXML namespace: \(ns)"
        case .unsupportedTag(let tag):
            return "Unsupported WBXML tag: \(tag)"
        case .malformedXml:
            return "Malformed XML while encoding WBXML"
        }
    }
}
