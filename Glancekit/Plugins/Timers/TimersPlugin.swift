import SwiftUI
import Observation
import AppKit
import UserNotifications

/// Timers glance: multiple concurrent countdown timers plus a stopwatch.
///
/// Distinct from Pomodoro (fixed focus/break cycles) and Time & Productivity
/// (a single target-date countdown). Here the user can run several independent
/// countdowns at once, each with its own label and duration, alongside one
/// free-running stopwatch.
///
/// - State (timers + stopwatch + prefs) is persisted to `UserDefaults` as
///   Codable JSON under `glancekit.timers.*`, storing each timer's `fireDate`
///   so running countdowns survive an app relaunch.
/// - Completion is detected inside `refresh()` (comparing `fireDate` to now) so
///   a timer fires its alert even while the popover is closed. `refreshInterval`
///   is dynamic (1s while anything runs, 0 when idle), mirroring Stocks.
@MainActor
@Observable
final class TimersPlugin: GlancePlugin {
    nonisolated var id: String { "timers" }
    nonisolated var title: String { "Timers" }
    nonisolated var iconSystemName: String { "timer" }

    /// Tick every second while something is counting so completion is caught
    /// promptly and the Smart Panel signal stays live; opt out of the loop when
    /// fully idle. (Dynamic, like Stocks.)
    var refreshInterval: TimeInterval {
        let active = stopwatch.isRunning || timers.contains { $0.state == .running }
        return active ? 1 : 0
    }

    // MARK: Persisted state

    private(set) var timers: [TimerItem] = [] {
        didSet { persist(timers, forKey: Keys.timers) }
    }
    private(set) var stopwatch = StopwatchState() {
        didSet { persist(stopwatch, forKey: Keys.stopwatch) }
    }

    /// Quick-add preset minutes shown as buttons.
    var presets: [Int] {
        didSet { UserDefaults.standard.set(presets, forKey: Keys.presets) }
    }
    var playSound: Bool {
        didSet { UserDefaults.standard.set(playSound, forKey: Keys.playSound) }
    }
    var showNotification: Bool {
        didSet { UserDefaults.standard.set(showNotification, forKey: Keys.showNotification) }
    }

    private enum Keys {
        static let timers = "glancekit.timers.timers"
        static let stopwatch = "glancekit.timers.stopwatch"
        static let presets = "glancekit.timers.presets"
        static let playSound = "glancekit.timers.playSound"
        static let showNotification = "glancekit.timers.showNotification"
    }

    init() {
        // Read prefs first (didSet on the Codable state below must not clobber).
        presets = (UserDefaults.standard.array(forKey: Keys.presets) as? [Int]).flatMap {
            $0.isEmpty ? nil : $0
        } ?? [1, 3, 5, 10, 25]
        playSound = (UserDefaults.standard.object(forKey: Keys.playSound) as? Bool) ?? true
        showNotification = (UserDefaults.standard.object(forKey: Keys.showNotification) as? Bool) ?? true

        var restored = Self.load([TimerItem].self, forKey: Keys.timers) ?? []
        let now = Date()
        // Recompute paused-remaining from fireDate; mark timers that expired
        // while the app was closed as finished (no alert — the moment passed).
        for i in restored.indices where restored[i].state == .running {
            if let fd = restored[i].fireDate, fd <= now {
                restored[i].state = .finished
                restored[i].fireDate = nil
                restored[i].remainingWhenPaused = 0
            }
        }
        timers = restored
        stopwatch = Self.load(StopwatchState.self, forKey: Keys.stopwatch) ?? StopwatchState()
    }

    // MARK: GlancePlugin

    func refresh() async {
        let now = Date()
        var changed = false
        for i in timers.indices where timers[i].state == .running {
            if let fd = timers[i].fireDate, fd <= now {
                timers[i].state = .finished
                timers[i].fireDate = nil
                timers[i].remainingWhenPaused = 0
                changed = true
                fireAlert(for: timers[i])
            }
        }
        // Mutating array elements already triggered didSet; `changed` documents intent.
        _ = changed
    }

