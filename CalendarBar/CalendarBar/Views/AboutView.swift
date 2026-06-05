import SwiftUI

enum AppInfo {
    static let author = "Кошевар Кирилл Петрович, ДАНИС"
    static let version = "beta 0.0.1"

    static var name: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "CalendarBar"
    }
}

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "calendar")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)

            Text(AppInfo.name)
                .font(.title3.bold())

            VStack(alignment: .leading, spacing: 8) {
                Text("Автор: \(AppInfo.author)")
                Text("Версия: \(AppInfo.version)")
            }
            .font(.body)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)

            Button("OK") {
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(24)
        .frame(width: 320)
        .background(Color.clear)
    }
}
