import Foundation
import Observation

nonisolated enum AppRoute: Equatable { case dial, controls, onboarding }
nonisolated enum PermissionChoice { case allow, withoutNotifications }
nonisolated enum PendingPermission: Identifiable {
    case start, resume, enable
    var id: Self { self }
}
nonisolated enum RefreshReason { case activation, retry, notification, operation, deadline(UUID, Int) }
nonisolated enum NotificationAction { case open, start(TimerPhase), dismiss }

nonisolated enum TimerCommand {
    case load, initializeConfirmed, finishOnboarding
    case start(PermissionChoice? = nil), resume(PermissionChoice? = nil)
    case pause(UUID), discard(UUID?, switchPhase: Bool)
    case durations(focus: Int, rest: Int), notifications(Bool, PermissionChoice? = nil), haptics(Bool)
    case deleteRecords, refresh(RefreshReason)
    case foregroundNotification(NotificationPayload?)
    case respondToNotification(NotificationPayload?, NotificationAction)
}

@MainActor @Observable
final class TimerModel {
    private(set) var snapshot = TimerSnapshot()
    private(set) var isLoaded = false
    private(set) var isBusy = false
    private(set) var isActive = false
    private(set) var route: AppRoute = .controls
    private(set) var navigationResetID = UUID()
    private(set) var storageError: String?
    private(set) var completionPending = false
    private(set) var permissionPrompt: PendingPermission?
    private(set) var startNotice = false
    let notifications: NotificationWorker

    @ObservationIgnored private let storage: StorageClient
    @ObservationIgnored private let clock: TimerClock
    @ObservationIgnored private let haptic: @MainActor (TimerHaptic) -> Void
    @ObservationIgnored private var anchor: RunningAnchor?
    @ObservationIgnored private var commands: [(TimerCommand, CheckedContinuation<Bool, Never>)] = []
    @ObservationIgnored private var completionTask: Task<Void, Never>?
    @ObservationIgnored private var startPresentationTask: Task<Void, Never>?
    @ObservationIgnored private var activityGeneration = 0
    @ObservationIgnored private var routeOnActivation = false
    @ObservationIgnored private var fallbackSession: UUID?

    init(storage: StorageClient = .application, notificationClient: NotificationClient = .system,
         clock: TimerClock = .continuous, haptic: @escaping @MainActor (TimerHaptic) -> Void = playTimerHaptic) {
        self.storage = storage
        self.clock = clock
        self.haptic = haptic
        self.notifications = NotificationWorker(client: notificationClient, clock: clock)
    }

    @discardableResult
    func send(_ command: TimerCommand) async -> Bool {
        await withCheckedContinuation { continuation in
            commands.append((command, continuation))
            guard !isBusy else { return }
            isBusy = true
            Task { [weak self] in
                guard let self else { return }
                while !self.commands.isEmpty {
                    let (command, continuation) = self.commands.removeFirst()
                    continuation.resume(returning: await self.execute(command))
                }
                self.isBusy = false
            }
        }
    }

    func setActive(_ active: Bool, returningFromBackground: Bool = false) {
        guard active != isActive || returningFromBackground else { return }
        isActive = active
        activityGeneration += 1
        completionTask?.cancel()
        completionTask = nil
        if active {
            if returningFromBackground { navigationResetID = UUID() }
            routeOnActivation = routeOnActivation || returningFromBackground
            Task { [weak self] in await self?.send(.refresh(.activation)) }
        }
    }

    func openControls() { cancelAutomaticDismissal(); route = isLoaded && !snapshot.settings.onboardingCompleted ? .onboarding : .controls }
    func closeControls() { route = .dial; startNotice = false }
    func showOnboarding() {
        cancelAutomaticDismissal()
        route = .onboarding
        navigationResetID = UUID()
    }
    func cancelAutomaticDismissal() { startPresentationTask?.cancel() }
    func cancelPermissionPrompt() { permissionPrompt = nil }

    func answerPermission(_ choice: PermissionChoice) {
        let prompt = permissionPrompt
        permissionPrompt = nil
        Task {
            switch prompt {
            case .start: await send(.start(choice))
            case .resume: await send(.resume(choice))
            case .enable: await send(.notifications(true, choice))
            case nil: break
            }
        }
    }

    var remaining: TimeInterval { max(0, rawRemaining(at: clock.now())) }
    var duration: TimeInterval { snapshot.timer.session?.duration ?? snapshot.settings.duration(for: snapshot.timer.phase) }
    var remainingRatio: Double { duration > 0 ? min(1, max(0, remaining / duration)) : 0 }

