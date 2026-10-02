import Foundation

nonisolated enum TimerPhase: String, Codable, Sendable, CaseIterable {
    case focus, rest

    var next: Self { self == .focus ? .rest : .focus }
    var label: String { self == .focus ? "集中" : "休憩" }
    var maximumMinutes: Int { self == .focus ? 120 : 60 }
}

nonisolated struct TimerSettings: Codable, Equatable, Sendable {
    var focusMinutes = 25
    var restMinutes = 5
    var notificationsEnabled = true
    var operationHapticsEnabled = true
    var onboardingCompleted = false

    func duration(for phase: TimerPhase) -> TimeInterval {
        Double(phase == .focus ? focusMinutes : restMinutes) * 60
    }

    func validate() throws {
        guard (1...120).contains(focusMinutes), (1...60).contains(restMinutes) else {
            throw StateError.invalidData
        }
    }
}

nonisolated enum TimerMode: String, Codable, Sendable {
    case ready, running, paused
}

nonisolated enum ReadyReason: Codable, Equatable, Sendable {
    case initial
    case userSelection
    case completed(UUID)
}

nonisolated struct TimerSession: Codable, Equatable, Sendable {
    var id: UUID
    var phase: TimerPhase
    var duration: TimeInterval
    var startedAt: Date
    var savedRemaining: TimeInterval
    var deadline: Date?
}

nonisolated struct TimerState: Codable, Equatable, Sendable {
    var mode: TimerMode = .ready
    var phase: TimerPhase = .focus
    var session: TimerSession?
    var readyReason: ReadyReason? = .initial
}

nonisolated struct NotificationIntent: Codable, Equatable, Sendable {
    var sessionID: UUID
    var token: UUID
    var deadline: Date
    var phase: TimerPhase

    var identifier: String { "mela.session.\(sessionID.uuidString).\(token.uuidString)" }
}

nonisolated struct TimerCompletion: Codable, Equatable, Sendable {
    var sessionID: UUID
    var phase: TimerPhase
    var duration: TimeInterval
    var endedAt: Date
    var notificationToken: UUID?
}

nonisolated struct FocusRecord: Codable, Equatable, Sendable {
    var sessionID: UUID
    var duration: TimeInterval
    var endedAt: Date
}

nonisolated struct DailyFocus: Equatable, Identifiable, Sendable {
    var date: Date
    var count: Int
    var duration: TimeInterval
    var id: Date { date }
}

nonisolated enum StateError: Error, Equatable, LocalizedError {
    case invalidData
    case unsupportedVersion(Int)

    var errorDescription: String? {
        switch self {
        case .invalidData: "保存データを読み込めません。再試行するか、確認して初期化してください。"
        case .unsupportedVersion: "新しい形式の保存データです。新しいバージョンのmelaで開いてください。"
        }
    }
}

