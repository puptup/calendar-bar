import SwiftUI
import AppKit

enum TextContentFormatter {
    static func plainText(from raw: String) -> String {
        guard raw.contains("<") else { return raw.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let data = raw.data(using: .utf8),
           let attributed = try? NSAttributedString(
            data: data,
            options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue
            ],
            documentAttributes: nil
           ) {
            return attributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return raw
            .replacingOccurrences(of: "<br[^>]*>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func linkified(_ string: String) -> AttributedString {
        var attributed = AttributedString(string)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return attributed
        }

        let nsString = string as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)
        detector.enumerateMatches(in: string, options: [], range: fullRange) { match, _, _ in
            guard let match, let url = match.url,
                  let range = Range(match.range, in: string),
                  let attrRange = Range(range, in: attributed) else { return }
            attributed[attrRange].link = url
            attributed[attrRange].foregroundColor = NSColor.linkColor
            attributed[attrRange].underlineStyle = .single
        }
        return attributed
    }
}

struct LinkDetectingText: View {
    let text: String

    var body: some View {
        Text(TextContentFormatter.linkified(displayText))
            .font(.body)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var displayText: String {
        TextContentFormatter.plainText(from: text)
    }
}