    func currentSignal() -> GlanceSignal? {
        let now = Date()

        // A finished, undismissed timer is the loudest thing we can say.
        if let done = timers.first(where: { $0.state == .finished }) {
            return GlanceSignal(
                priority: .urgent, score: 100,
                headline: "\(displayLabel(done)) done",
                detail: "Tap the glance to dismiss",
                systemImage: "bell.badge.fill", tint: .red)
        }

        // Otherwise, the soonest-finishing running timer.
        let running = timers.filter { $0.state == .running && $0.fireDate != nil }
        if let soonest = running.min(by: { $0.fireDate! < $1.fireDate! }) {
            let remaining = max(0, soonest.fireDate!.timeIntervalSince(now))
            let elapsedFraction = soonest.total > 0
                ? min(1, max(0, (soonest.total - remaining) / soonest.total)) : 0
            let urgent = remaining < 60
            let targetID = soonest.id
            return GlanceSignal(
                priority: urgent ? .elevated : .normal,
                score: 1_000_000 - remaining, // sooner finish sorts first
                headline: "\(displayLabel(soonest)) · \(Self.mmss(remaining)) left",
                systemImage: iconSystemName,
                tint: urgent ? .orange : nil,
                accessory: .gauge(elapsedFraction),
                quickAction: GlanceSignal.QuickAction(
                    title: "+1 min", systemImage: "plus",
                    run: { [weak self] in self?.addMinute(targetID) }))
        }

        // Nothing counting down — surface the stopwatch if it's running.
        if stopwatch.isRunning {
            return GlanceSignal(
                priority: .normal, score: 0,
                headline: "Stopwatch · \(Self.hmmss(stopwatchElapsed(at: now)))",
                systemImage: "stopwatch")
        }
        return nil
    }

    func popoverSection() -> AnyView { AnyView(TimersPopover(plugin: self)) }
    func settingsSection() -> AnyView { AnyView(TimersSettings(plugin: self)) }

    // MARK: Timer commands

    func addPreset(minutes: Int) {
        add(label: "", seconds: TimeInterval(max(1, minutes) * 60))
    }

    func addCustom(minutes: Int, seconds: Int, label: String) {
        let total = TimeInterval(max(0, minutes) * 60 + max(0, seconds))
        guard total > 0 else { return }
        add(label: label.trimmingCharacters(in: .whitespaces), seconds: total)
    }

    private func add(label: String, seconds: TimeInterval) {
        let now = Date()
        timers.append(TimerItem(
            id: UUID(), label: label, total: seconds,
            fireDate: now.addingTimeInterval(seconds),
            remainingWhenPaused: seconds, state: .running))
    }

    func togglePause(_ id: UUID) {
        guard let i = timers.firstIndex(where: { $0.id == id }) else { return }
        let now = Date()
        switch timers[i].state {
        case .running:
            let remaining = timers[i].fireDate.map { max(0, $0.timeIntervalSince(now)) } ?? 0
            timers[i].remainingWhenPaused = remaining
            timers[i].fireDate = nil
            timers[i].state = .paused
        case .paused:
            timers[i].fireDate = now.addingTimeInterval(timers[i].remainingWhenPaused)
            timers[i].state = .running
        case .finished:
            break
        }
    }

    func addMinute(_ id: UUID) {
        guard let i = timers.firstIndex(where: { $0.id == id }) else { return }
        let now = Date()
        timers[i].total += 60
        switch timers[i].state {
        case .running:
            let base = timers[i].fireDate ?? now
            timers[i].fireDate = base.addingTimeInterval(60)
        case .paused:
            timers[i].remainingWhenPaused += 60
        case .finished:
            // Revive a finished timer with a fresh minute.
            timers[i].total = 60
            timers[i].remainingWhenPaused = 60
            timers[i].fireDate = now.addingTimeInterval(60)
            timers[i].state = .running
        }
    }

    func reset(_ id: UUID) {
        guard let i = timers.firstIndex(where: { $0.id == id }) else { return }
        let total = timers[i].total
        timers[i].remainingWhenPaused = total
        if timers[i].state == .running {
            timers[i].fireDate = Date().addingTimeInterval(total)
        } else {
            timers[i].fireDate = nil
            timers[i].state = .paused
        }
    }

