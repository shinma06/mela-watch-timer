import Foundation
import Testing
@testable import mela_watch_timer_Watch_App

struct StateStoreTests {
    @Test func A18_missingAtomicRoundTripAndUnknownSchema() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let url = directory.appending(path: "state-v1.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = StateStore(url: url)
        let initial = try await store.load()
        #expect(initial == TimerSnapshot())
        var state = initial
        state.start(at: Date(timeIntervalSince1970: 1_800_000_000))
        try await store.save(state)
        let loaded = try await store.load()
        #expect(loaded == state)
        let unknown = Data("{\"schemaVersion\":999}".utf8)
        try unknown.write(to: url)
        await #expect(throws: StateError.unsupportedVersion(999)) { try await store.load() }
        #expect(try Data(contentsOf: url) == unknown)
        let reset = try await store.reset()
        #expect(reset == TimerSnapshot())
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let backup = try #require(files.first { $0.lastPathComponent.hasPrefix("state-backup-") })
        #expect(try Data(contentsOf: backup) == unknown)
    }

    @Test @MainActor func A18_corruptDataIsNotOverwrittenAndLegacyNotificationIsRemoved() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "state-v1.json")
        let data = Data("{broken".utf8)
        try data.write(to: url)
        let alerts = TestNotifications()
        await alerts.seed(["pomodoro.timer", "unrelated.notification"])
        let model = TimerModel(storage: .file(at: url), notificationClient: alerts.client,
                               clock: TestTime().clock, haptic: { _ in })
        await model.send(.load)
        #expect(!model.isLoaded)
        #expect(model.storageError != nil)
        #expect(try Data(contentsOf: url) == data)
        #expect(await alerts.ids == ["unrelated.notification"])
        await model.send(.initializeConfirmed)
        #expect(model.isLoaded)
        #expect(model.snapshot.timer.mode == .ready)
    }

    @Test func A18_failedResetPreservesOriginal() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "state-v1.json")
        let original = Data("unreadable as JSON but must be preserved".utf8)
        try original.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = StateStore(url: url)
        await #expect(throws: (any Error).self) { try await store.reset() }
        #expect(try Data(contentsOf: url) == original)
    }
}
