import Foundation
import SwiftUI
import Synchronization
import Testing
@testable import mela_watch_timer_Watch_App

final class TestTime: Sendable {
    private let reading = Mutex(ClockReading(wall: Date(timeIntervalSince1970: 1_800_000_000), elapsed: 0))
    func now() -> ClockReading { reading.withLock { $0 } }
    func advance(_ seconds: Double, wall: Double? = nil) {
        reading.withLock { $0.wall.addTimeInterval(wall ?? seconds); $0.elapsed += seconds }
    }
    var clock: TimerClock {
        TimerClock(now: { self.now() }, sleep: { _ in try await Task.sleep(for: .seconds(86_400)) })
    }
}

actor TestStore {
    var value: TimerSnapshot
    var writes: [TimerSnapshot] = []
    var fail = false
    init(_ value: TimerSnapshot) { self.value = value }
    func setFailure(_ fail: Bool) { self.fail = fail }
    func load() -> TimerSnapshot { value }
    func save(_ next: TimerSnapshot) throws {
        if fail { throw CocoaError(.fileWriteOutOfSpace) }
        try next.validate()
        value = next
        writes.append(next)
    }
    nonisolated var client: StorageClient {
        StorageClient(load: { await self.load() }, save: { try await self.save($0) }, reset: {
            try await self.save(TimerSnapshot())
            return await self.load()
        })
    }
}

actor TestNotifications {
    var access = NotificationAccess(authorization: .allowed, soundEnabled: true)
    var ids: Set<String> = []
    var deliveredIDs: Set<String> = []
    var additions: [(NotificationIntent, Double)] = []
    var removals: [String] = []
    var permissionFails = false
    var addFails = false
    var holding = false
    var pendingAdds: [UUID: CheckedContinuation<Void, Error>] = [:]
    var addWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func configure(access: NotificationAccess? = nil, permissionFails: Bool = false, addFails: Bool = false, holding: Bool = false) {
        if let access { self.access = access }
        self.permissionFails = permissionFails
        self.addFails = addFails
        self.holding = holding
    }
    func permissions() -> NotificationAccess { access }
    func request() throws {
        if permissionFails { throw CocoaError(.featureUnsupported) }
        access = NotificationAccess(authorization: .allowed, soundEnabled: true)
    }
    func add(_ intent: NotificationIntent, seconds: Double) async throws {
        additions.append((intent, seconds))
        let ready = addWaiters.filter { additions.count >= $0.0 }
        addWaiters.removeAll { additions.count >= $0.0 }
        ready.forEach { $0.1.resume() }
        if holding { try await withCheckedThrowingContinuation { pendingAdds[intent.token] = $0 } }
        if addFails { throw CocoaError(.featureUnsupported) }
        ids.insert(intent.identifier)
    }
    func finish(_ token: UUID, fail: Bool = false) {
        let continuation = pendingAdds.removeValue(forKey: token)
        if fail { continuation?.resume(throwing: CocoaError(.featureUnsupported)) }
        else { continuation?.resume() }
    }
    func waitForAdd(_ count: Int = 1) async {
        if additions.count >= count { return }
        await withCheckedContinuation { addWaiters.append((count, $0)) }
    }
    func remove(_ identifiers: [String]) {
        removals.append(contentsOf: identifiers)
        ids.subtract(identifiers)
        deliveredIDs.subtract(identifiers)
    }
    func seed(_ identifiers: Set<String>) { ids.formUnion(identifiers) }
    nonisolated var client: NotificationClient {
        NotificationClient(settings: { await self.permissions() }, requestPermission: { try await self.request() },
                           pending: { await Array(self.ids) }, delivered: { await Array(self.deliveredIDs) },
                           remove: { await self.remove($0) }, add: { try await self.add($0, seconds: $1) })
    }
}

@MainActor final class Haptics {
    var values: [TimerHaptic] = []
    var starts: Int { values.filter { $0 == .start }.count }
    var completions: Int { values.filter { $0 == .success }.count }
}

