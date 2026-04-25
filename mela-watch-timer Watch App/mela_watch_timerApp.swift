import SwiftUI
import UserNotifications

@main
struct mela_watch_timer_Watch_AppApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .task { await requestNotificationPermission() }
        }
    }

    private func requestNotificationPermission() async {
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])
    }
}
