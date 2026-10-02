import Foundation
import Observation
import UserNotifications
import WatchKit

nonisolated struct StorageClient: Sendable {
    var load: @Sendable () async throws -> TimerSnapshot
    var save: @Sendable (TimerSnapshot) async throws -> Void
    var reset: @Sendable () async throws -> TimerSnapshot

    static func file(at url: URL) -> Self {
        let store = StateStore(url: url)
        return Self(load: { try await store.load() }, save: { try await store.save($0) },
                    reset: { try await store.reset() })
    }

    static var application: Self {
        file(at: URL.applicationSupportDirectory.appending(path: "mela/state-v1.json"))
    }
}

actor StateStore {
    private let url: URL

    init(url: URL) { self.url = url }

    func load() throws -> TimerSnapshot {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return TimerSnapshot()
        }
        struct Header: Decodable { let schemaVersion: Int }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let version = try decoder.decode(Header.self, from: data).schemaVersion
        guard version == 1 else { throw StateError.unsupportedVersion(version) }
        let snapshot = try decoder.decode(TimerSnapshot.self, from: data)
        try snapshot.validate()
        return snapshot
    }

    func save(_ snapshot: TimerSnapshot) throws {
        try snapshot.validate()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(snapshot)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
    }

    func reset() throws -> TimerSnapshot {
        // Preserve unreadable/unknown data; a failed backup must never destroy the original.
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            let backup = url.deletingLastPathComponent().appending(path: "state-backup-\(UUID().uuidString).json")
            try data.write(to: backup, options: .atomic)
        }
        let snapshot = TimerSnapshot()
        try save(snapshot)
        return snapshot
    }
}

nonisolated enum NotificationAuthorization: Sendable {
    case notDetermined, allowed, denied
}

nonisolated struct NotificationAccess: Equatable, Sendable {
    var authorization: NotificationAuthorization
    var soundEnabled: Bool
}

nonisolated struct NotificationPayload: Equatable, Sendable {
    var sessionID: UUID
    var token: UUID
    var phase: TimerPhase
    var identifier: String { "mela.session.\(sessionID.uuidString).\(token.uuidString)" }

    init(intent: NotificationIntent) {
        sessionID = intent.sessionID
        token = intent.token
        phase = intent.phase
    }

    init?(userInfo: [AnyHashable: Any], identifier: String) {
        guard let version = userInfo["payloadVersion"] as? Int, version == 1,
              let idString = userInfo["sessionID"] as? String, let id = UUID(uuidString: idString),
              let tokenString = userInfo["token"] as? String, let token = UUID(uuidString: tokenString),
              let phaseString = userInfo["phase"] as? String, let phase = TimerPhase(rawValue: phaseString) else {
            return nil
        }
        self.sessionID = id
        self.token = token
        self.phase = phase
        guard self.identifier == identifier else { return nil }
    }

    var userInfo: [AnyHashable: Any] {
        ["payloadVersion": 1, "sessionID": sessionID.uuidString, "token": token.uuidString, "phase": phase.rawValue]
    }
}

nonisolated struct NotificationClient: Sendable {
    var settings: @Sendable () async -> NotificationAccess
    var requestPermission: @Sendable () async throws -> Void
    var pending: @Sendable () async -> [String]
    var delivered: @Sendable () async -> [String]
    var remove: @Sendable ([String]) async -> Void
    var add: @Sendable (NotificationIntent, TimeInterval) async throws -> Void

    static var system: Self {
        return Self(settings: {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            let authorization: NotificationAuthorization
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: authorization = .allowed
            case .notDetermined: authorization = .notDetermined
            default: authorization = .denied
            }
            return NotificationAccess(authorization: authorization, soundEnabled: settings.soundSetting == .enabled)
        }, requestPermission: {
            _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        }, pending: {
            await UNUserNotificationCenter.current().pendingNotificationRequests().map(\.identifier)
        }, delivered: {
            await UNUserNotificationCenter.current().deliveredNotifications().map { $0.request.identifier }
        }, remove: { ids in
            let center = UNUserNotificationCenter.current()
            center.removePendingNotificationRequests(withIdentifiers: ids)
            center.removeDeliveredNotifications(withIdentifiers: ids)
        }, add: { intent, remaining in
            guard remaining.isFinite, remaining > 0 else { throw StateError.invalidData }
            let content = UNMutableNotificationContent()
            content.title = intent.phase == .focus ? "集中の時間が終わりました" : "休憩の時間が終わりました"
            content.body = intent.phase == .focus
                ? "ひと息つくタイミングです。休憩は自分のタイミングで始められます。"
                : "準備ができたら、次の集中を始められます。"
            content.sound = .default
            content.interruptionLevel = .active
            content.categoryIdentifier = intent.phase == .focus ? "FOCUS_COMPLETE" : "REST_COMPLETE"
            content.userInfo = NotificationPayload(intent: intent).userInfo
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: remaining, repeats: false)
            try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: intent.identifier, content: content, trigger: trigger))
        })
    }
}

