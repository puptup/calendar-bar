import SwiftUI

@main
struct CalendarBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {}

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
