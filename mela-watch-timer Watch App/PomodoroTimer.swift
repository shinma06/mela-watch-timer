import Foundation
import WatchKit
import UserNotifications
import Observation

@Observable
@MainActor
final class PomodoroTimer {

    enum Phase {
        case work, rest

        // タイマー時間設定(test用)
        var duration: TimeInterval { self == .work ? 0.25 * 60 : 0.5 * 60 }
        var next: Phase { self == .work ? .rest : .work }
        var label: String { self == .work ? "集中" : "休憩" }
    }

    private(set) var phase: Phase = .work
    private(set) var isRunning = false
    private(set) var remaining: TimeInterval = 25 * 60
    private(set) var completedPomodoros = 0

    private var endDate: Date?
    private var ticker: Timer?

    var progress: Double {
        max(0, min(1, 1.0 - remaining / phase.duration))
    }

    func toggle() {
        isRunning ? pause() : resume()
    }

    func skip() {
        cancelNotification()
        transition(autoResume: false)
    }

    func refreshIfNeeded() {
        guard isRunning, let end = endDate else { return }
        remaining = max(0, end.timeIntervalSinceNow)
    }

    private func resume() {
        isRunning = true
        endDate = Date().addingTimeInterval(remaining)
        scheduleNotification()
        WKInterfaceDevice.current().play(.start)
        startTicker()
    }

    private func pause() {
        isRunning = false
        ticker?.invalidate()
        ticker = nil
        endDate = nil
        cancelNotification()
        WKInterfaceDevice.current().play(.click)
    }

    private func tick() {
        guard let end = endDate else { return }
        let newRemaining = max(0, end.timeIntervalSinceNow)
        remaining = newRemaining
        if newRemaining <= 0 {
            WKInterfaceDevice.current().play(.success)
            transition(autoResume: false)
        }
    }

    private func transition(autoResume: Bool) {
        ticker?.invalidate()
        ticker = nil
        isRunning = false
        endDate = nil

        if phase == .work { completedPomodoros += 1 }
        phase = phase.next
        remaining = phase.duration

        if autoResume {
            resume()
        }
    }

    private func startTicker() {
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            // RunLoop.main 上で動作するためメインスレッドが保証済み
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func scheduleNotification() {
        cancelNotification()
        let content = UNMutableNotificationContent()
        content.title = phase.label + "終了"
        content.body = phase.next.label + "を始めましょう"
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: remaining, repeats: false)
        let request = UNNotificationRequest(
            identifier: "pomodoro.timer",
            content: content,
            trigger: trigger
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func cancelNotification() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: ["pomodoro.timer"]
        )
    }
}