    func delete(_ id: UUID) {
        timers.removeAll { $0.id == id }
    }

    /// Live remaining seconds for display (source of truth = the model).
    func remaining(_ item: TimerItem, at now: Date = Date()) -> TimeInterval {
        switch item.state {
        case .running: return item.fireDate.map { max(0, $0.timeIntervalSince(now)) } ?? 0
        case .paused: return max(0, item.remainingWhenPaused)
        case .finished: return 0
        }
    }

    // MARK: Stopwatch commands

    func stopwatchToggle() {
        let now = Date()
        if stopwatch.isRunning {
            stopwatch.accumulated = stopwatchElapsed(at: now)
            stopwatch.startDate = nil
            stopwatch.isRunning = false
        } else {
            stopwatch.startDate = now
            stopwatch.isRunning = true
        }
    }

    func stopwatchReset() {
        stopwatch = StopwatchState()
    }

    func stopwatchElapsed(at now: Date = Date()) -> TimeInterval {
        if stopwatch.isRunning, let start = stopwatch.startDate {
            return stopwatch.accumulated + max(0, now.timeIntervalSince(start))
        }
        return stopwatch.accumulated
    }

    // MARK: Alerts

    private func fireAlert(for item: TimerItem) {
        if playSound { NSSound.beep() }
        guard showNotification else { return }
        postNotification(
            title: "Timer done",
            body: displayLabel(item))
    }

