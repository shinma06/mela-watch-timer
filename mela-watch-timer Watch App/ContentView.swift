import SwiftUI

struct ContentView: View {
    let model: TimerModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isLuminanceReduced) private var luminanceReduced
    @State private var wasBackground = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1,
                                paused: model.snapshot.timer.mode != .running || (!model.isActive && !luminanceReduced))) { _ in
            DialFace(phase: model.snapshot.timer.phase, ratio: model.remainingRatio, dimmed: luminanceReduced)
                .contentShape(Rectangle())
                .onTapGesture { model.openControls() }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(model.accessibilitySummary)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { model.openControls() }
        }
        .ignoresSafeArea()
        .sheet(isPresented: Binding(get: { model.route != .dial }, set: { if !$0 { model.closeControls() } })) {
            NavigationStack {
                if model.route == .onboarding { OnboardingView(model: model) }
                else { ControlsView(model: model) }
            }
            .alert("終了のお知らせ", isPresented: Binding(get: { model.permissionPrompt != nil }, set: { _ in })) {
                Button("通知を使う") { model.answerPermission(.allow) }
                Button("今は使わない") { model.answerPermission(.withoutNotifications) }
                Button("取消", role: .cancel) { model.cancelPermissionPrompt() }
            } message: { Text("画面を閉じても区切りを知らせるため、通知を使います。音と振動はWatchの設定に従います。") }
        }
        .task { await model.send(.load) }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .background { wasBackground = true }
            model.setActive(phase == .active, returningFromBackground: phase == .active && wasBackground)
            if phase == .active { wasBackground = false }
        }
    }
}

struct DialFace: View {
    let phase: TimerPhase
    let ratio: Double
    let dimmed: Bool

    private var red: Color { dimmed ? Color(red: 169 / 255, green: 65 / 255, blue: 62 / 255) : Color(red: 242 / 255, green: 95 / 255, blue: 92 / 255) }
    private var blue: Color { dimmed ? Color(red: 7 / 255, green: 16 / 255, blue: 31 / 255) : Color(red: 22 / 255, green: 58 / 255, blue: 112 / 255) }

    var body: some View {
        ZStack {
            phase == .focus ? blue : red
            RemainingSector(ratio: ratio).fill(phase == .focus ? red : blue)
        }
        .clipped()
    }
}

nonisolated struct RemainingSector: Shape {
    var ratio: Double

    func path(in rect: CGRect) -> Path {
        let geometry = DialGeometry(width: rect.width, height: rect.height, ratio: ratio)
        guard geometry.clampedRatio > 0 else { return Path() }
        if geometry.clampedRatio >= 1 { return Path(rect) }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        path.move(to: center)
        path.addArc(center: center, radius: geometry.radius,
                    startAngle: .radians(geometry.elapsedAngle - .pi / 2),
                    endAngle: .radians(3 * .pi / 2), clockwise: false)
        path.closeSubpath()
        return path
    }
}

private struct OnboardingView: View {
    let model: TimerModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("mela").font(.title2)
                Text("赤は集中、青は休憩")
                Text("色が減ると残り時間も減る")
                Text("画面をタップすると操作できます")
                if let error = model.storageError { Text(error) }
                Button("始める") { Task { await model.send(.finishOnboarding) } }
                    .frame(minHeight: 44)
                    .disabled(model.isBusy)
            }.padding()
        }
    }
}