nonisolated struct TimerSnapshot: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var settings = TimerSettings()
    var timer = TimerState()
    var lastCompletion: TimerCompletion?
    var notificationIntent: NotificationIntent?
    var focusRecords: [FocusRecord] = []

    func validate() throws {
        guard schemaVersion == 1 else { throw StateError.unsupportedVersion(schemaVersion) }
        try settings.validate()
        func validDate(_ date: Date) -> Bool { date.timeIntervalSince1970.isFinite }
        func validDuration(_ seconds: Double, for phase: TimerPhase) -> Bool {
            seconds.isFinite && seconds >= 60 && seconds <= Double(phase.maximumMinutes * 60)
                && seconds.truncatingRemainder(dividingBy: 60) == 0
        }
        switch timer.mode {
        case .ready:
            guard timer.session == nil, timer.readyReason != nil else { throw StateError.invalidData }
            if case let .completed(id) = timer.readyReason {
                guard let completion = lastCompletion, completion.sessionID == id,
                      timer.phase == completion.phase.next else { throw StateError.invalidData }
            }
        case .running, .paused:
            guard let session = timer.session, timer.readyReason == nil,
                  timer.phase == session.phase, validDuration(session.duration, for: session.phase),
                  validDate(session.startedAt), session.savedRemaining.isFinite,
                  session.savedRemaining > 0, session.savedRemaining <= session.duration else {
                throw StateError.invalidData
            }
            if timer.mode == .running {
                guard let deadline = session.deadline, validDate(deadline) else { throw StateError.invalidData }
            } else if session.deadline != nil || notificationIntent != nil {
                throw StateError.invalidData
            }
        }
        if let completion = lastCompletion {
            guard validDate(completion.endedAt), validDuration(completion.duration, for: completion.phase) else {
                throw StateError.invalidData
            }
        }
        if let intent = notificationIntent {
            guard settings.notificationsEnabled, validDate(intent.deadline) else { throw StateError.invalidData }
            if timer.mode == .running {
                guard let session = timer.session, intent.sessionID == session.id,
                      intent.phase == session.phase, intent.deadline == session.deadline else {
                    throw StateError.invalidData
                }
            } else {
                guard case let .completed(id) = timer.readyReason,
                      let completion = lastCompletion, id == intent.sessionID,
                      completion.sessionID == id, completion.phase == intent.phase,
                      completion.notificationToken == intent.token else { throw StateError.invalidData }
            }
        }
        guard Set(focusRecords.map(\.sessionID)).count == focusRecords.count,
              focusRecords.allSatisfy({ validDate($0.endedAt) && validDuration($0.duration, for: .focus) }) else {
            throw StateError.invalidData
        }
    }

    @discardableResult
    mutating func start(at now: Date, id: UUID = UUID(), token: UUID = UUID()) -> Bool {
        guard timer.mode == .ready else { return false }
        let duration = settings.duration(for: timer.phase)
        let deadline = now.addingTimeInterval(duration)
        timer.session = TimerSession(id: id, phase: timer.phase, duration: duration,
                                     startedAt: now, savedRemaining: duration, deadline: deadline)
        timer.mode = .running
        timer.readyReason = nil
        notificationIntent = settings.notificationsEnabled
            ? NotificationIntent(sessionID: id, token: token, deadline: deadline, phase: timer.phase) : nil
        return true
    }

    @discardableResult
    mutating func pause(remaining: TimeInterval) -> Bool {
        guard timer.mode == .running, var session = timer.session,
              remaining.isFinite, remaining > 0, remaining <= session.duration else { return false }
        session.savedRemaining = remaining
        session.deadline = nil
        timer.session = session
        timer.mode = .paused
        notificationIntent = nil
        return true
    }

    @discardableResult
    mutating func resume(at now: Date, token: UUID = UUID()) -> Bool {
        guard timer.mode == .paused, var session = timer.session else { return false }
        let deadline = now.addingTimeInterval(session.savedRemaining)
        session.deadline = deadline
        timer.session = session
        timer.mode = .running
        notificationIntent = settings.notificationsEnabled
            ? NotificationIntent(sessionID: session.id, token: token, deadline: deadline, phase: session.phase) : nil
        return true
    }

    @discardableResult
    mutating func complete(at endedAt: Date) -> Bool {
        guard timer.mode == .running, let session = timer.session else { return false }
        lastCompletion = TimerCompletion(sessionID: session.id, phase: session.phase,
                                         duration: session.duration, endedAt: endedAt,
                                         notificationToken: notificationIntent?.token)
        if session.phase == .focus, !focusRecords.contains(where: { $0.sessionID == session.id }) {
            focusRecords.append(FocusRecord(sessionID: session.id, duration: session.duration, endedAt: endedAt))
        }
        timer = TimerState(mode: .ready, phase: session.phase.next, readyReason: .completed(session.id))
        // Keep this deadline's notification valid until the user starts or selects another round.
        return true
    }

    mutating func reset(switchPhase: Bool) {
        timer = TimerState(mode: .ready, phase: switchPhase ? timer.phase.next : timer.phase,
                           readyReason: .userSelection)
        notificationIntent = nil
    }

    mutating func pruneRecords(at now: Date) {
        let cutoff = now.addingTimeInterval(-14 * 24 * 60 * 60)
        focusRecords.removeAll { $0.endedAt < cutoff }
    }

    func dailyFocus(at now: Date, calendar: Calendar = .current) -> [DailyFocus] {
        let today = calendar.startOfDay(for: now)
        return (0..<7).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today),
                  let end = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            let records = focusRecords.filter { $0.endedAt >= day && $0.endedAt < end }
            return DailyFocus(date: day, count: records.count, duration: records.reduce(0) { $0 + $1.duration })
        }
    }
}

nonisolated struct ClockReading: Equatable, Sendable {
    var wall: Date
    var elapsed: TimeInterval
}

nonisolated struct TimerClock: Sendable {
    var now: @Sendable () -> ClockReading
    var sleep: @Sendable (TimeInterval) async throws -> Void

    static var continuous: Self {
        let clock = ContinuousClock()
        let origin = clock.now
        return Self(now: {
            let components = origin.duration(to: clock.now).components
            return ClockReading(wall: Date(), elapsed: Double(components.seconds)
                                + Double(components.attoseconds) / 1e18)
        }, sleep: { seconds in
            try await clock.sleep(for: .seconds(max(0, seconds)))
        })
    }
}

nonisolated struct RunningAnchor: Sendable {
    var sessionID: UUID
    var remaining: TimeInterval
    var elapsed: TimeInterval

    func remaining(at now: ClockReading) -> TimeInterval { remaining - (now.elapsed - elapsed) }
}

nonisolated struct DialGeometry: Sendable {
    var width: Double
    var height: Double
    var ratio: Double

    var center: CGPoint { CGPoint(x: width / 2, y: height / 2) }
    var radius: Double { hypot(width, height) / 2 + 1 }
    var clampedRatio: Double { ratio.isFinite ? min(1, max(0, ratio)) : 0 }
    var elapsedAngle: Double { 2 * .pi * (1 - clampedRatio) }

    func point(at angle: Double) -> CGPoint {
        CGPoint(x: center.x + radius * sin(angle), y: center.y - radius * cos(angle))
    }
}