    var status: String {
        if completionPending { return "完了の保存待ち" }
        switch snapshot.timer.mode {
        case .running: return snapshot.timer.phase.label + "中"
        case .paused: return "一時停止中"
        case .ready:
            if case .completed = snapshot.timer.readyReason, let completion = snapshot.lastCompletion {
                return completion.phase.label + "が終わりました"
            }
            return snapshot.timer.phase.label + "の開始待ち"
        }
    }

    var accessibilitySummary: String {
        "\(snapshot.timer.phase.label)、\(status)、残り\(Self.spokenTime(remaining))。操作を開く"
    }

    static func displayTime(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        if total >= 3600 { return String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60) }
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    static func spokenTime(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        return "\(total / 60)分\(total % 60)秒"
    }

    private func rawRemaining(at now: ClockReading) -> TimeInterval {
        guard let session = snapshot.timer.session else { return snapshot.settings.duration(for: snapshot.timer.phase) }
        if snapshot.timer.mode == .running, let anchor, anchor.sessionID == session.id { return anchor.remaining(at: now) }
        return session.savedRemaining
    }

    private func execute(_ command: TimerCommand) async -> Bool {
        switch command {
        case .load:
            if isLoaded { return true }
            return await load(reset: false)
        case .initializeConfirmed: return await load(reset: true)
        default: break
        }
        if !isLoaded, !(await load(reset: false)) { return false }
        let reason: RefreshReason
        switch command {
        case let .refresh(value): reason = value
        case .foregroundNotification, .respondToNotification: reason = .notification
        default: reason = .operation
        }
        if case let .deadline(id, generation) = reason {
            guard isActive, activityGeneration == generation, snapshot.timer.session?.id == id else { return false }
        }
        if !(await reconcile(reason: reason)) {
            if case let .foregroundNotification(payload) = command, let payload,
               let intent = snapshot.notificationIntent, payload == NotificationPayload(intent: intent),
               snapshot.timer.mode == .running, remaining == 0 {
                return true
            }
            return false
        }
        switch command {
        case .load, .initializeConfirmed: return true
        case let .start(choice): return await begin(resume: false, choice: choice)
        case let .resume(choice): return await begin(resume: true, choice: choice)
        case let .pause(id):
            guard snapshot.timer.session?.id == id, snapshot.timer.mode == .running else { return false }
            var next = snapshot
            guard next.pause(remaining: rawRemaining(at: clock.now())) else { return false }
            return await persist(next, anchor: nil, failure: "一時停止を保存できず、タイマーは継続しています。", haptic: .stop)
        case let .discard(id, switchPhase):
            guard snapshot.timer.session?.id == id else { return false }
            var next = snapshot
            next.reset(switchPhase: switchPhase)
            return await persist(next, anchor: nil, failure: "途中経過を破棄できませんでした。タイマーの状態は変更していません。")
        case let .durations(focus, rest):
            var next = snapshot
            next.settings.focusMinutes = focus
            next.settings.restMinutes = rest
            return await persistCurrent(next, failure: "時間を保存できませんでした。変更前の設定を使います。")
        case let .haptics(enabled):
            var next = snapshot
            next.settings.operationHapticsEnabled = enabled
            return await persistCurrent(next, failure: "設定を保存できませんでした。")
        case let .notifications(enabled, choice):
            return await setNotifications(enabled, choice: choice)
        case .deleteRecords:
            var next = snapshot
            next.focusRecords.removeAll()
            return await persistCurrent(next, failure: "記録を削除できませんでした。記録はそのまま残っています。")
        case .finishOnboarding:
            var next = snapshot
            next.settings.onboardingCompleted = true
            let saved = await persistCurrent(next, failure: "案内の確認を保存できませんでした。")
            if saved { route = .controls }
            return saved
        case let .refresh(reason):
            if case .retry = reason {
                guard await persistCurrent(snapshot, failure: "保存できませんでした。もう一度再試行してください。") else { return false }
            }
            updateNotifications()
            scheduleCompletion()
            if case .activation = reason, routeOnActivation {
                chooseLaunchRoute()
                routeOnActivation = false
            }
            return true
        case let .foregroundNotification(payload): return await foregroundNotification(payload)
        case let .respondToNotification(payload, action):
            if case .dismiss = action { return false }
            route = .controls
            guard let payload, validCompletedNotification(payload),
                  case let .start(phase) = action, phase == snapshot.timer.phase else { return false }
            return await begin(resume: false, choice: nil)
        }
    }

