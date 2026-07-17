import Foundation
import Observation

/// Pure local-state 25/5 Pomodoro timer. No persistence, no network.
@MainActor
@Observable
final class TimeProdPomodoro {
    enum Phase: String {
        case work = "Focus"
        case shortBreak = "Break"
    }

    static let workDuration: TimeInterval = 25 * 60
    static let breakDuration: TimeInterval = 5 * 60

    private(set) var phase: Phase = .work
    private(set) var remaining: TimeInterval = TimeProdPomodoro.workDuration
    private(set) var isRunning = false

    private var timer: Timer?

    var remainingText: String {
        let total = max(0, Int(remaining.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func pause() {
        isRunning = false
        timer?.invalidate()
        timer = nil
    }

    func reset() {
        pause()
        phase = .work
        remaining = TimeProdPomodoro.workDuration
    }

    private func tick() {
        guard remaining > 0 else {
            advancePhase()
            return
        }
        remaining -= 1
    }

    private func advancePhase() {
        switch phase {
        case .work:
            phase = .shortBreak
            remaining = TimeProdPomodoro.breakDuration
        case .shortBreak:
            phase = .work
            remaining = TimeProdPomodoro.workDuration
        }
    }
}
