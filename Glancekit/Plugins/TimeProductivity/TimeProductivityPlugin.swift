import SwiftUI
import Observation
import EventKit
import AppKit

/// Multi-feature productivity glance: world clocks, next calendar event,
/// reminders, a Pomodoro timer, and a countdown to a target date.
///
/// All EventKit access is best-effort: denied/undetermined authorization
/// never crashes `refresh()`, it just surfaces a "grant access" message in
/// the popover (see `PLUGIN_CONTRACT.md` rule 4).
@MainActor
@Observable
final class TimeProductivityPlugin: GlancePlugin {
    nonisolated var id: String { "timeprod" }
    nonisolated var title: String { "Time & Productivity" }
    nonisolated var iconSystemName: String { "clock" }
    var refreshInterval: TimeInterval { 60 }

    // MARK: Feature toggles (persisted)

    var worldClocksEnabled: Bool {
        didSet { UserDefaults.standard.set(worldClocksEnabled, forKey: Keys.worldClocksEnabled) }
    }
    var calendarEnabled: Bool {
        didSet { UserDefaults.standard.set(calendarEnabled, forKey: Keys.calendarEnabled) }
    }
    var remindersEnabled: Bool {
        didSet { UserDefaults.standard.set(remindersEnabled, forKey: Keys.remindersEnabled) }
    }
    var pomodoroEnabled: Bool {
        didSet { UserDefaults.standard.set(pomodoroEnabled, forKey: Keys.pomodoroEnabled) }
    }
    var countdownEnabled: Bool {
        didSet { UserDefaults.standard.set(countdownEnabled, forKey: Keys.countdownEnabled) }
    }
    var meetingJoinEnabled: Bool {
        didSet { UserDefaults.standard.set(meetingJoinEnabled, forKey: Keys.meetingJoinEnabled) }
    }

    // MARK: Persisted configuration

    var zones: [String] {
        didSet { UserDefaults.standard.set(zones, forKey: Keys.zones) }
    }
    var countdownDate: Date {
        didSet { UserDefaults.standard.set(countdownDate.timeIntervalSince1970, forKey: Keys.countdownDate) }
    }
    var countdownLabel: String {
        didSet { UserDefaults.standard.set(countdownLabel, forKey: Keys.countdownLabel) }
    }

    // MARK: Live state

    let pomodoro = TimeProdPomodoro()
    private(set) var nextEvent: TimeProdEvent?
    private(set) var reminders: [TimeProdReminder] = []
    private(set) var lastError: String?

    private let feed = TimeProdEventKitFeed()

    private enum Keys {
        static let worldClocksEnabled = "glancekit.timeprod.worldClocks"
        static let calendarEnabled = "glancekit.timeprod.calendar"
        static let remindersEnabled = "glancekit.timeprod.reminders"
        static let pomodoroEnabled = "glancekit.timeprod.pomodoro"
        static let countdownEnabled = "glancekit.timeprod.countdown"
        static let meetingJoinEnabled = "glancekit.timeprod.meetingJoin"
        static let zones = "glancekit.timeprod.zones"
        static let countdownDate = "glancekit.timeprod.countdownDate"
        static let countdownLabel = "glancekit.timeprod.countdownLabel"
    }

    init() {
        let defaults = UserDefaults.standard
        worldClocksEnabled = defaults.object(forKey: Keys.worldClocksEnabled) as? Bool ?? true
        calendarEnabled = defaults.object(forKey: Keys.calendarEnabled) as? Bool ?? true
        remindersEnabled = defaults.object(forKey: Keys.remindersEnabled) as? Bool ?? true
        pomodoroEnabled = defaults.object(forKey: Keys.pomodoroEnabled) as? Bool ?? true
        countdownEnabled = defaults.object(forKey: Keys.countdownEnabled) as? Bool ?? true
        meetingJoinEnabled = defaults.object(forKey: Keys.meetingJoinEnabled) as? Bool ?? true

        zones = defaults.stringArray(forKey: Keys.zones)
            ?? ["America/New_York", "Europe/London", "Asia/Tokyo"]

        let storedInterval = defaults.object(forKey: Keys.countdownDate) as? Double
        countdownDate = storedInterval.map { Date(timeIntervalSince1970: $0) }
            ?? Calendar.current.date(byAdding: .day, value: 30, to: Date())
            ?? Date()
        countdownLabel = defaults.string(forKey: Keys.countdownLabel) ?? "Deadline"
    }

