import SwiftUI
import Observation

/// Pomodoro glance: a configurable focus/break cycle with a progress ring,
/// long breaks, auto-start, and a session tally.
///
/// Purely local and event-driven — the timer owns its own tick, so this opts out
/// of the shared refresh loop (`refreshInterval` 0, no-op `refresh()`).
@MainActor
@Observable
final class PomodoroPlugin: GlancePlugin {
    nonisolated var id: String { "pomodoro" }
    nonisolated var title: String { "Pomodoro" }
    nonisolated var iconSystemName: String { "timer" }

    let timer = PomodoroTimer()

    func refresh() async {}

    /// Surfaces a running timer with its remaining time. A running focus/break
    /// clock is worth keeping in view; a stopped timer stays quiet.
    func currentSignal() -> GlanceSignal? {
        guard timer.isRunning else {
            // Stopped, but if you've focused today, a quiet tally stays on the feed.
            guard timer.sessionsToday > 0 else { return nil }
            return GlanceSignal(priority: .ambient, score: 0,
                                headline: "\(timer.sessionsToday) focus session\(timer.sessionsToday == 1 ? "" : "s") today",
                                systemImage: iconSystemName, tint: .secondary)
        }
        let tint: Color = timer.phase.isBreak ? .green : .red
        let timer = self.timer
        return GlanceSignal(priority: .elevated, score: 0,
                            headline: "\(timer.phase.title) · \(timer.remainingText)",
                            detail: "Next: \(timer.nextPhase.title)",
                            systemImage: timer.phase.symbol, tint: tint,
                            accessory: .gauge(timer.progress),
                            quickAction: GlanceSignal.QuickAction(
                                title: "Pause", systemImage: "pause.fill",
                                run: { timer.toggle() }))
    }

    func popoverSection() -> AnyView { AnyView(PomodoroPopover(timer: timer)) }
    func settingsSection() -> AnyView { AnyView(PomodoroSettings(timer: timer)) }
}

// MARK: - Popover UI

private struct PomodoroPopover: View {
    @Bindable var timer: PomodoroTimer

    var body: some View {
        VStack(spacing: 12) {
            PomodoroRing(timer: timer)

            HStack(spacing: 8) {
                Button {
                    timer.toggle()
                } label: {
                    Label(timer.isRunning ? "Pause" : "Start",
                          systemImage: timer.isRunning ? "pause.fill" : "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)

                Button {
                    timer.skip()
                } label: {
                    Label("Skip", systemImage: "forward.end.fill")
                }
                .controlSize(.regular)
                .help("Skip to \(timer.nextPhase.title) without counting this session")

                Button {
                    timer.restartPhase()
                } label: {
                    Label("Restart", systemImage: "arrow.counterclockwise")
                }
                .controlSize(.regular)
                .help("Restart the current \(timer.phase.title.lowercased())")
            }
            .labelStyle(.iconOnly)

            PomodoroCycleDots(timer: timer)

            HStack {
                Text("^[\(timer.sessionsToday) session](inflect: true) today")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reset cycle") { timer.reset() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }
}

private struct PomodoroRing: View {
    let timer: PomodoroTimer

    private var tint: Color {
        switch timer.phase {
        case .work: return .red
        case .shortBreak: return .green
        case .longBreak: return .blue
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(0.18), lineWidth: 8)
            Circle()
                .trim(from: 0, to: timer.progress)
                .stroke(tint, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.25), value: timer.progress)

            VStack(spacing: 2) {
                Label(timer.phase.title, systemImage: timer.phase.symbol)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(timer.remainingText)
                    .font(.system(size: 30, weight: .medium).monospacedDigit())
                    .contentTransition(.numericText())
                Text(timer.isRunning ? "Next: \(timer.nextPhase.title)" : "Paused")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: 150, height: 150)
    }
}

/// One dot per focus session in the cycle — filled as sessions complete, so the
/// distance to the next long break is visible at a glance.
private struct PomodoroCycleDots: View {
    let timer: PomodoroTimer

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<timer.cycleLength, id: \.self) { index in
                Image(systemName: index < timer.sessionsInCycle ? "circle.fill" : "circle")
                    .font(.caption2)
                    .foregroundStyle(index < timer.sessionsInCycle ? .red : .secondary)
            }
        }
        .help("\(timer.sessionsInCycle) of \(timer.cycleLength) focus sessions before the long break")
    }
}

// MARK: - Settings UI

private struct PomodoroSettings: View {
    @Bindable var timer: PomodoroTimer

    var body: some View {
        SettingsPage("Durations") {
            Stepper("Focus: ^[\(timer.workMinutes) minute](inflect: true)",
                    value: $timer.workMinutes, in: 1...180)
            Stepper("Short break: ^[\(timer.shortBreakMinutes) minute](inflect: true)",
                    value: $timer.shortBreakMinutes, in: 1...180)
            Stepper("Long break: ^[\(timer.longBreakMinutes) minute](inflect: true)",
                    value: $timer.longBreakMinutes, in: 1...180)
            Stepper("Long break after ^[\(timer.longBreakInterval) session](inflect: true)",
                    value: $timer.longBreakInterval, in: 2...12)
            SettingsHelp("Changing a duration takes effect on the next phase, or right away if the current one hasn't started.")

            Divider()

            SettingsSectionHeader("Behavior")
            SettingsToggleRow("Start breaks automatically", isOn: $timer.autoStartBreaks)
            SettingsToggleRow("Start the next focus session automatically", isOn: $timer.autoStartWork)
            SettingsToggleRow("Play a sound when a phase ends", isOn: $timer.playSound)
        }
    }
}
