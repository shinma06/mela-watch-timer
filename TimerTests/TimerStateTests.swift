import Foundation
import Testing
@testable import mela_watch_timer_Watch_App

struct TimerStateTests {
    @Test func startPauseResumeAndComplete() throws {
        var state = TimerSnapshot()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let started = state.start(at: now)
        #expect(started)
        let session = try #require(state.timer.session)
        let secondStart = state.start(at: now.addingTimeInterval(1))
        #expect(!secondStart)
        #expect(state.timer.session == session)
        let paused = state.pause(remaining: 1489.6)
        #expect(paused)
        #expect(state.timer.session?.deadline == nil)
        let resumed = state.resume(at: now.addingTimeInterval(110.4))
        #expect(resumed)
        #expect(state.timer.session?.duration == 1500)
        #expect(state.timer.session?.deadline == now.addingTimeInterval(1600))
        let completed = state.complete(at: now.addingTimeInterval(1600))
        #expect(completed)
        let secondCompletion = state.complete(at: now.addingTimeInterval(1601))
        #expect(!secondCompletion)
        #expect(state.focusRecords.count == 1)
        #expect(state.timer.phase == .rest)
        #expect(state.notificationIntent?.sessionID == session.id)
        try state.validate()
    }

    @Test(arguments: [0, 121, -1]) func invalidFocusMinutes(minutes: Int) {
        var state = TimerSnapshot()
        state.settings.focusMinutes = minutes
        #expect(throws: StateError.invalidData) { try state.validate() }
    }

    @Test(arguments: [1, 120]) func validFocusBoundaries(minutes: Int) throws {
        var state = TimerSnapshot()
        state.settings.focusMinutes = minutes
        state.start(at: Date())
        try state.validate()
    }

    @Test func settingsAndDiscard() throws {
        var state = TimerSnapshot()
        state.start(at: Date())
        state.settings.focusMinutes = 50
        #expect(state.timer.session?.duration == 1500)
        state.reset(switchPhase: false)
        #expect(state.settings.duration(for: state.timer.phase) == 3000)
        #expect(state.focusRecords.isEmpty)
        #expect(state.notificationIntent == nil)
        try state.validate()
    }

    @Test(arguments: [1.0, 0.75, 0.5, 0.25, 0.0]) func dial(ratio: Double) {
        for size in [(162.0, 197.0), (205.0, 251.0)] {
            let dial = DialGeometry(width: size.0, height: size.1, ratio: ratio)
            #expect(dial.center == CGPoint(x: size.0 / 2, y: size.1 / 2))
            #expect(dial.radius > hypot(size.0, size.1) / 2)
            #expect(dial.elapsedAngle == 2 * .pi * (1 - ratio))
        }
    }
}
