import SwiftUI

struct MailContentView: View {
    @ObservedObject private var store = SettingsStore.shared

    var body: some View {
        Group {
            if store.isLoggedIn && store.password != nil {
                MailListView()
            } else {
                AuthView()
                    .frame(width: MailPopoverMetrics.listWidth, height: MailPopoverMetrics.height)
            }
        }
        .background(Color.clear)
    }
}