@MainActor final class Fixture {
    let time: TestTime
    let store: TestStore
    let alerts: TestNotifications
    let haptics = Haptics()
    let model: TimerModel

    init(snapshot: TimerSnapshot = TimerSnapshot(), time: TestTime = TestTime(), alerts: TestNotifications = TestNotifications()) {
        self.time = time
        store = TestStore(snapshot)
        self.alerts = alerts
        let haptics = haptics
        model = TimerModel(storage: store.client, notificationClient: alerts.client, clock: time.clock,
                           haptic: { haptics.values.append($0) })
    }
    func load(active: Bool = false) async {
        await model.send(.load)
        if active {
            model.setActive(true)
            await model.send(.refresh(.activation))
        }
    }
    func start() async {
        await model.send(.start())
        await model.notifications.waitForIdle()
    }
}

@MainActor struct TimerModelTests {
    @Test func A01_startIsOneTransaction() async {
        let f = Fixture()
        await f.load(active: true)
        defer { f.model.setActive(false) }
        async let a = f.model.send(.start())
        async let b = f.model.send(.start())
        let results = await [a, b]
        await f.model.notifications.waitForIdle()
        #expect(results.filter { $0 }.count == 1)
        #expect(f.model.snapshot.timer.session?.duration == 1500)
        #expect(f.haptics.starts == 1)
        #expect(await f.alerts.additions.count == 1)
    }

    @Test func A02_pauseResumeUsesPreciseElapsedTime() async throws {
        let f = Fixture()
        await f.load()
        await f.start()
        let id = try #require(f.model.snapshot.timer.session?.id)
        f.time.advance(10.4)
        await f.model.send(.pause(id))
        #expect(abs(f.model.remaining - 1489.6) < 0.000_001)
        f.time.advance(100)
        #expect(abs(f.model.remaining - 1489.6) < 0.000_001)
        await f.model.send(.resume())
        #expect(f.model.snapshot.timer.session?.id == id)
        #expect(f.model.duration == 1500)
        let deadline = try #require(f.model.snapshot.timer.session?.deadline)
        #expect(abs(deadline.timeIntervalSince(f.time.now().wall) - 1489.6) < 0.000_001)
    }

    @Test(arguments: [-0.001, 0, 0.001]) func A03_deadlineWinsOverPause(offset: Double) async throws {
        let f = Fixture()
        await f.load()
        await f.start()
        let id = try #require(f.model.snapshot.timer.session?.id)
        f.time.advance(1500 + offset)
        await f.model.send(.refresh(.operation))
        #expect(f.model.snapshot.timer.mode == (offset < 0 ? .running : .ready))
        await f.model.send(.pause(id))
        if offset < 0 {
            #expect(f.model.snapshot.timer.mode == .paused)
            #expect(f.model.snapshot.focusRecords.isEmpty)
        } else {
            #expect(f.model.snapshot.timer.mode == .ready)
            #expect(f.model.snapshot.timer.phase == .rest)
            #expect(f.model.snapshot.focusRecords.count == 1)
        }
    }

    @Test(arguments: [false, true]) func A04_discardDoesNotComplete(switchPhase: Bool) async throws {
        let f = Fixture()
        await f.load()
        await f.start()
        let id = try #require(f.model.snapshot.timer.session?.id)
        f.time.advance(10)
        if switchPhase { await f.model.send(.pause(id)) }
        await f.model.send(.discard(id, switchPhase: switchPhase))
        #expect(f.model.snapshot.focusRecords.isEmpty)
        #expect(f.model.snapshot.timer.mode == .ready)
        #expect(f.model.snapshot.timer.phase == (switchPhase ? .rest : .focus))
        #expect(f.model.snapshot.notificationIntent == nil)
        #expect(f.haptics.completions == 0)
    }