    private func load(reset: Bool) async -> Bool {
        await notifications.removeLegacyNotification()
        do {
            var next = try await (reset ? storage.reset() : storage.load())
            try next.validate()
            let saved = next
            let reading = clock.now()
            var restoredAnchor: RunningAnchor?
            if let session = next.timer.session, next.timer.mode == .running, let deadline = session.deadline {
                let remaining = min(session.savedRemaining, deadline.timeIntervalSince(reading.wall))
                if remaining <= 0 {
                    next.complete(at: deadline)
                } else {
                    restoredAnchor = RunningAnchor(sessionID: session.id, remaining: remaining, elapsed: reading.elapsed)
                    next.timer.session?.savedRemaining = remaining
                    let correctedDeadline = reading.wall.addingTimeInterval(remaining)
                    if abs(correctedDeadline.timeIntervalSince(deadline)) > 2 {
                        next.timer.session?.deadline = correctedDeadline
                        if next.settings.notificationsEnabled {
                            next.notificationIntent = NotificationIntent(sessionID: session.id, token: UUID(),
                                                                         deadline: correctedDeadline, phase: session.phase)
                        }
                    }
                }
            }
            next.pruneRecords(at: reading.wall)
            // A changed restoration is one transaction; unchanged ready/paused data needs no write.
            do {
                if next != saved { try await storage.save(next) }
            } catch {
                snapshot = saved
                isLoaded = true
                if let session = saved.timer.session, saved.timer.mode == .running, let deadline = session.deadline {
                    let remaining = min(session.savedRemaining, deadline.timeIntervalSince(reading.wall))
                    anchor = RunningAnchor(sessionID: session.id, remaining: remaining, elapsed: reading.elapsed)
                    completionPending = remaining <= 0
                }
                storageError = completionPending
                    ? "完了を保存できませんでした。新しい回を始める前に再試行してください。"
                    : "復元した状態を保存できませんでした。再試行してください。"
                route = .controls
                updateNotifications()
                return false
            }
            snapshot = next
            anchor = restoredAnchor
            isLoaded = true
            storageError = nil
            completionPending = false
            chooseLaunchRoute()
            updateNotifications()
            scheduleCompletion()
            return true
        } catch {
            storageError = (error as? StateError)?.errorDescription ?? "保存データを読み込めません。再試行するか、確認して初期化してください。"
            route = .controls
            return false
        }
    }

    private func chooseLaunchRoute() {
        if !snapshot.settings.onboardingCompleted { route = .onboarding }
        else { route = snapshot.timer.mode == .running ? .dial : .controls }
    }

    private func begin(resume: Bool, choice: PermissionChoice?) async -> Bool {
        guard !completionPending, storageError == nil,
              snapshot.timer.mode == (resume ? .paused : .ready) else { return false }
        var next = snapshot
        if next.settings.notificationsEnabled {
            let access = await notifications.inspectPermission()
            if access.authorization == .notDetermined {
                guard let choice else { permissionPrompt = resume ? .resume : .start; return false }
                if choice == .withoutNotifications { next.settings.notificationsEnabled = false }
                else { await notifications.requestPermission() }
            }
        }
        let reading = clock.now()
        let changed = resume ? next.resume(at: reading.wall) : next.start(at: reading.wall)
        guard changed, let session = next.timer.session else { return false }
        let newAnchor = RunningAnchor(sessionID: session.id, remaining: session.savedRemaining, elapsed: reading.elapsed)
        guard await persist(next, anchor: newAnchor,
                            failure: "開始を保存できませんでした。タイマーは開始していません。", haptic: .start) else { return false }
        startNotice = false
        startPresentationTask?.cancel()
        if !next.settings.notificationsEnabled { route = .dial }
        else {
            let token = next.notificationIntent?.token
            startPresentationTask = Task { [weak self, notifications] in
                await notifications.waitForIdle()
                guard !Task.isCancelled, let self, self.snapshot.timer.mode == .running,
                      self.snapshot.timer.session?.id == session.id, self.snapshot.notificationIntent?.token == token else { return }
                if notifications.permissionRequestFailed || notifications.state.cannotDeliver(token: token) {
                    self.startNotice = true
                } else { self.route = .dial }
            }
        }
        return true
    }

    private func setNotifications(_ enabled: Bool, choice: PermissionChoice?) async -> Bool {
        var enabled = enabled
        if enabled {
            let access = await notifications.inspectPermission()
            if access.authorization == .notDetermined {
                guard let choice else { permissionPrompt = .enable; return false }
                if choice == .withoutNotifications { enabled = false }
                else { await notifications.requestPermission() }
            }
        }
        guard await reconcile(reason: .operation) else { return false }
        var next = snapshot
        next.settings.notificationsEnabled = enabled
        next.notificationIntent = nil
        if enabled, next.timer.mode == .running, let session = next.timer.session {
            next.notificationIntent = NotificationIntent(sessionID: session.id, token: UUID(),
                                                         deadline: clock.now().wall.addingTimeInterval(remaining), phase: session.phase)
        }
        return await persistCurrent(next, failure: "通知設定を保存できませんでした。変更前の設定を使います。")
    }

