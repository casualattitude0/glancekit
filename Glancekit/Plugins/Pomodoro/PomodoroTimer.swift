import Foundation
import Observation
import AppKit

/// The Pomodoro engine: phase machine, configurable durations, cycle counting,
/// and persistence. No network.
///
/// Time is tracked as a *deadline* (`endDate`), not a decrementing counter. A
/// 1 Hz counter drifts, and stops entirely while the Mac is asleep — a timer you
/// start before lunch would be minutes wrong when you come back. The tick only
/// republishes `now`; the remaining time is always derived from the wall clock.
@MainActor
@Observable
final class PomodoroTimer {

    enum Phase: String, CaseIterable {
        case work, shortBreak, longBreak

        var title: String {
            switch self {
            case .work: return "Focus"
            case .shortBreak: return "Short Break"
            case .longBreak: return "Long Break"
            }
        }

        var symbol: String {
            switch self {
            case .work: return "brain.head.profile"
            case .shortBreak: return "cup.and.saucer"
            case .longBreak: return "figure.walk"
            }
        }

        var isBreak: Bool { self != .work }
    }

    // MARK: - Configuration (persisted)

    // These are bound straight to Steppers, which enforce the ranges. Nothing
    // here re-assigns itself inside its own `didSet` to clamp: `@Observable`
    // rewrites stored properties into computed ones, so the usual "assigning in
    // your own didSet doesn't re-enter it" rule does not apply — it recurses
    // until the stack dies. Out-of-range values are pinned where they're read
    // (`duration(for:)`, `cycleLength`) instead, which also sanitizes anything
    // hand-edited into the plist.
    var workMinutes: Int {
        didSet { persistConfig(); syncIdleRemaining() }
    }
    var shortBreakMinutes: Int {
        didSet { persistConfig(); syncIdleRemaining() }
    }
    var longBreakMinutes: Int {
        didSet { persistConfig(); syncIdleRemaining() }
    }
    /// Number of focus sessions between long breaks. Read `cycleLength`.
    var longBreakInterval: Int {
        didSet { persistConfig() }
    }
    var autoStartBreaks: Bool { didSet { persistConfig() } }
    var autoStartWork: Bool { didSet { persistConfig() } }
    var playSound: Bool { didSet { persistConfig() } }

    // MARK: - Live state

    private(set) var phase: Phase = .work
    /// Focus sessions finished in the current cycle — resets after a long break.
    private(set) var sessionsInCycle: Int = 0
    /// Focus sessions finished today, across cycles.
    private(set) var sessionsToday: Int = 0

    /// Republished by the tick so `remaining` recomputes; never read directly.
    private var now: Date = Date()
    private var endDate: Date?
    private var pausedRemaining: TimeInterval = 0
    /// True while the current phase sits untouched at its full duration — the
    /// only time a duration change in Settings may move the clock under the user.
    private var isFresh = true

    private var timer: Timer?

    var isRunning: Bool { endDate != nil }

    var remaining: TimeInterval {
        guard let endDate else { return max(0, pausedRemaining) }
        return max(0, endDate.timeIntervalSince(now))
    }