    @Test func A05_durationIsFixedForStartedSession() async throws {
        let f = Fixture()
        await f.load()
        await f.start()
        let id = try #require(f.model.snapshot.timer.session?.id)
        await f.model.send(.durations(focus: 50, rest: 5))
        f.time.advance(10)
        await f.model.send(.pause(id))
        await f.model.send(.resume())
        #expect(f.model.duration == 1500)
        #expect(f.model.remaining == 1490)
        await f.model.send(.discard(id, switchPhase: false))
        #expect(f.model.duration == 3000)
        // A cancelled picker does not send a command; the saved setting stays unchanged.
        #expect(f.model.snapshot.settings.focusMinutes == 50)
    }

    @Test func A06_invalidInputAndRestBounds() async throws {
        let f = Fixture()
        await f.load()
        for minutes in [0, 61] {
            let result = await f.model.send(.durations(focus: 25, rest: minutes))
            #expect(!result)
            #expect(f.model.snapshot.settings.restMinutes == 5)
        }
        for minutes in [1, 60] {
            let result = await f.model.send(.durations(focus: 25, rest: minutes))
            #expect(result)
        }
        var state = TimerSnapshot()
        state.start(at: f.time.now().wall)
        for value in [Double.nan, .infinity, -.infinity] {
            state.timer.session?.savedRemaining = value
            #expect(throws: StateError.invalidData) { try state.validate() }
        }
        let data = try JSONEncoder().encode(TimerSnapshot())
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var settings = try #require(object["settings"] as? [String: Any])
        settings["focusMinutes"] = 1.5
        object["settings"] = settings
        let fractional = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(TimerSnapshot.self, from: fractional) }
        object["timer"] = ["mode": "unknown", "phase": "focus"]
        let invalidEnum = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(TimerSnapshot.self, from: invalidEnum) }
    }

    @Test(arguments: [300.0, 2100.0]) func A07_processRestoreDoesNotInventRounds(elapsed: Double) async {
        let original = Fixture()
        await original.load()
        await original.start()
        original.time.advance(elapsed)
        let restored = Fixture(snapshot: await original.store.value, time: original.time)
        await restored.load()
        if elapsed < 1500 { #expect(restored.model.remaining == 1200) }
        else {
            #expect(restored.model.snapshot.timer.mode == .ready)
            #expect(restored.model.snapshot.timer.phase == .rest)
            #expect(restored.model.snapshot.focusRecords.count == 1)
            #expect(await restored.alerts.additions.isEmpty)
        }
    }

    @Test func A07_pausedRestoreIsFixed() async throws {
        let f = Fixture()
        await f.load()
        await f.start()
        let id = try #require(f.model.snapshot.timer.session?.id)
        f.time.advance(10)
        await f.model.send(.pause(id))
        f.time.advance(9000)
        let restored = Fixture(snapshot: await f.store.value, time: f.time)
        await restored.load()
        #expect(restored.model.snapshot.timer.mode == .paused)
        #expect(restored.model.remaining == 1490)
    }

    @Test func A08_completionAndHistoryAreAtomicAndIdempotent() async throws {
        let f = Fixture()
        await f.load(active: true)
        defer { f.model.setActive(false) }
        await f.start()
        let intent = try #require(f.model.snapshot.notificationIntent)
        f.time.advance(1500)
        await f.model.send(.refresh(.deadline(intent.sessionID, 1)))
        await f.model.send(.refresh(.activation))
        await f.model.send(.foregroundNotification(NotificationPayload(intent: intent)))
        let saved = await f.store.value
        let restored = Fixture(snapshot: saved, time: f.time)
        await restored.load()
        #expect(restored.model.snapshot.focusRecords.count == 1)
        #expect(restored.model.snapshot.lastCompletion?.sessionID == intent.sessionID)
        let writes = await f.store.writes
        #expect(writes.allSatisfy { $0.focusRecords.isEmpty || $0.timer.mode == .ready })
    }

    @Test(arguments: ["start", "pause", "complete", "settings", "delete"]) func A09_saveFailuresKeepPriorState(operation: String) async throws {
        var snapshot = TimerSnapshot()
        snapshot.focusRecords = [FocusRecord(sessionID: UUID(), duration: 60, endedAt: TestTime().now().wall)]
        let f = Fixture(snapshot: snapshot)
        await f.load()
        if operation == "pause" || operation == "complete" { await f.start() }
        let prior = f.model.snapshot
        await f.store.setFailure(true)
        switch operation {
        case "start": await f.model.send(.start())
        case "pause": await f.model.send(.pause(try #require(prior.timer.session?.id)))
        case "complete": f.time.advance(1500); await f.model.send(.refresh(.activation))
        case "settings": await f.model.send(.durations(focus: 50, rest: 10))
        default: await f.model.send(.deleteRecords)
        }
        #expect(f.model.snapshot == prior)
        #expect(f.model.storageError != nil)
        if operation == "start" { #expect(await f.alerts.additions.isEmpty) }
        if operation == "pause" { #expect(f.model.status == "集中中") }
        if operation == "complete" {
            #expect(f.model.completionPending)
            #expect(f.model.remaining == 0)
            let payload = NotificationPayload(intent: try #require(prior.notificationIntent))
            let sound = await f.model.send(.foregroundNotification(payload))
            #expect(sound)
            await f.store.setFailure(false)
            await f.model.send(.refresh(.retry))
            #expect(f.model.snapshot.focusRecords.count == 2)
            #expect(!f.model.completionPending)
        }
    }

    @Test func A10_lateAddIsRemovedAfterPause() async throws {
        let alerts = TestNotifications()
        await alerts.configure(holding: true)
        let f = Fixture(alerts: alerts)
        await f.load()
        await f.model.send(.start())
        await alerts.waitForAdd()
        let intent = try #require(f.model.snapshot.notificationIntent)
        await f.model.send(.pause(intent.sessionID))
        #expect(f.model.snapshot.timer.mode == .paused)
        await alerts.finish(intent.token)
        await f.model.notifications.waitForIdle()
        #expect(await alerts.ids.isEmpty)
        #expect(await alerts.removals.contains(intent.identifier))
    }

    @Test func A11_actionsAreValidatedAndOnlyStartOnce() async throws {
        let f = Fixture()
        await f.load()
        await f.start()
        let payload = NotificationPayload(intent: try #require(f.model.snapshot.notificationIntent))
        f.time.advance(1500)
        let first = await f.model.send(.respondToNotification(payload, .start(.rest)))
        let id = f.model.snapshot.timer.session?.id
        let second = await f.model.send(.respondToNotification(payload, .start(.rest)))
        let invalid = await f.model.send(.respondToNotification(nil, .start(.focus)))
        #expect(first)
        #expect(!second && !invalid)
        #expect(f.model.snapshot.timer.session?.id == id)
        #expect(f.model.snapshot.timer.phase == .rest)
        #expect(NotificationPayload(userInfo: ["payloadVersion": 2], identifier: payload.identifier) == nil)
    }

    @Test(arguments: [0.0, 0.25, 0.5, 0.75, 1.0]) func A12_realShapeCoversExpectedQuadrants(ratio: Double) {
        for size in [(162.0, 197.0), (205.0, 251.0), (251.0, 205.0)] {
            let rect = CGRect(x: 0, y: 0, width: size.0, height: size.1)
            let path = RemainingSector(ratio: ratio).path(in: rect)
            let quadrants = [CGPoint(x: size.0 - 1, y: 1), CGPoint(x: size.0 - 1, y: size.1 - 1),
                             CGPoint(x: 1, y: size.1 - 1), CGPoint(x: 1, y: 1)]
            for (quadrant, point) in quadrants.enumerated() {
                #expect(path.contains(point) == (Double(quadrant) >= 4 * (1 - ratio)))
            }
            if ratio == 0 { #expect(path.isEmpty) }
        }
    }

    @Test(arguments: ["denied", "silent", "off", "error"]) func A13_permissionOutcomesDoNotStopTimer(kind: String) async {
        var state = TimerSnapshot()
        let alerts = TestNotifications()
        switch kind {
        case "denied": await alerts.configure(access: NotificationAccess(authorization: .denied, soundEnabled: false))
        case "silent": await alerts.configure(access: NotificationAccess(authorization: .allowed, soundEnabled: false))
        case "off": state.settings.notificationsEnabled = false
        default: await alerts.configure(access: NotificationAccess(authorization: .notDetermined, soundEnabled: false), permissionFails: true)
        }
        let f = Fixture(snapshot: state, alerts: alerts)
        await f.load()
        await f.model.send(.start(.allow))
        await f.model.notifications.waitForIdle()
        #expect(f.model.snapshot.timer.mode == .running)
        #expect(f.haptics.completions == 0)
        if kind == "off" || kind == "denied" || kind == "error" { #expect(await alerts.ids.isEmpty) }
        if kind == "error" { #expect(f.model.notifications.permissionRequestFailed) }
        if kind == "silent" { #expect(f.model.notifications.message.contains("音と振動")) }
    }

    @Test(arguments: [false, true]) func A14_staleAddCannotPolluteNewGeneration(failOld: Bool) async throws {
        let alerts = TestNotifications()
        await alerts.configure(holding: true)
        let f = Fixture(alerts: alerts)
        await f.load()
        await f.model.send(.start())
        await alerts.waitForAdd()
        let old = try #require(f.model.snapshot.notificationIntent)
        await f.model.send(.pause(old.sessionID))
        await f.model.send(.resume())
        let latest = try #require(f.model.snapshot.notificationIntent)
        #expect(latest.token != old.token)
        // The one worker serializes registration, but a newer OS ID must also survive late cleanup.
        await alerts.seed([latest.identifier])
        await alerts.configure(holding: false)
        await alerts.finish(old.token, fail: failOld)
        await f.model.notifications.waitForIdle()
        #expect(await alerts.ids == [latest.identifier])
        #expect(f.model.notifications.state == .scheduled(latest.token))
    }

    @Test(arguments: [0.0, 0.000_01]) func A15_triggerOnlyReceivesPositiveRemaining(remaining: Double) async {
        let time = TestTime()
        let alerts = TestNotifications()
        let worker = NotificationWorker(client: alerts.client, clock: time.clock)
        let intent = NotificationIntent(sessionID: UUID(), token: UUID(), deadline: time.now().wall.addingTimeInterval(remaining), phase: .focus)
        worker.update(NotificationPlan(intent: intent, running: true, enabled: true, remaining: remaining, elapsed: 0))
        await worker.waitForIdle()
        let additions = await alerts.additions
        #expect(additions.count == (remaining > 0 ? 1 : 0))
        #expect(additions.allSatisfy { $0.1 > 0 && $0.1.isFinite })
    }

    @Test func A15_addFailureDoesNotRollBackStartedSession() async {
        let alerts = TestNotifications()
        await alerts.configure(addFails: true)
        let f = Fixture(alerts: alerts)
        await f.load()
        await f.start()
        #expect(f.model.snapshot.timer.mode == .running)
        #expect(f.model.notifications.state == .failed(f.model.snapshot.notificationIntent!.token))
    }

    @Test(arguments: [false, true]) func A16_notificationAndTaskOrderHasNoExtraHaptic(taskFirst: Bool) async throws {
        let f = Fixture()
        await f.load(active: true)
        defer { f.model.setActive(false) }
        await f.start()
        let intent = try #require(f.model.snapshot.notificationIntent)
        f.time.advance(1500)
        if taskFirst { await f.model.send(.refresh(.deadline(intent.sessionID, 1))) }
        let sound = await f.model.send(.foregroundNotification(NotificationPayload(intent: intent)))
        await f.model.send(.refresh(.deadline(intent.sessionID, 1)))
        #expect(sound)
        #expect(f.haptics.completions == 0)
    }

    @Test(arguments: [false, true]) func A16_fallbackOnlyWhileContinuouslyActive(background: Bool) async throws {
        let alerts = TestNotifications()
        await alerts.configure(access: NotificationAccess(authorization: .denied, soundEnabled: false))
        let f = Fixture(alerts: alerts)
        await f.load(active: true)
        defer { f.model.setActive(false) }
        await f.start()
        let id = try #require(f.model.snapshot.timer.session?.id)
        if background { f.model.setActive(false) }
        f.time.advance(1500)
        await f.model.send(.refresh(.deadline(id, 1)))
        await f.model.send(.refresh(.activation))
        #expect(f.haptics.completions == (background ? 0 : 1))
    }

    @Test func A17_historyGroupsCompletionDayAndRetainsFourteenDays() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let end = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 0, minute: 1)))
        var state = TimerSnapshot()
        state.settings.focusMinutes = 2
        state.start(at: end.addingTimeInterval(-120))
        state.complete(at: end)
        #expect(state.dailyFocus(at: end, calendar: calendar).first?.duration == 120)
        #expect(state.dailyFocus(at: end, calendar: calendar).count == 7)
        calendar.timeZone = TimeZone(secondsFromGMT: -3600)!
        #expect(calendar.component(.day, from: state.dailyFocus(at: end, calendar: calendar)[0].date) == 1)
        state.focusRecords.append(FocusRecord(sessionID: UUID(), duration: 60, endedAt: end.addingTimeInterval(-14 * 86400 - 1)))
        state.pruneRecords(at: end)
        #expect(state.focusRecords.count == 1)
        state.focusRecords.append(state.focusRecords[0])
        #expect(throws: StateError.invalidData) { try state.validate() }
    }

    @Test func A17_deleteKeepsCurrentTimerAndAllowsNewRecord() async {
        let f = Fixture()
        await f.load()
        await f.start()
        let running = f.model.snapshot.timer
        await f.model.send(.deleteRecords)
        #expect(f.model.snapshot.timer == running)
        f.time.advance(1500)
        await f.model.send(.refresh(.activation))
        #expect(f.model.snapshot.focusRecords.count == 1)
    }

    @Test(arguments: [-3600.0, 3600.0]) func A19_wallClockChangesPreserveElapsedTime(change: Double) async throws {
        let f = Fixture()
        await f.load()
        await f.start()
        let token = f.model.snapshot.notificationIntent?.token
        f.time.advance(10, wall: change + 10)
        await f.model.send(.refresh(.activation))
        #expect(f.model.remaining == 1490)
        #expect(f.model.snapshot.notificationIntent?.token != token)
        #expect(f.model.snapshot.timer.session?.deadline == f.time.now().wall.addingTimeInterval(1490))
        f.time.advance(0, wall: -3600)
        let restored = Fixture(snapshot: await f.store.value, time: f.time)
        await restored.load()
        #expect(restored.model.remaining == 1490)
    }

    @Test func A20_completionKeepsNotificationUntilNextStartOrOff() async throws {
        let f = Fixture()
        await f.load()
        await f.start()
        let intent = try #require(f.model.snapshot.notificationIntent)
        f.time.advance(1500)
        await f.model.send(.refresh(.activation))
        await f.model.notifications.waitForIdle()
        #expect(await f.alerts.ids.contains(intent.identifier))
        let sound = await f.model.send(.foregroundNotification(NotificationPayload(intent: intent)))
        #expect(sound)
        await f.start()
        #expect(await !f.alerts.ids.contains(intent.identifier))
        await f.model.send(.notifications(false))
        await f.model.notifications.waitForIdle()
        #expect(await f.alerts.ids.isEmpty)
    }
    @Test func A09_expiredColdRestoreFailureShowsZeroAndRetries() async {
        let time = TestTime()
        var snapshot = TimerSnapshot()
        snapshot.start(at: time.now().wall)
        time.advance(1501)
        let f = Fixture(snapshot: snapshot, time: time)
        await f.store.setFailure(true)
        await f.load()
        #expect(f.model.isLoaded)
        #expect(f.model.completionPending)
        #expect(f.model.remaining == 0)
        #expect(f.model.snapshot.focusRecords.isEmpty)
        await f.store.setFailure(false)
        await f.model.send(.refresh(.retry))
        #expect(f.model.snapshot.focusRecords.count == 1)
        #expect(f.model.snapshot.focusRecords[0].endedAt == snapshot.timer.session?.deadline)
    }

    @Test func A11_earlyForegroundNotificationReschedulesWithoutCompleting() async throws {
        let f = Fixture()
        await f.load()
        await f.start()
        let intent = try #require(f.model.snapshot.notificationIntent)
        f.time.advance(10)
        let sound = await f.model.send(.foregroundNotification(NotificationPayload(intent: intent)))
        await f.model.notifications.waitForIdle()
        #expect(!sound)
        #expect(f.model.remaining == 1490)
        #expect(f.model.snapshot.focusRecords.isEmpty)
        #expect(f.model.snapshot.notificationIntent?.token != intent.token)
        #expect(await !f.alerts.ids.contains(intent.identifier))
    }

    @Test func A13_permissionRationaleDoesNotStartClock() async {
        let alerts = TestNotifications()
        await alerts.configure(access: NotificationAccess(authorization: .notDetermined, soundEnabled: false))
        let f = Fixture(alerts: alerts)
        await f.load()
        let started = await f.model.send(.start())
        #expect(!started)
        #expect(f.model.permissionPrompt == .start)
        #expect(f.model.snapshot.timer.mode == .ready)
        f.time.advance(45)
        await f.model.send(.start(.withoutNotifications))
        #expect(f.model.remaining == 1500)
        #expect(!f.model.snapshot.settings.notificationsEnabled)
        #expect(f.model.snapshot.timer.session?.startedAt == f.time.now().wall)
    }

    @Test func A16_pendingAddAndSoundOffNeverUseFallback() async throws {
        for pending in [true, false] {
            let alerts = TestNotifications()
            await alerts.configure(access: NotificationAccess(authorization: .allowed, soundEnabled: pending),
                                   addFails: !pending, holding: pending)
            let f = Fixture(alerts: alerts)
            await f.load(active: true)
            await f.model.send(.start())
            await alerts.waitForAdd()
            if !pending { await f.model.notifications.waitForIdle() }
            let intent = try #require(f.model.snapshot.notificationIntent)
            f.time.advance(1500)
            await f.model.send(.refresh(.deadline(intent.sessionID, 1)))
            #expect(f.haptics.completions == 0)
            if pending {
                await alerts.finish(intent.token)
                await f.model.notifications.waitForIdle()
            }
            f.model.setActive(false)
        }
    }

    @Test(arguments: [false, true]) func A04_confirmationFromExpiredSessionIsIgnored(switchPhase: Bool) async throws {
        let f = Fixture()
        await f.load()
        await f.start()
        let capturedSessionID = try #require(f.model.snapshot.timer.session?.id)
        let intent = f.model.snapshot.notificationIntent
        f.time.advance(1500)
        await f.model.send(.refresh(.activation))
        let completed = f.model.snapshot
        let discarded = await f.model.send(.discard(capturedSessionID, switchPhase: switchPhase))
        #expect(!discarded)
        #expect(f.model.snapshot == completed)
        #expect(f.model.snapshot.timer.phase == .rest)
        #expect(f.model.snapshot.notificationIntent == intent)
        #expect(f.model.snapshot.focusRecords.count == 1)
    }

    @Test func A10_reopenedControlsAreNotDismissedBySlowAdd() async throws {
        var snapshot = TimerSnapshot()
        snapshot.settings.onboardingCompleted = true
        let alerts = TestNotifications()
        await alerts.configure(holding: true)
        let f = Fixture(snapshot: snapshot, alerts: alerts)
        await f.load()
        await f.model.send(.start())
        await alerts.waitForAdd()
        let intent = try #require(f.model.snapshot.notificationIntent)
        f.model.closeControls()
        f.model.openControls()
        await alerts.finish(intent.token)
        await f.model.notifications.waitForIdle()
        await Task.yield()
        #expect(f.model.route == .controls)
    }

}