    // MARK: GlancePlugin

    var menuBarSummary: String? {
        if calendarEnabled, feed.calendarAuthState == .authorized, let event = nextEvent {
            return "\(event.title) \(Self.relativeShort(event.startDate))"
        }
        if pomodoroEnabled, pomodoro.isRunning {
            return "\(pomodoro.phase.rawValue) \(pomodoro.remainingText)"
        }
        return nil
    }

    func refresh() async {
        lastError = nil

        if calendarEnabled {
            if feed.calendarAuthState == .authorized {
                nextEvent = feed.loadNextEvent()
            } else {
                nextEvent = nil
            }
        }

        if remindersEnabled {
            if feed.remindersAuthState == .authorized {
                reminders = await feed.loadReminders()
            } else {
                reminders = []
            }
        }
    }

    func requestCalendarAccess() async {
        _ = await feed.requestCalendarAccess()
        await refresh()
    }

    func requestRemindersAccess() async {
        _ = await feed.requestRemindersAccess()
        await refresh()
    }

    var calendarAuthorized: Bool { feed.calendarAuthState == .authorized }
    var remindersAuthorized: Bool { feed.remindersAuthState == .authorized }

    /// Only the enabled EventKit-backed features contribute a permission. The
    /// permission-free features (world clocks, Pomodoro, countdown) never gate
    /// the section — but if an enabled calendar/reminders feature isn't yet
    /// authorized, the section shows a grant prompt first.
    var requiredPermissions: [GlancePermission] {
        var perms: [GlancePermission] = []
        if calendarEnabled, feed.calendarAuthState != .authorized {
            perms.append(GlancePermission(
                id: "eventkit.calendar",
                title: "Calendar",
                iconSystemName: "calendar",
                rationale: "Show your next event.",
                status: { Self.eventKitStatus(EKEventStore.authorizationStatus(for: .event)) },
                request: { [weak self] in await self?.requestCalendarAccess() },
                settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
            ))
        }
        if remindersEnabled, feed.remindersAuthState != .authorized {
            perms.append(GlancePermission(
                id: "eventkit.reminders",
                title: "Reminders",
                iconSystemName: "checklist",
                rationale: "Show your reminders.",
                status: { Self.eventKitStatus(EKEventStore.authorizationStatus(for: .reminder)) },
                request: { [weak self] in await self?.requestRemindersAccess() },
                settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders"
            ))
        }
        return perms
    }

    private static func eventKitStatus(_ status: EKAuthorizationStatus) -> GlancePermission.Status {
        switch status {
        case .fullAccess, .authorized: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied  // .denied, .restricted, .writeOnly (insufficient to read)
        }
    }

    func popoverSection() -> AnyView {
        AnyView(TimeProdPopover(plugin: self))
    }

    func settingsSection() -> AnyView {
        AnyView(TimeProdSettings(plugin: self))
    }

    // MARK: Helpers

    fileprivate static func relativeShort(_ date: Date) -> String {
        let seconds = Int(date.timeIntervalSinceNow)
        if seconds <= 0 { return "now" }
        if seconds < 3600 { return "in \(max(1, seconds / 60))m" }
        if seconds < 86_400 { return "in \(seconds / 3600)h" }
        return "in \(seconds / 86_400)d"
    }
}

// MARK: - Popover UI

private struct TimeProdPopover: View {
    let plugin: TimeProductivityPlugin

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let err = plugin.lastError {
                Label(err, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if plugin.worldClocksEnabled {
                TimeProdSection(title: "World Clocks") {
                    if plugin.zones.isEmpty {
                        Text("No time zones configured.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        VStack(spacing: 6) {
                            ForEach(plugin.zones, id: \.self) { zone in
                                TimeProdClockRow(zoneIdentifier: zone)
                            }
                        }
                    }
                }
            }

            if plugin.calendarEnabled {
                TimeProdSection(title: "Next Event") {
                    TimeProdCalendarBody(plugin: plugin)
                }
            }

            if plugin.remindersEnabled {
                TimeProdSection(title: "Reminders") {
                    TimeProdRemindersBody(plugin: plugin)
                }
            }

            if plugin.pomodoroEnabled {
                TimeProdSection(title: "Pomodoro") {
                    TimeProdPomodoroControls(pomodoro: plugin.pomodoro)
                }
            }

            if plugin.countdownEnabled {
                TimeProdSection(title: "Countdown") {
                    TimeProdCountdownView(label: plugin.countdownLabel, targetDate: plugin.countdownDate)
                }
            }
        }
        .task { await plugin.refresh() }
    }
}