    var remainingText: String {
        let total = Int(remaining.rounded(.up))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    /// 0…1 through the current phase, for the progress ring.
    var progress: Double {
        let total = duration(for: phase)
        guard total > 0 else { return 0 }
        return min(1, max(0, 1 - remaining / total))
    }

    /// What `skip()`/completion will move to — shown as a hint in the popover.
    var nextPhase: Phase {
        guard phase == .work else { return .work }
        return (sessionsInCycle + 1) % cycleLength == 0 ? .longBreak : .shortBreak
    }

    /// Focus sessions per cycle, pinned to a range a cycle can actually be run
    /// in. Never divide by the raw `longBreakInterval` — a zero would trap.
    var cycleLength: Int { min(max(longBreakInterval, 2), 12) }

    func duration(for phase: Phase) -> TimeInterval {
        switch phase {
        case .work: return Self.clampMinutes(workMinutes)
        case .shortBreak: return Self.clampMinutes(shortBreakMinutes)
        case .longBreak: return Self.clampMinutes(longBreakMinutes)
        }
    }

    /// A phase of zero length would complete the instant it started and spin the
    /// phase machine, so the floor is a real minute.
    private static func clampMinutes(_ minutes: Int) -> TimeInterval {
        TimeInterval(min(max(minutes, 1), 180) * 60)
    }

    // MARK: - Persistence

    private let defaults: UserDefaults

    private enum Keys {
        static let workMinutes = "glancekit.pomodoro.workMinutes"
        static let shortBreakMinutes = "glancekit.pomodoro.shortBreakMinutes"
        static let longBreakMinutes = "glancekit.pomodoro.longBreakMinutes"
        static let longBreakInterval = "glancekit.pomodoro.longBreakInterval"
        static let autoStartBreaks = "glancekit.pomodoro.autoStartBreaks"
        static let autoStartWork = "glancekit.pomodoro.autoStartWork"
        static let playSound = "glancekit.pomodoro.playSound"
        static let phase = "glancekit.pomodoro.phase"
        static let sessionsInCycle = "glancekit.pomodoro.sessionsInCycle"
        static let sessionsToday = "glancekit.pomodoro.sessionsToday"
        static let todayStamp = "glancekit.pomodoro.todayStamp"
        static let endDate = "glancekit.pomodoro.endDate"
        static let pausedRemaining = "glancekit.pomodoro.pausedRemaining"
        static let isFresh = "glancekit.pomodoro.isFresh"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        workMinutes = defaults.object(forKey: Keys.workMinutes) as? Int ?? 25
        shortBreakMinutes = defaults.object(forKey: Keys.shortBreakMinutes) as? Int ?? 5
        longBreakMinutes = defaults.object(forKey: Keys.longBreakMinutes) as? Int ?? 15
        longBreakInterval = defaults.object(forKey: Keys.longBreakInterval) as? Int ?? 4
        autoStartBreaks = defaults.object(forKey: Keys.autoStartBreaks) as? Bool ?? true
        autoStartWork = defaults.object(forKey: Keys.autoStartWork) as? Bool ?? false
        playSound = defaults.object(forKey: Keys.playSound) as? Bool ?? true

        restore()
    }

    /// Rebuild the last session from disk. A running timer whose deadline passed
    /// while the app was closed is credited and advanced — the focus time really
    /// did elapse — but never auto-started, since nobody was watching the phase
    /// it would have run through.
    private func restore() {
        phase = Phase(rawValue: defaults.string(forKey: Keys.phase) ?? "") ?? .work
        sessionsInCycle = defaults.integer(forKey: Keys.sessionsInCycle)
        isFresh = defaults.object(forKey: Keys.isFresh) as? Bool ?? true
        pausedRemaining = defaults.object(forKey: Keys.pausedRemaining) as? Double
            ?? duration(for: phase)

        restoreTodayCount()

        guard let stored = defaults.object(forKey: Keys.endDate) as? Double else { return }
        let deadline = Date(timeIntervalSince1970: stored)
        if deadline > Date() {
            endDate = deadline
            now = Date()
            startTicking()
        } else {
            completePhase(chime: false, allowAutoStart: false)
        }
    }

    private func restoreTodayCount() {
        let stamp = Self.dayStamp(Date())
        if defaults.string(forKey: Keys.todayStamp) == stamp {
            sessionsToday = defaults.integer(forKey: Keys.sessionsToday)
        } else {
            sessionsToday = 0
            defaults.set(stamp, forKey: Keys.todayStamp)
            defaults.set(0, forKey: Keys.sessionsToday)
        }
    }

    private static func dayStamp(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }

    private func persistConfig() {
        defaults.set(workMinutes, forKey: Keys.workMinutes)
        defaults.set(shortBreakMinutes, forKey: Keys.shortBreakMinutes)
        defaults.set(longBreakMinutes, forKey: Keys.longBreakMinutes)
        defaults.set(longBreakInterval, forKey: Keys.longBreakInterval)
        defaults.set(autoStartBreaks, forKey: Keys.autoStartBreaks)
        defaults.set(autoStartWork, forKey: Keys.autoStartWork)
        defaults.set(playSound, forKey: Keys.playSound)
    }

    private func persistState() {
        defaults.set(phase.rawValue, forKey: Keys.phase)
        defaults.set(sessionsInCycle, forKey: Keys.sessionsInCycle)
        defaults.set(sessionsToday, forKey: Keys.sessionsToday)
        defaults.set(Self.dayStamp(Date()), forKey: Keys.todayStamp)
        defaults.set(pausedRemaining, forKey: Keys.pausedRemaining)
        defaults.set(isFresh, forKey: Keys.isFresh)
        if let endDate {
            defaults.set(endDate.timeIntervalSince1970, forKey: Keys.endDate)
        } else {
            defaults.removeObject(forKey: Keys.endDate)
        }
    }

    // MARK: - Controls

    func start() {
        guard !isRunning else { return }
        restoreTodayCount()  // a timer paused overnight starts a fresh tally
        let seconds = pausedRemaining > 0 ? pausedRemaining : duration(for: phase)
        now = Date()
        endDate = now.addingTimeInterval(seconds)
        isFresh = false
        startTicking()
        persistState()
    }

    func pause() {
        guard isRunning else { return }
        pausedRemaining = remaining
        endDate = nil
        stopTicking()
        persistState()
    }

    func toggle() { isRunning ? pause() : start() }

    /// Restart the current phase from its full duration, stopped.
    func restartPhase() {
        stopTicking()
        endDate = nil
        pausedRemaining = duration(for: phase)
        isFresh = true
        persistState()
    }

    /// Abandon the current phase and move to the next one. Skipped focus time is
    /// not credited — only a phase that ran to zero counts as a session.
    func skip() {
        advance(counting: false)
        chimeIfEnabled()
        if shouldAutoStart(phase) { start() }
    }

    /// Back to focus session one with an empty cycle. Today's tally survives —
    /// it's a record of work done, not part of the cycle being reset.
    func reset() {
        stopTicking()
        endDate = nil
        phase = .work
        sessionsInCycle = 0
        pausedRemaining = duration(for: .work)
        isFresh = true
        persistState()
    }

    // MARK: - Phase machine

    private func tick() {
        now = Date()
        guard let endDate, now >= endDate else { return }
        completePhase(chime: true, allowAutoStart: true)
    }

    private func completePhase(chime: Bool, allowAutoStart: Bool) {
        advance(counting: true)
        if chime { chimeIfEnabled() }
        if allowAutoStart, shouldAutoStart(phase) { start() }
    }

    /// Move to the next phase, stopped and at full duration.
    private func advance(counting: Bool) {
        stopTicking()
        endDate = nil

        if phase == .work, counting {
            restoreTodayCount()
            sessionsInCycle += 1
            sessionsToday += 1
        }

        let next: Phase
        if phase == .work {
            next = sessionsInCycle % cycleLength == 0 && sessionsInCycle > 0
                ? .longBreak : .shortBreak
        } else {
            if phase == .longBreak { sessionsInCycle = 0 }
            next = .work
        }

        phase = next
        pausedRemaining = duration(for: next)
        isFresh = true
        persistState()
    }

    private func shouldAutoStart(_ phase: Phase) -> Bool {
        phase.isBreak ? autoStartBreaks : autoStartWork
    }

    // MARK: - Plumbing

    private func startTicking() {
        timer?.invalidate()
        // Sub-second so the ring animates smoothly and the phase flips promptly;
        // the tick only reads the clock, so the extra rate costs nothing.
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func stopTicking() {
        timer?.invalidate()
        timer = nil
    }

    private func syncIdleRemaining() {
        guard isFresh, !isRunning else { return }
        pausedRemaining = duration(for: phase)
        persistState()
    }

    private func chimeIfEnabled() {
        guard playSound else { return }
        if let sound = NSSound(named: phase.isBreak ? "Glass" : "Blow") {
            sound.play()
        } else {
            NSSound.beep()
        }
    }
}