nonisolated enum NotificationScheduleState: Equatable, Sendable {
    case idle, disabled
    case pending(UUID), scheduled(UUID), unavailable(UUID), failed(UUID)

    func cannotDeliver(token: UUID?) -> Bool {
        switch self {
        case let .unavailable(id), let .failed(id): id == token
        default: false
        }
    }
}

nonisolated struct NotificationPlan: Equatable, Sendable {
    var intent: NotificationIntent?
    var running: Bool
    var enabled: Bool
    var remaining: TimeInterval
    var elapsed: TimeInterval
}

@MainActor @Observable
final class NotificationWorker {
    private(set) var access = NotificationAccess(authorization: .notDetermined, soundEnabled: false)
    private(set) var state: NotificationScheduleState = .idle
    private(set) var permissionRequestFailed = false
    @ObservationIgnored private let client: NotificationClient
    @ObservationIgnored private let clock: TimerClock
    @ObservationIgnored private var desired: NotificationPlan?
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var worker: Task<Void, Never>?

    init(client: NotificationClient, clock: TimerClock) {
        self.client = client
        self.clock = clock
    }

    func inspectPermission() async -> NotificationAccess {
        access = await client.settings()
        if access.authorization != .notDetermined { permissionRequestFailed = false }
        return access
    }

    func requestPermission() async {
        do {
            try await client.requestPermission()
            permissionRequestFailed = false
        } catch {
            permissionRequestFailed = true
        }
        access = await client.settings()
    }

    func update(_ plan: NotificationPlan) {
        let previousToken = desired?.intent?.token
        desired = plan
        revision += 1
        if !plan.enabled { state = .disabled }
        else if let token = plan.intent?.token, plan.running, token != previousToken { state = .pending(token) }
        else if plan.intent == nil { state = .idle }
        guard worker == nil else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            var handledRevision = -1
            while handledRevision != self.revision {
                let capturedRevision = self.revision
                if let plan = self.desired { await self.apply(plan, revision: capturedRevision) }
                handledRevision = capturedRevision
            }
            self.worker = nil
        }
    }

    func waitForIdle() async { await worker?.value }

    func removeLegacyNotification() async { await client.remove(["pomodoro.timer"]) }

    private func apply(_ plan: NotificationPlan, revision capturedRevision: Int) async {
        let access = await client.settings()
        let pending = await client.pending()
        let delivered = await client.delivered()
        guard capturedRevision == revision else { return }
        self.access = access
        let keep = plan.enabled ? plan.intent?.identifier : nil
        let obsolete = Set(pending + delivered + ["pomodoro.timer"]).filter {
            ($0.hasPrefix("mela.session.") || $0 == "pomodoro.timer") && $0 != keep
        }
        if !obsolete.isEmpty { await client.remove(Array(obsolete)) }
        guard capturedRevision == revision, plan.running, plan.enabled, let intent = plan.intent else { return }
        guard access.authorization == .allowed else {
            state = .unavailable(intent.token)
            return
        }
        if pending.contains(intent.identifier) || delivered.contains(intent.identifier) {
            state = .scheduled(intent.token)
            return
        }
        let remaining = plan.remaining - (clock.now().elapsed - plan.elapsed)
        guard remaining.isFinite, remaining > 0 else { return }
        state = .pending(intent.token)
        do {
            try await client.add(intent, remaining)
            guard desired?.intent?.token == intent.token, desired?.enabled == true else {
                await client.remove([intent.identifier])
                return
            }
            state = .scheduled(intent.token)
        } catch {
            guard desired?.intent?.token == intent.token, desired?.enabled == true else {
                await client.remove([intent.identifier])
                return
            }
            state = .failed(intent.token)
        }
    }

    var message: String {
        if state == .disabled { return "終了のお知らせはオフです" }
        if permissionRequestFailed { return "通知の状態を確認できませんでした" }
        if case .failed = state { return "終了のお知らせを設定できませんでした" }
        if access.authorization != .allowed { return "画面を閉じている間は終了をお知らせできません" }
        if !access.soundEnabled { return "音と振動はWatchの設定を確認してください" }
        return "終了のお知らせはWatchの設定に従います"
    }
}

nonisolated enum TimerHaptic: Sendable { case start, stop, success }

@MainActor
func playTimerHaptic(_ haptic: TimerHaptic) {
    switch haptic {
    case .start: WKInterfaceDevice.current().play(.start)
    case .stop: WKInterfaceDevice.current().play(.stop)
    case .success: WKInterfaceDevice.current().play(.success)
    }
}
