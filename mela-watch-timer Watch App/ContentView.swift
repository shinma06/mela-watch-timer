import SwiftUI

struct ContentView: View {
    @State private var pomodoro = PomodoroTimer()

    private var accentColor: Color {
        pomodoro.phase == .work ? .orange : .mint
    }

    var body: some View {
        VStack(spacing: 6) {
            phaseLabel
            progressRing
            controls
        }
        .padding(.horizontal, 6)
        .onAppear { pomodoro.refreshIfNeeded() }
    }

    private var phaseLabel: some View {
        Text(pomodoro.phase.label)
            .font(.caption2)
            .fontWeight(.semibold)
            .foregroundStyle(accentColor)
            .animation(.easeInOut(duration: 0.3), value: pomodoro.phase == .work)
    }

    private var progressRing: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.1), lineWidth: 7)

            Circle()
                .trim(from: 0, to: pomodoro.progress)
                .stroke(
                    accentColor,
                    style: StrokeStyle(lineWidth: 7, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 1), value: pomodoro.progress)

            VStack(spacing: 2) {
                Text(timeString(pomodoro.remaining))
                    .font(.system(size: 32, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)

                sessionDots
            }
        }
        .frame(width: 130, height: 130)
    }

    private var sessionDots: some View {
        let count = min(pomodoro.completedPomodoros, 8)
        return HStack(spacing: 3) {
            ForEach(0..<count, id: \.self) { _ in
                Circle()
                    .fill(Color.orange)
                    .frame(width: 4, height: 4)
            }
        }
        .frame(height: 8)
        .animation(.spring, value: pomodoro.completedPomodoros)
    }

    private var controls: some View {
        HStack(spacing: 14) {
            Button(action: { pomodoro.toggle() }) {
                Image(systemName: pomodoro.isRunning ? "pause.fill" : "play.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.black)
            }
            .buttonStyle(.plain)
            .frame(width: 48, height: 48)
            .background(accentColor)
            .clipShape(Circle())
            .animation(.easeInOut(duration: 0.2), value: pomodoro.isRunning)

            Button(action: { pomodoro.skip() }) {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .frame(width: 38, height: 38)
            .background(Color.white.opacity(0.15))
            .clipShape(Circle())
        }
    }

    private func timeString(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded(.up)))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

#Preview {
    ContentView()
}