private struct TimeProdSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
    }
}

private struct TimeProdCalendarBody: View {
    let plugin: TimeProductivityPlugin

    var body: some View {
        if !plugin.calendarAuthorized {
            TimeProdAccessPrompt(text: "Calendar access needed.") {
                Task { await plugin.requestCalendarAccess() }
            }
        } else if let event = plugin.nextEvent {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(event.title).font(.body)
                    Spacer()
                    Text(TimeProductivityPlugin.relativeShort(event.startDate))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if plugin.meetingJoinEnabled, let url = event.meetingURL {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Label("Join", systemImage: "video")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
        } else {
            Text("No upcoming events.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct TimeProdRemindersBody: View {
    let plugin: TimeProductivityPlugin

    var body: some View {
        if !plugin.remindersAuthorized {
            TimeProdAccessPrompt(text: "Reminders access needed.") {
                Task { await plugin.requestRemindersAccess() }
            }
        } else if plugin.reminders.isEmpty {
            Text("No open reminders.")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(plugin.reminders) { reminder in
                    HStack {
                        Image(systemName: "circle")
                            .font(.caption2)
                        Text(reminder.title).font(.body)
                        Spacer()
                        if let due = reminder.dueDate {
                            Text(due.formatted(date: .omitted, time: .shortened))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

private struct TimeProdAccessPrompt: View {
    let text: String
    let action: () -> Void

    var body: some View {
        HStack {
            Text(text).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Grant access", action: action)
                .controlSize(.small)
        }
    }
}

private struct TimeProdPomodoroControls: View {
    @Bindable var pomodoro: TimeProdPomodoro

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(pomodoro.phase.rawValue).font(.caption).foregroundStyle(.secondary)
                Text(pomodoro.remainingText).font(.title3.monospacedDigit())
            }
            Spacer()
            HStack(spacing: 6) {
                Button(pomodoro.isRunning ? "Pause" : "Start") {
                    pomodoro.isRunning ? pomodoro.pause() : pomodoro.start()
                }
                .controlSize(.small)
                Button("Reset") { pomodoro.reset() }
                    .controlSize(.small)
            }
        }
    }
}

// MARK: - Settings UI

private struct TimeProdSettings: View {
    @Bindable var plugin: TimeProductivityPlugin
    @State private var zonesText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Features").font(.headline)
            Toggle("World clocks", isOn: $plugin.worldClocksEnabled)
            Toggle("Calendar next event", isOn: $plugin.calendarEnabled)
            Toggle("Reminders", isOn: $plugin.remindersEnabled)
            Toggle("Pomodoro timer", isOn: $plugin.pomodoroEnabled)
            Toggle("Countdown", isOn: $plugin.countdownEnabled)
            Toggle("Meeting join button", isOn: $plugin.meetingJoinEnabled)

            Divider()

            Text("World Clock Zones").font(.headline)
            Text("Comma-separated IANA time zone identifiers, e.g. America/New_York.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("America/New_York, Europe/London", text: $zonesText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)
            Button("Save zones") {
                plugin.zones = zonesText
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }

            Divider()

            Text("Countdown").font(.headline)
            TextField("Label", text: $plugin.countdownLabel)
                .textFieldStyle(.roundedBorder)
            DatePicker("Target date", selection: $plugin.countdownDate)
                .datePickerStyle(.compact)

            Divider()

            Text("Access").font(.headline)
            HStack {
                Button("Grant Calendar access") {
                    Task { await plugin.requestCalendarAccess() }
                }
                Button("Grant Reminders access") {
                    Task { await plugin.requestRemindersAccess() }
                }
            }
        }
        .onAppear {
            zonesText = plugin.zones.joined(separator: ", ")
        }
    }
}