    private func reconcile(reason: RefreshReason) async -> Bool {
        guard snapshot.timer.mode == .running, let session = snapshot.timer.session else { return true }
        let reading = clock.now()
        let remaining = rawRemaining(at: reading)
        if remaining <= 0 {
            let generation = activityGeneration
            let canFallback: Bool
            if case .deadline = reason {
                canFallback = isActive && notifications.state.cannotDeliver(token: snapshot.notificationIntent?.token)
                    && (notifications.access.authorization != .allowed || notifications.access.soundEnabled)
            }
            else { canFallback = false }
            var next = snapshot
            next.complete(at: reading.wall.addingTimeInterval(remaining))
            guard await persist(next, anchor: nil, failure: "完了を保存できませんでした。新しい回を始める前に再試行してください。") else {
                completionPending = true
                completionTask?.cancel()
                completionTask = nil
                return false
            }
            if canFallback, isActive, activityGeneration == generation, next.settings.notificationsEnabled, fallbackSession != session.id {
                fallbackSession = session.id
                haptic(.success)
            }
        } else if let deadline = session.deadline {
            let corrected = reading.wall.addingTimeInterval(remaining)
            if abs(corrected.timeIntervalSince(deadline)) > 2 {
                var next = snapshot
                next.timer.session?.deadline = corrected
                next.timer.session?.savedRemaining = remaining
                if next.settings.notificationsEnabled {
                    next.notificationIntent = NotificationIntent(sessionID: session.id, token: UUID(), deadline: corrected, phase: session.phase)
                }
                return await persist(next, anchor: anchor, failure: "時刻の変更を保存できませんでした。タイマーは継続しています。")
            }
        }
        return true
    }

    private func persistCurrent(_ candidate: TimerSnapshot, failure: String) async -> Bool {
        var next = candidate
        if next.timer.mode == .running, let session = next.timer.session {
            let reading = clock.now()
            let remaining = rawRemaining(at: reading)
            guard remaining > 0 else {
                _ = await reconcile(reason: .operation)
                return false
            }
            let deadline = reading.wall.addingTimeInterval(remaining)
            next.timer.session?.savedRemaining = remaining
            next.timer.session?.deadline = deadline
            if next.notificationIntent != nil { next.notificationIntent?.deadline = deadline }
            guard session.id == anchor?.sessionID else { return false }
        }
        return await persist(next, anchor: anchor, failure: failure)
    }

    private func persist(_ candidate: TimerSnapshot, anchor newAnchor: RunningAnchor?, failure: String,
                         haptic requestedHaptic: TimerHaptic? = nil) async -> Bool {
        var next = candidate
        next.pruneRecords(at: clock.now().wall)
        do {
            try next.validate()
            try await storage.save(next)
            snapshot = next
            anchor = newAnchor
            storageError = nil
            completionPending = false
            updateNotifications()
            scheduleCompletion()
            if let requestedHaptic, next.settings.operationHapticsEnabled, isActive { haptic(requestedHaptic) }
            return true
        } catch {
            storageError = failure
            return false
        }
    }

    private func updateNotifications() {
        let now = clock.now()
        notifications.update(NotificationPlan(intent: snapshot.notificationIntent, running: snapshot.timer.mode == .running,
                                              enabled: snapshot.settings.notificationsEnabled,
                                              remaining: rawRemaining(at: now), elapsed: now.elapsed))
    }

    private func scheduleCompletion() {
        completionTask?.cancel()
        completionTask = nil
        guard isActive, !completionPending, snapshot.timer.mode == .running, let id = snapshot.timer.session?.id else { return }
        let seconds = max(0, rawRemaining(at: clock.now()))
        let generation = activityGeneration
        let sleep = clock.sleep
        completionTask = Task { [weak self] in
            do { try await sleep(seconds) } catch { return }
            guard !Task.isCancelled else { return }
            await self?.send(.refresh(.deadline(id, generation)))
        }
    }

    private func validCompletedNotification(_ payload: NotificationPayload) -> Bool {
        guard snapshot.settings.notificationsEnabled, let intent = snapshot.notificationIntent,
              payload == NotificationPayload(intent: intent), case let .completed(id) = snapshot.timer.readyReason,
              id == payload.sessionID, snapshot.lastCompletion?.notificationToken == payload.token else { return false }
        return true
    }

    private func foregroundNotification(_ payload: NotificationPayload?) async -> Bool {
        guard let payload, let intent = snapshot.notificationIntent, payload == NotificationPayload(intent: intent) else { return false }
        if validCompletedNotification(payload) { return true }
        if snapshot.timer.mode == .running, remaining > 0 {
            var next = snapshot
            next.notificationIntent?.token = UUID()
            _ = await persistCurrent(next, failure: "通知時刻を保存できませんでした。タイマーは継続しています。")
        }
        return false
    }
}