private struct ControlsView: View {
    let model: TimerModel
    @State private var discardPhaseSwitch: Bool?
    @State private var confirmInitialization = false

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Text(model.snapshot.timer.phase.label).font(.title2)
                Text(model.status)
                if model.isLoaded {
                    TimelineView(.animation(minimumInterval: 1, paused: model.snapshot.timer.mode != .running || !model.isActive)) { _ in
                        Text(TimerModel.displayTime(model.remaining)).monospacedDigit()
                            .accessibilityLabel("残り" + TimerModel.spokenTime(model.remaining))
                    }
                }
                if let error = model.storageError {
                    Text(error)
                    Button("再試行") { run(model.isLoaded ? .refresh(.retry) : .load) }
                    if !model.isLoaded {
                        Button("保存データを初期化", role: .destructive) { confirmInitialization = true }
                    }
                }
                if model.isLoaded && !model.completionPending {
                    Button(primaryTitle) {
                        switch model.snapshot.timer.mode {
                        case .ready: run(.start())
                        case .paused: run(.resume())
                        case .running:
                            if let id = model.snapshot.timer.session?.id { run(.pause(id)) }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.storageError != nil)
                    if model.snapshot.timer.mode != .ready {
                        Button("この回をやり直す") { discardPhaseSwitch = false }
                    }
                    Button(model.snapshot.timer.phase.next.label + "に切り替える") {
                        if model.snapshot.timer.mode == .ready { run(.discard(nil, switchPhase: true)) }
                        else { discardPhaseSwitch = true }
                    }
                    Text(model.notifications.message).font(.footnote)
                    if model.startNotice {
                        Button("このまま使う") { model.closeControls() }
                    }
                    if model.notifications.permissionRequestFailed || isNotificationFailed {
                        Button("お知らせを再試行") { run(.notifications(true, .allow)) }
                    }
                    NavigationLink("設定") { SettingsView(model: model) }
                    NavigationLink("記録") { RecordsView(model: model) }
                }
                Button("閉じる") { model.closeControls() }
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .disabled(model.isBusy)
            .padding(.horizontal)
        }
        .navigationTitle("操作")
        .alert("この回の途中経過は記録されません", isPresented: Binding(
            get: { discardPhaseSwitch != nil }, set: { if !$0 { discardPhaseSwitch = nil } })) {
                Button("取消", role: .cancel) { discardPhaseSwitch = nil }
                Button(discardPhaseSwitch == true ? "切り替える" : "やり直す", role: .destructive) {
                    let switchPhase = discardPhaseSwitch == true
                    run(.discard(model.snapshot.timer.session?.id, switchPhase: switchPhase))
                    discardPhaseSwitch = nil
                }
        }
        .alert("保存データを初期化しますか", isPresented: $confirmInitialization) {
            Button("取消", role: .cancel) {}
            Button("初期化", role: .destructive) { run(.initializeConfirmed) }
        } message: { Text("設定と記録を新しく作成します。元のデータは保存できる場合に端末内へ退避します。") }

    }

    private var primaryTitle: String {
        switch model.snapshot.timer.mode {
        case .ready: model.snapshot.timer.phase.label + "を開始"
        case .running: "一時停止"
        case .paused: "再開"
        }
    }
    private var isNotificationFailed: Bool { if case .failed = model.notifications.state { true } else { false } }
    private func run(_ command: TimerCommand) { Task { await model.send(command) } }
}

private struct SettingsView: View {
    let model: TimerModel
    @State private var confirmDelete = false

    var body: some View {
        Form {
            NavigationLink("時間の設定") { DurationSettingsView(model: model) }
            Text("時間の変更は次の回から反映されます").font(.footnote)
            Toggle("終了のお知らせ", isOn: Binding(get: { model.snapshot.settings.notificationsEnabled }, set: {
                value in Task { await model.send(.notifications(value)) }
            }))
            Text(model.notifications.message).font(.footnote)
            Text("通知の許可と音・振動は、WatchまたはiPhoneの通知設定を確認してください。").font(.footnote)
            Toggle("操作時の触覚", isOn: Binding(get: { model.snapshot.settings.operationHapticsEnabled }, set: {
                value in Task { await model.send(.haptics(value)) }
            }))
            Button("使い方") { model.showOnboarding() }
            Button("記録を削除", role: .destructive) { confirmDelete = true }
            if let error = model.storageError { Text(error) }
        }
        .disabled(model.isBusy)
        .navigationTitle("設定")
        .onAppear { model.cancelAutomaticDismissal() }
        .alert("記録をすべて削除しますか", isPresented: $confirmDelete) {
            Button("取消", role: .cancel) {}
            Button("削除", role: .destructive) { Task { await model.send(.deleteRecords) } }
        } message: { Text("現在のタイマーと設定は残ります。") }
    }
}

private struct DurationSettingsView: View {
    let model: TimerModel
    @Environment(\.dismiss) private var dismiss
    @State private var focus: Int
    @State private var rest: Int

    init(model: TimerModel) {
        self.model = model
        _focus = State(initialValue: model.snapshot.settings.focusMinutes)
        _rest = State(initialValue: model.snapshot.settings.restMinutes)
    }

    var body: some View {
        Form {
            Picker("集中", selection: $focus) { ForEach(1...120, id: \.self) { Text("\($0)分").tag($0) } }
            Picker("休憩", selection: $rest) { ForEach(1...60, id: \.self) { Text("\($0)分").tag($0) } }
            Text("時間の変更は次の回から反映されます").font(.footnote)
            Button("保存") { Task { if await model.send(.durations(focus: focus, rest: rest)) { dismiss() } } }
            Button("取消", role: .cancel) { dismiss() }
            if let error = model.storageError { Text(error) }
        }
        .disabled(model.isBusy)
        .navigationTitle("時間")
    }
}

private struct RecordsView: View {
    let model: TimerModel

    var body: some View {
        List {
            Text("完了した集中").font(.headline)
            let days = model.snapshot.dailyFocus(at: Date())
            if days.allSatisfy({ $0.count == 0 }) { Text("完了した集中がここに記録されます") }
            ForEach(days) { day in
                VStack(alignment: .leading) {
                    Text(day.date, format: .dateTime.month().day())
                    Text("\(day.count)回・\(duration(day.duration))")
                }.accessibilityElement(children: .combine)
            }
        }
        .navigationTitle("記録")
        .onAppear { model.cancelAutomaticDismissal() }
    }

    private func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        return minutes >= 60 ? "\(minutes / 60)時間\(minutes % 60)分" : "\(minutes)分"
    }
}

#Preview {
    DialFace(phase: .focus, ratio: 0.75, dimmed: false).ignoresSafeArea()
}
