import SwiftUI
import Observation
import AppKit

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
    /// User-managed named templates (persisted as Codable JSON).
    private(set) var templates: [TimerTemplate] = [] {
        didSet { persist(templates, forKey: Keys.templates) }
    }
    var playSound: Bool {
        didSet { UserDefaults.standard.set(playSound, forKey: Keys.playSound) }
    }
    var showNotification: Bool {
        didSet { UserDefaults.standard.set(showNotification, forKey: Keys.showNotification) }
    }
    /// Name of the finish sound. "Beep" (or an unknown value) falls back to
    /// `NSSound.beep()`; otherwise a named system sound is played.
    var finishSoundName: String {
        didSet { UserDefaults.standard.set(finishSoundName, forKey: Keys.finishSound) }
    }

    /// System sounds offered in Settings (all ship with macOS).
    static let soundChoices = [
        "Beep", "Glass", "Ping", "Pop", "Hero", "Submarine",
        "Funk", "Sosumi", "Tink", "Purr", "Blow", "Bottle", "Frog", "Morse"]

    private enum Keys {
        static let timers = "glancekit.timers.timers"
        static let stopwatch = "glancekit.timers.stopwatch"
        static let presets = "glancekit.timers.presets"
        static let templates = "glancekit.timers.templates"
        static let playSound = "glancekit.timers.playSound"
        static let showNotification = "glancekit.timers.showNotification"
        static let finishSound = "glancekit.timers.finishSound"
    }

    init() {
        // Read prefs first (didSet on the Codable state below must not clobber).
        presets = (UserDefaults.standard.array(forKey: Keys.presets) as? [Int]).flatMap {
            $0.isEmpty ? nil : $0
        } ?? [1, 3, 5, 10, 25]
        playSound = (UserDefaults.standard.object(forKey: Keys.playSound) as? Bool) ?? true
        showNotification = (UserDefaults.standard.object(forKey: Keys.showNotification) as? Bool) ?? true
        finishSoundName = (UserDefaults.standard.string(forKey: Keys.finishSound)) ?? "Beep"
        templates = Self.load([TimerTemplate].self, forKey: Keys.templates) ?? []

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
                let item = timers[i]
                if item.repeats && item.total > 0 {
                    // Loop: alert, then immediately re-arm from the full duration.
                    // Stays `.running`, so refreshInterval keeps returning 1.
                    timers[i].fireDate = now.addingTimeInterval(item.total)
                    timers[i].remainingWhenPaused = item.total
                } else {
                    timers[i].state = .finished
                    timers[i].fireDate = nil
                    timers[i].remainingWhenPaused = 0
                }
                changed = true
                fireAlert(for: item)
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
        guard seconds > 0 else { return }
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

    /// Remove every finished timer at once.
    func clearFinished() {
        timers.removeAll { $0.state == .finished }
    }

    /// Reorder the active timer list (drag / move up / move down).
    func move(from source: IndexSet, to destination: Int) {
        timers.move(fromOffsets: source, toOffset: destination)
    }

    /// Move a single timer one slot up/down (button-driven reorder).
    func moveTimer(_ id: UUID, up: Bool) {
        guard let i = timers.firstIndex(where: { $0.id == id }) else { return }
        let j = up ? i - 1 : i + 1
        guard timers.indices.contains(j) else { return }
        timers.swapAt(i, j)
    }

    /// Rename a timer inline. Trimmed; an empty name reverts to the "Timer"
    /// placeholder via `displayLabel`.
    func rename(_ id: UUID, to newName: String) {
        guard let i = timers.firstIndex(where: { $0.id == id }) else { return }
        timers[i].label = newName.trimmingCharacters(in: .whitespaces)
    }

    /// Toggle the per-timer auto-restart flag.
    func toggleRepeat(_ id: UUID) {
        guard let i = timers.firstIndex(where: { $0.id == id }) else { return }
        timers[i].repeats.toggle()
    }

    /// Duplicate a timer as a fresh running copy (works for any state).
    func duplicate(_ id: UUID) {
        guard let src = timers.first(where: { $0.id == id }) else { return }
        guard src.total > 0 else { return }
        let now = Date()
        timers.append(TimerItem(
            id: UUID(), label: src.label, total: src.total,
            fireDate: now.addingTimeInterval(src.total),
            remainingWhenPaused: src.total, state: .running,
            repeats: src.repeats))
    }

    /// Restart a (typically finished) timer in place from its full duration.
    func restart(_ id: UUID) {
        guard let i = timers.firstIndex(where: { $0.id == id }) else { return }
        let total = timers[i].total
        guard total > 0 else { return }
        timers[i].fireDate = Date().addingTimeInterval(total)
        timers[i].remainingWhenPaused = total
        timers[i].state = .running
    }

    /// Edit the remaining time of a running or paused timer. Grows `total` if
    /// needed so the progress bar stays in range.
    func setRemaining(_ id: UUID, seconds: TimeInterval) {
        guard let i = timers.firstIndex(where: { $0.id == id }) else { return }
        let secs = max(0, seconds)
        guard secs > 0 else { return }
        timers[i].total = max(timers[i].total, secs)
        switch timers[i].state {
        case .running:
            timers[i].fireDate = Date().addingTimeInterval(secs)
            timers[i].remainingWhenPaused = secs
        case .paused:
            timers[i].remainingWhenPaused = secs
        case .finished:
            // Editing a finished timer's time revives it as paused.
            timers[i].remainingWhenPaused = secs
            timers[i].fireDate = nil
            timers[i].state = .paused
        }
    }

    // MARK: Template commands

    func addTemplate(name: String, minutes: Int, seconds: Int) {
        let total = TimeInterval(max(0, minutes) * 60 + max(0, seconds))
        guard total > 0 else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        templates.append(TimerTemplate(
            name: trimmed.isEmpty ? Self.mmss(total) : trimmed, seconds: total))
    }

    func deleteTemplate(_ id: UUID) {
        templates.removeAll { $0.id == id }
    }

    func moveTemplate(from source: IndexSet, to destination: Int) {
        templates.move(fromOffsets: source, toOffset: destination)
    }

    func moveTemplate(_ id: UUID, up: Bool) {
        guard let i = templates.firstIndex(where: { $0.id == id }) else { return }
        let j = up ? i - 1 : i + 1
        guard templates.indices.contains(j) else { return }
        templates.swapAt(i, j)
    }

    /// Launch a running timer from a saved template.
    func launchTemplate(_ template: TimerTemplate) {
        add(label: template.name, seconds: template.seconds)
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
        if playSound { playFinishSound() }
        guard showNotification else { return }
        // `sound: false` — the finish sound above is the user's own choice, and
        // the service beep on top would be two noises for one timer.
        // A fresh identifier each time: a repeating timer posting a stable id
        // would rewrite its own row instead of announcing the next loop.
        NotificationService.post(
            title: item.repeats ? "Timer looped" : "Timer done",
            body: displayLabel(item),
            tint: .blue,
            identifier: "\(item.id)-\(UUID().uuidString.prefix(8))",
            source: "timers",
            sound: false)
    }

    /// Play the selected finish sound, falling back to the system beep when the
    /// choice is "Beep" or a named sound can't be loaded.
    func playFinishSound() {
        if finishSoundName == "Beep" {
            NSSound.beep()
        } else if let sound = NSSound(named: NSSound.Name(finishSoundName)) {
            sound.stop()
            sound.play()
        } else {
            NSSound.beep()
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
    /// Auto-restart from `total` when it finishes.
    var repeats: Bool = false
}

// Backward-compatible decode: timers persisted before `repeats` existed lack
// that key. Custom `init(from:)` defaults it to false so the whole array still
// restores instead of failing to decode (which would silently drop all timers).
extension TimerItem {
    private enum CodingKeys: String, CodingKey {
        case id, label, total, fireDate, remainingWhenPaused, state, repeats
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        total = try c.decode(TimeInterval.self, forKey: .total)
        fireDate = try c.decodeIfPresent(Date.self, forKey: .fireDate)
        remainingWhenPaused = try c.decode(TimeInterval.self, forKey: .remainingWhenPaused)
        state = try c.decode(RunState.self, forKey: .state)
        repeats = try c.decodeIfPresent(Bool.self, forKey: .repeats) ?? false
    }
}

/// A user-managed named preset (e.g. "Tea 4:00") that launches a timer on tap.
struct TimerTemplate: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    /// Duration in seconds.
    var seconds: TimeInterval

    init(id: UUID = UUID(), name: String, seconds: TimeInterval) {
        self.id = id
        self.name = name
        self.seconds = seconds
    }
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

    private var finishedCount: Int {
        plugin.timers.filter { $0.state == .finished }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            presetRow
            if !plugin.templates.isEmpty { templateRow }
            customRow

            Divider()

            if plugin.timers.isEmpty {
                emptyState
            } else {
                if finishedCount > 1 {
                    HStack {
                        Spacer()
                        Button {
                            plugin.clearFinished()
                        } label: {
                            Label("Clear \(finishedCount) finished", systemImage: "xmark.circle")
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                VStack(spacing: 6) {
                    ForEach(plugin.timers) { item in
                        TimersRow(
                            plugin: plugin, item: item,
                            canMoveUp: plugin.timers.first?.id != item.id,
                            canMoveDown: plugin.timers.last?.id != item.id)
                    }
                }
            }

            Divider()

            TimersStopwatchView(plugin: plugin)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No timers running")
                .font(.callout.weight(.medium))
            Text(plugin.templates.isEmpty
                 ? "Tap a preset above or add a custom timer to start."
                 : "Tap a preset, a saved template, or add a custom timer.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
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

    private var templateRow: some View {
        // Saved named templates — tap to launch. Managed in Settings.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(plugin.templates) { template in
                    Button {
                        plugin.launchTemplate(template)
                    } label: {
                        Text("\(template.name) · \(TimersPlugin.mmss(template.seconds))")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Start “\(template.name)”")
                }
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
    let canMoveUp: Bool
    let canMoveDown: Bool

    @State private var now = Date()
    @State private var isRenaming = false
    @State private var draftName = ""
    @State private var isEditingTime = false
    @State private var editMinutes = ""
    @State private var editSeconds = ""
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var remaining: TimeInterval { plugin.remaining(item, at: now) }
    private var isFinished: Bool { item.state == .finished }
    private var fraction: Double {
        guard item.total > 0 else { return isFinished ? 1 : 0 }
        return min(1, max(0, (item.total - remaining) / item.total))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header

            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .tint(isFinished ? .red : (remaining < 60 && item.state == .running ? .orange : .accentColor))
                .scaleEffect(x: 1, y: 0.6, anchor: .center)

            if isEditingTime { editTimeRow }
            controls
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isFinished ? Color.red.opacity(0.12) : Color.secondary.opacity(0.06)))
        .onReceive(ticker) { now = $0 }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                if isRenaming {
                    TextField("Name", text: $draftName)
                        .textFieldStyle(.roundedBorder)
                        .font(.body)
                        .frame(maxWidth: 160)
                        .onSubmit { commitRename() }
                } else {
                    HStack(spacing: 4) {
                        Text(plugin.displayLabel(item))
                            .font(.body.weight(.medium))
                        if item.repeats {
                            Image(systemName: "repeat")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .help("Repeats on finish")
                        }
                    }
                }
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
    }

    private var editTimeRow: some View {
        HStack(spacing: 6) {
            TextField("min", text: $editMinutes)
                .textFieldStyle(.roundedBorder)
                .frame(width: 44)
                .multilineTextAlignment(.trailing)
            Text(":").foregroundStyle(.secondary)
            TextField("sec", text: $editSeconds)
                .textFieldStyle(.roundedBorder)
                .frame(width: 44)
                .multilineTextAlignment(.trailing)
            Button("Set") { commitEditTime() }
                .controlSize(.small)
            Button("Cancel") { isEditingTime = false }
                .controlSize(.small)
            Spacer()
        }
        .font(.caption)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            if isFinished {
                Button {
                    plugin.restart(item.id)
                } label: {
                    Label("Restart", systemImage: "arrow.clockwise")
                }
                .help("Restart from full duration")

                Button {
                    plugin.delete(item.id)
                } label: {
                    Label("Dismiss", systemImage: "xmark.circle.fill")
                }

                Spacer()
                moreMenu
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

                moreMenu

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

    private var moreMenu: some View {
        Menu {
            Button {
                draftName = item.label
                isRenaming = true
            } label: { Label("Rename", systemImage: "pencil") }

            Button {
                plugin.toggleRepeat(item.id)
            } label: {
                Label(item.repeats ? "Stop repeating" : "Repeat on finish",
                      systemImage: "repeat")
            }

            Button {
                plugin.duplicate(item.id)
            } label: { Label("Duplicate", systemImage: "plus.square.on.square") }

            if !isFinished {
                Button {
                    let r = Int(remaining.rounded())
                    editMinutes = String(r / 60)
                    editSeconds = String(r % 60)
                    isEditingTime = true
                } label: { Label("Edit time…", systemImage: "clock.arrow.circlepath") }
            }

            Divider()

            Button {
                plugin.moveTimer(item.id, up: true)
            } label: { Label("Move up", systemImage: "arrow.up") }
                .disabled(!canMoveUp)

            Button {
                plugin.moveTimer(item.id, up: false)
            } label: { Label("Move down", systemImage: "arrow.down") }
                .disabled(!canMoveDown)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("More actions")
    }

    private func commitRename() {
        plugin.rename(item.id, to: draftName)
        isRenaming = false
    }

    private func commitEditTime() {
        let secs = TimeInterval((Int(editMinutes) ?? 0) * 60 + (Int(editSeconds) ?? 0))
        plugin.setRemaining(item.id, seconds: secs)
        isEditingTime = false
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

    // New-template draft fields.
    @State private var newTemplateName = ""
    @State private var newTemplateMinutes = ""
    @State private var newTemplateSeconds = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Alerts").font(.headline)
            Toggle("Play sound on finish", isOn: $plugin.playSound)
            HStack {
                Picker("Finish sound", selection: $plugin.finishSoundName) {
                    ForEach(TimersPlugin.soundChoices, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .frame(maxWidth: 220)
                .disabled(!plugin.playSound)
                Button("Preview") { plugin.playFinishSound() }
                    .disabled(!plugin.playSound)
            }
            // Whether a finished timer notifies at all; how it notifies (panel,
            // system record, corner, dwell) lives in Settings ▸ Notifications.
            Toggle("Notify when a timer finishes", isOn: $plugin.showNotification)
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

            Divider()

            templatesSection
        }
        .onAppear {
            presetsText = plugin.presets.map(String.init).joined(separator: ", ")
        }
    }

    private var templatesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Saved templates").font(.headline)
            Text("Named presets (e.g. “Tea 4:00”). Tap one in the popover to start it.")
                .font(.caption).foregroundStyle(.secondary)

            if plugin.templates.isEmpty {
                Text("No templates yet.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(plugin.templates) { template in
                    HStack(spacing: 8) {
                        Text(template.name)
                        Spacer()
                        Text(TimersPlugin.mmss(template.seconds))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Button {
                            plugin.moveTemplate(template.id, up: true)
                        } label: { Image(systemName: "arrow.up") }
                            .buttonStyle(.borderless)
                            .disabled(plugin.templates.first?.id == template.id)
                        Button {
                            plugin.moveTemplate(template.id, up: false)
                        } label: { Image(systemName: "arrow.down") }
                            .buttonStyle(.borderless)
                            .disabled(plugin.templates.last?.id == template.id)
                        Button {
                            plugin.deleteTemplate(template.id)
                        } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .help("Delete template")
                    }
                    .font(.callout)
                }
            }

            HStack(spacing: 6) {
                TextField("Name", text: $newTemplateName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
                TextField("min", text: $newTemplateMinutes)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 44)
                    .multilineTextAlignment(.trailing)
                Text(":").foregroundStyle(.secondary)
                TextField("sec", text: $newTemplateSeconds)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 44)
                    .multilineTextAlignment(.trailing)
                Button("Add") {
                    plugin.addTemplate(
                        name: newTemplateName,
                        minutes: Int(newTemplateMinutes) ?? 0,
                        seconds: Int(newTemplateSeconds) ?? 0)
                    newTemplateName = ""; newTemplateMinutes = ""; newTemplateSeconds = ""
                }
            }
        }
    }
}
