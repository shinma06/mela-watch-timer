import SwiftUI
import UserNotifications

@main
struct mela_watch_timer_Watch_AppApp: App {
    @State private var model: TimerModel
    private let notificationDelegate: TimerNotificationDelegate

    init() {
        let model = TimerModel()
        _model = State(initialValue: model)
        notificationDelegate = TimerNotificationDelegate(model: model)
        let center = UNUserNotificationCenter.current()
        center.delegate = notificationDelegate
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "FOCUS_COMPLETE", actions: [
                UNNotificationAction(identifier: "START_REST", title: "休憩を開始", options: .foreground)
            ], intentIdentifiers: []),
            UNNotificationCategory(identifier: "REST_COMPLETE", actions: [
                UNNotificationAction(identifier: "START_FOCUS", title: "集中を開始", options: .foreground)
            ], intentIdentifiers: [])
        ])
    }

    var body: some Scene {
        WindowGroup { ContentView(model: model) }
    }
}

@MainActor
final class TimerNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    private let model: TimerModel
    init(model: TimerModel) { self.model = model }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                           willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let payload = NotificationPayload(userInfo: notification.request.content.userInfo,
                                          identifier: notification.request.identifier)
        let shouldPresent = await model.send(.foregroundNotification(payload))
        return shouldPresent ? [.sound] : []
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                           didReceive response: UNNotificationResponse) async {
        let request = response.notification.request
        let payload = NotificationPayload(userInfo: request.content.userInfo, identifier: request.identifier)
        let action: NotificationAction
        switch response.actionIdentifier {
        case "START_REST": action = .start(.rest)
        case "START_FOCUS": action = .start(.focus)
        case UNNotificationDismissActionIdentifier: action = .dismiss
        default: action = .open
        }
        await model.send(.respondToNotification(payload, action))
    }
}
