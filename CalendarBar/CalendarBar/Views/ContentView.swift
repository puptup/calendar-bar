import SwiftUI

struct ContentView: View {
    @ObservedObject private var store = SettingsStore.shared

    var body: some View {
        Group {
            if store.isLoggedIn && store.password != nil {
                EventsListView()
            } else {
                AuthView()
                    .frame(width: PopoverMetrics.timelineWidth, height: PopoverMetrics.height)
            }
        }
        .background(Color.clear)
    }
}