    /// Best-effort user notification. Requests authorization lazily the first
    /// time; if the app can't post (no bundle id, denied, unavailable) it
    /// silently falls back to just the beep — never crashes.
    private func postNotification(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: UUID().uuidString, content: content, trigger: nil)
            center.add(request, withCompletionHandler: nil)
        }
    }

    // MARK: Helpers

    func displayLabel(_ item: TimerItem) -> String {
        item.label.isEmpty ? "Timer" : item.label
    }

    private func persist<T: Encodable>(_ value: T, forKey key: String) {
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private static func load<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func mmss(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    static func hmmss(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}

// MARK: - Model

struct TimerItem: Codable, Identifiable, Equatable {
    enum RunState: String, Codable { case running, paused, finished }

    let id: UUID
    var label: String
    /// Full duration in seconds (grows with +1 min).
    var total: TimeInterval
    /// When it will finish; nil while paused or finished.
    var fireDate: Date?
    /// Seconds left, captured on pause (also the resume basis).
    var remainingWhenPaused: TimeInterval
    var state: RunState
}

struct StopwatchState: Codable, Equatable {
    var startDate: Date?
    var accumulated: TimeInterval = 0
    var isRunning: Bool = false
}

// MARK: - Popover UI

private struct TimersPopover: View {
    @Bindable var plugin: TimersPlugin

    @State private var customMinutes: String = ""
    @State private var customSeconds: String = ""
    @State private var customLabel: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            presetRow
            customRow

            Divider()

            if plugin.timers.isEmpty {
                Text("No timers yet — add one above.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 6) {
                    ForEach(plugin.timers) { item in
                        TimersRow(plugin: plugin, item: item)
                    }
                }
            }

            Divider()

            TimersStopwatchView(plugin: plugin)
        }
    }

    private var presetRow: some View {
        HStack(spacing: 6) {
            ForEach(plugin.presets, id: \.self) { minutes in
                Button("\(minutes)m") { plugin.addPreset(minutes: minutes) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    private var customRow: some View {
        HStack(spacing: 6) {
            TextField("Label", text: $customLabel)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity)
            TextField("min", text: $customMinutes)
                .textFieldStyle(.roundedBorder)
                .frame(width: 44)
                .multilineTextAlignment(.trailing)
            Text(":").foregroundStyle(.secondary)
            TextField("sec", text: $customSeconds)
                .textFieldStyle(.roundedBorder)
                .frame(width: 44)
                .multilineTextAlignment(.trailing)
            Button {
                plugin.addCustom(
                    minutes: Int(customMinutes) ?? 0,
                    seconds: Int(customSeconds) ?? 0,
                    label: customLabel)
                customMinutes = ""; customSeconds = ""; customLabel = ""
            } label: {
                Image(systemName: "plus.circle.fill")
            }
            .buttonStyle(.borderless)
            .help("Add a custom timer")
        }
    }
}

/// One timer row. A local `Timer.publish` (as in `Countdown.swift`) drives the
/// live readout; the model remains the source of truth for `remaining`.
private struct TimersRow: View {
    let plugin: TimersPlugin
    let item: TimerItem

    @State private var now = Date()
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var remaining: TimeInterval { plugin.remaining(item, at: now) }
    private var isFinished: Bool { item.state == .finished }
    private var fraction: Double {
        guard item.total > 0 else { return isFinished ? 1 : 0 }
        return min(1, max(0, (item.total - remaining) / item.total))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(plugin.displayLabel(item))
                        .font(.body.weight(.medium))
                    if isFinished {
                        Text("Done").font(.caption2).foregroundStyle(.red)
                    } else if item.state == .paused {
                        Text("Paused").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(isFinished ? "Done" : TimersPlugin.mmss(remaining))
                    .font(.title3.monospacedDigit())
                    .foregroundStyle(isFinished ? .red : (remaining < 60 && item.state == .running ? .orange : .primary))
            }

            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .tint(isFinished ? .red : (remaining < 60 && item.state == .running ? .orange : .accentColor))
                .scaleEffect(x: 1, y: 0.6, anchor: .center)

            controls
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isFinished ? Color.red.opacity(0.12) : Color.secondary.opacity(0.06)))
        .onReceive(ticker) { now = $0 }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            if isFinished {
                Button {
                    plugin.delete(item.id)
                } label: {
                    Label("Dismiss", systemImage: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .font(.caption)
            } else {
                Button {
                    plugin.togglePause(item.id)
                } label: {
                    Image(systemName: item.state == .running ? "pause.fill" : "play.fill")
                }
                .help(item.state == .running ? "Pause" : "Resume")

                Button { plugin.addMinute(item.id) } label: {
                    Image(systemName: "plus")
                }
                .help("Add one minute")

                Button { plugin.reset(item.id) } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .help("Reset to full duration")

                Spacer()

                Button { plugin.delete(item.id) } label: {
                    Image(systemName: "trash")
                }
                .help("Delete timer")
            }
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

private struct TimersStopwatchView: View {
    let plugin: TimersPlugin

    @State private var now = Date()
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack {
            Label("Stopwatch", systemImage: "stopwatch")
                .font(.body)
            Spacer()
            Text(TimersPlugin.hmmss(plugin.stopwatchElapsed(at: now)))
                .font(.title3.monospacedDigit())

            Button {
                plugin.stopwatchToggle()
            } label: {
                Image(systemName: plugin.stopwatch.isRunning ? "pause.fill" : "play.fill")
            }
            .help(plugin.stopwatch.isRunning ? "Pause" : "Start")

            Button {
                plugin.stopwatchReset()
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .help("Reset")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .onReceive(ticker) { now = $0 }
    }
}

// MARK: - Settings UI

private struct TimersSettings: View {
    @Bindable var plugin: TimersPlugin
    @State private var presetsText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Alerts").font(.headline)
            Toggle("Play sound on finish", isOn: $plugin.playSound)
            Toggle("Show system notification", isOn: $plugin.showNotification)
            Text("Notifications require Glancekit to be allowed under System Settings › Notifications. If denied, the finish sound still plays.")
                .font(.caption).foregroundStyle(.secondary)

            Divider()

            Text("Quick-add presets").font(.headline)
            Text("Comma-separated minutes shown as buttons in the popover.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("1, 3, 5, 10, 25", text: $presetsText)
                    .textFieldStyle(.roundedBorder)
                Button("Save") {
                    let parsed = presetsText
                        .split(separator: ",")
                        .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                        .filter { $0 > 0 }
                    if !parsed.isEmpty { plugin.presets = parsed }
                    presetsText = plugin.presets.map(String.init).joined(separator: ", ")
                }
            }
        }
        .onAppear {
            presetsText = plugin.presets.map(String.init).joined(separator: ", ")
        }
    }
}
