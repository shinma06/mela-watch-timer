import SwiftUI

extension PomodoroTimer.Phase {
    var accentColor: Color { self == .work ? .orange : .mint }
}

struct ContentView: View {
    @State private var pomodoro = PomodoroTimer()

    var body: some View {
        // このbodyはpomodoroのいかなるプロパティも直接参照しないため
        // 毎秒の再描画対象から外れる
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height) - 6
            ZStack {
                ProgressRingView(pomodoro: pomodoro)
                VStack(spacing: 4) {
                    PhaseLabelView(pomodoro: pomodoro)
                    TimerTextView(pomodoro: pomodoro)
                    SessionDotsView(pomodoro: pomodoro)
                    ControlsView(pomodoro: pomodoro)
                }
            }
            .frame(width: size, height: size)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea()
        .onAppear { pomodoro.refreshIfNeeded() }
    }
}

// remaining と phase を観測 — 毎秒再描画
private struct ProgressRingView: View {
    let pomodoro: PomodoroTimer

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.12), lineWidth: 5)
            Circle()
                .trim(from: 0, to: pomodoro.progress)
                .stroke(
                    pomodoro.phase.accentColor,
                    style: StrokeStyle(lineWidth: 5, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(pomodoro.progress == 1 ? .none : .linear(duration: 1), value: pomodoro.progress)
        }
    }
}

// phase のみ観測 — フェーズ切り替え時のみ再描画
private struct PhaseLabelView: View {
    let pomodoro: PomodoroTimer

    var body: some View {
        Text(pomodoro.phase.label)
            .font(.caption2)
            .fontWeight(.semibold)
            .foregroundStyle(pomodoro.phase.accentColor)
            .animation(.easeInOut(duration: 0.3), value: pomodoro.phase == .work)
    }
}

// remaining のみ観測 — 毎秒再描画
private struct TimerTextView: View {
    let pomodoro: PomodoroTimer

    var body: some View {
        let total = max(0, Int(pomodoro.remaining.rounded(.up)))
        Text(String(format: "%02d:%02d", total / 60, total % 60))
            .font(.system(size: 30, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white)
    }
}

// completedPomodoros のみ観測 — セッション完了時のみ再描画
private struct SessionDotsView: View {
    let pomodoro: PomodoroTimer

    var body: some View {
        let count = min(pomodoro.completedPomodoros, 8)
        HStack(spacing: 3) {
            ForEach(0..<count, id: \.self) { _ in
                Circle()
                    .fill(Color.orange)
                    .frame(width: 4, height: 4)
            }
        }
        .frame(height: 8)
        .animation(.spring, value: pomodoro.completedPomodoros)
    }
}

// isRunning と phase を観測 — ボタン状態変化時のみ再描画
private struct ControlsView: View {
    let pomodoro: PomodoroTimer

    var body: some View {
        HStack(spacing: 10) {
            Button { pomodoro.toggle() } label: {
                Image(systemName: pomodoro.isRunning ? "pause.fill" : "play.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.black)
            }
            .buttonStyle(.plain)
            .frame(width: 40, height: 40)
            .background(pomodoro.phase.accentColor)
            .clipShape(Circle())
            .animation(.easeInOut(duration: 0.2), value: pomodoro.isRunning)

            Button { pomodoro.skip() } label: {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .frame(width: 32, height: 32)
            .background(Color.white.opacity(0.15))
            .clipShape(Circle())
        }
    }
}

#Preview {
    ContentView()
}
