import SwiftUI
import Observation
import AppKit

/// Countdowns glance: any number of named countdowns to a target date/time.
///
/// Grew out of the retired Time & Productivity glance's single hard-coded
/// countdown into a first-class tool — add as many dated milestones as you like
/// (a launch, a birthday, a trip), each ticking live and sorted soonest-first,
/// with the nearest one surfaced to the Smart Panel.
///
/// Distinct from Timers (duration-based countdowns you start on demand) and
/// Pomodoro (fixed focus/break cycles): a countdown here targets a fixed point
/// on the calendar, so it survives relaunches and "arrives" on its own.
///
/// State is persisted to `UserDefaults` as Codable JSON under
/// `glancekit.countdowns.*`. On first run for anyone upgrading from Time &
/// Productivity, the old single countdown is migrated in (see `init`).
@MainActor
@Observable
final class CountdownsPlugin: GlancePlugin {
    nonisolated var id: String { "countdowns" }
    nonisolated var title: String { "Countdowns" }
    nonisolated var iconSystemName: String { "hourglass" }
    /// The rows tick themselves once a second; a minute cadence is enough to
    /// keep the Smart Panel headline and "arrived" transitions fresh.
    var refreshInterval: TimeInterval { 60 }

    // MARK: Persisted state

    private(set) var items: [CountdownItem] = [] {
        didSet { persist(items, forKey: Keys.items) }
    }
    /// Show seconds in the live readout (off = days/hours/minutes only).
    var showSeconds: Bool {
        didSet { UserDefaults.standard.set(showSeconds, forKey: Keys.showSeconds) }
    }

    private enum Keys {
        static let items = "glancekit.countdowns.items"
        static let showSeconds = "glancekit.countdowns.showSeconds"
        static let migratedKey = "glancekit.countdowns.migratedFromTimeProd"
        // Legacy Time & Productivity keys read once during migration.
        static let legacyDate = "glancekit.timeprod.countdownDate"
        static let legacyLabel = "glancekit.timeprod.countdownLabel"
    }

    init() {
        let defaults = UserDefaults.standard
        showSeconds = defaults.object(forKey: Keys.showSeconds) as? Bool ?? true
        items = Self.load([CountdownItem].self, forKey: Keys.items) ?? []
        migrateLegacyCountdownIfNeeded()
    }

    /// One-shot: fold Time & Productivity's single `(countdownLabel, countdownDate)`
    /// into a first Countdowns item. Guarded by its own flag so a user who later
    /// deletes every countdown doesn't get the old one resurrected.
    private func migrateLegacyCountdownIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Keys.migratedKey) else { return }
        defaults.set(true, forKey: Keys.migratedKey)

        guard let interval = defaults.object(forKey: Keys.legacyDate) as? Double else { return }
        let label = defaults.string(forKey: Keys.legacyLabel) ?? "Deadline"
        items.append(CountdownItem(
            label: label.isEmpty ? "Deadline" : label,
            targetDate: Date(timeIntervalSince1970: interval),
            allDay: false))

        defaults.removeObject(forKey: Keys.legacyDate)
        defaults.removeObject(forKey: Keys.legacyLabel)
    }

    // MARK: GlancePlugin

    func refresh() async {
        // Purely derived from `items` + wall clock; nothing to fetch. Presence of
        // the method keeps the glance on the shared loop so its signal refreshes.
    }

    /// Countdowns sorted for display: soonest still-upcoming first, then any that
    /// have already arrived (most recent arrival first).
    func sortedItems(now: Date = Date()) -> [CountdownItem] {
        items.sorted { a, b in
            let aPast = a.targetDate <= now, bPast = b.targetDate <= now
            if aPast != bPast { return !aPast }          // upcoming before arrived
            if aPast { return a.targetDate > b.targetDate } // arrived: newest first
            return a.targetDate < b.targetDate              // upcoming: soonest first
        }
    }

    func currentSignal() -> GlanceSignal? {
        let now = Date()
        let upcoming = items.filter { $0.targetDate > now }.sorted { $0.targetDate < $1.targetDate }
        guard let next = upcoming.first else { return nil }

        let seconds = next.targetDate.timeIntervalSince(now)
        let priority: GlanceSignal.Priority
        if seconds <= 3600 { priority = .elevated }
        else if seconds <= 86_400 { priority = .normal }
        else { priority = .ambient }

        return GlanceSignal(
            priority: priority,
            score: max(0, 1_000_000 - seconds),  // soonest sorts first
            headline: "\(next.label) · \(Self.shortRemaining(seconds))",
            detail: next.targetDate.formatted(date: .abbreviated, time: next.allDay ? .omitted : .shortened),
            systemImage: "hourglass")
    }

    func popoverSection() -> AnyView { AnyView(CountdownsPopover(plugin: self)) }
    func settingsSection() -> AnyView { AnyView(CountdownsSettings(plugin: self)) }

    // MARK: Commands

    func add(label: String, targetDate: Date, allDay: Bool) {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        items.append(CountdownItem(
            label: trimmed.isEmpty ? "Countdown" : trimmed,
            targetDate: allDay ? Calendar.current.startOfDay(for: targetDate) : targetDate,
            allDay: allDay))
    }

    func update(_ id: UUID, label: String, targetDate: Date, allDay: Bool) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        items[i].label = trimmed.isEmpty ? "Countdown" : trimmed
        items[i].targetDate = allDay ? Calendar.current.startOfDay(for: targetDate) : targetDate
        items[i].allDay = allDay
    }

    func delete(_ id: UUID) { items.removeAll { $0.id == id } }

    func move(from source: IndexSet, to destination: Int) {
        items.move(fromOffsets: source, toOffset: destination)
    }

    // MARK: Formatting

    /// Full readout for a row, honouring `showSeconds`. Reads "Arrived" once the
    /// target passes, then flips to elapsed-since after a moment.
    func remainingText(for item: CountdownItem, now: Date = Date()) -> String {
        let delta = item.targetDate.timeIntervalSince(now)
        if delta <= 0 {
            let elapsed = -delta
            if elapsed < 60 { return "Arrived" }
            return Self.longDuration(elapsed, showSeconds: showSeconds) + " ago"
        }
        return Self.longDuration(delta, showSeconds: showSeconds)
    }

    /// `12d 03:04:05` / `03:04:05` / (no seconds) `12d 03h 04m` / `03h 04m`.
    static func longDuration(_ seconds: TimeInterval, showSeconds: Bool) -> String {
        let total = Int(seconds.rounded())
        let days = total / 86_400
        let hours = (total % 86_400) / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if showSeconds {
            if days > 0 { return String(format: "%dd %02d:%02d:%02d", days, hours, minutes, secs) }
            return String(format: "%02d:%02d:%02d", hours, minutes, secs)
        }
        if days > 0 { return String(format: "%dd %02dh %02dm", days, hours, minutes) }
        if hours > 0 { return String(format: "%02dh %02dm", hours, minutes) }
        return String(format: "%dm", minutes)
    }

    /// Compact form for the Smart Panel headline ("in 12d", "in 3h", "in 5m").
    static func shortRemaining(_ seconds: TimeInterval) -> String {
        if seconds <= 0 { return "now" }
        let total = Int(seconds)
        if total >= 86_400 { return "in \(total / 86_400)d" }
        if total >= 3600 { return "in \(total / 3600)h" }
        return "in \(max(1, total / 60))m"
    }

    // MARK: Persistence

    private func persist<T: Encodable>(_ value: T, forKey key: String) {
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private static func load<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - Model

struct CountdownItem: Codable, Identifiable, Equatable {
    let id: UUID
    var label: String
    var targetDate: Date
    /// Date-only target (no meaningful time-of-day). Drives display + rounding.
    var allDay: Bool

    init(id: UUID = UUID(), label: String, targetDate: Date, allDay: Bool) {
        self.id = id
        self.label = label
        self.targetDate = targetDate
        self.allDay = allDay
    }
}

// MARK: - Popover UI

private struct CountdownsPopover: View {
    @Bindable var plugin: CountdownsPlugin
    @State private var showingAdd = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Countdowns")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    showingAdd = true
                } label: {
                    Label("Add", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }

            if plugin.items.isEmpty {
                CountdownsEmptyState()
            } else {
                VStack(spacing: 6) {
                    ForEach(plugin.sortedItems()) { item in
                        CountdownRow(plugin: plugin, item: item)
                    }
                }
            }
        }
        .popover(isPresented: $showingAdd, arrowEdge: .bottom) {
            CountdownEditor(title: "New Countdown") { label, date, allDay in
                plugin.add(label: label, targetDate: date, allDay: allDay)
                showingAdd = false
            } onCancel: { showingAdd = false }
        }
    }
}

private struct CountdownsEmptyState: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No countdowns yet")
                .font(.callout.weight(.medium))
            Text("Add a dated milestone — a launch, a trip, a deadline — and watch it tick down.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }
}

private struct CountdownRow: View {
    let plugin: CountdownsPlugin
    let item: CountdownItem

    @State private var now = Date()
    @State private var isEditing = false
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var arrived: Bool { item.targetDate <= now }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: arrived ? "checkmark.seal.fill" : "hourglass")
                .foregroundStyle(arrived ? Color.green : Color.accentColor)
                .font(.body)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.label).font(.body).lineLimit(1)
                Text(item.targetDate.formatted(
                    date: .abbreviated, time: item.allDay ? .omitted : .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            Text(plugin.remainingText(for: item, now: now))
                .font(.callout.monospacedDigit())
                .foregroundStyle(arrived ? .secondary : .primary)

            Menu {
                Button {
                    isEditing = true
                } label: { Label("Edit…", systemImage: "pencil") }
                Button(role: .destructive) {
                    plugin.delete(item.id)
                } label: { Label("Delete", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.06)))
        .onReceive(ticker) { now = $0 }
        .popover(isPresented: $isEditing, arrowEdge: .bottom) {
            CountdownEditor(
                title: "Edit Countdown",
                initialLabel: item.label,
                initialDate: item.targetDate,
                initialAllDay: item.allDay
            ) { label, date, allDay in
                plugin.update(item.id, label: label, targetDate: date, allDay: allDay)
                isEditing = false
            } onCancel: { isEditing = false }
        }
    }
}

/// Shared add/edit form used by both the popover's "Add" and a row's "Edit…".
private struct CountdownEditor: View {
    let title: String
    var initialLabel: String = ""
    var initialDate: Date? = nil
    var initialAllDay: Bool = false
    let onSave: (String, Date, Bool) -> Void
    let onCancel: () -> Void

    @State private var label: String
    @State private var date: Date
    @State private var allDay: Bool

    init(
        title: String,
        initialLabel: String = "",
        initialDate: Date? = nil,
        initialAllDay: Bool = false,
        onSave: @escaping (String, Date, Bool) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.title = title
        self.initialLabel = initialLabel
        self.initialDate = initialDate
        self.initialAllDay = initialAllDay
        self.onSave = onSave
        self.onCancel = onCancel
        _label = State(initialValue: initialLabel)
        // Default a fresh countdown to a week out at 9am — a sensible non-zero start.
        _date = State(initialValue: initialDate
            ?? Calendar.current.date(byAdding: .day, value: 7, to: Date())
            ?? Date())
        _allDay = State(initialValue: initialAllDay)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)

            TextField("Label", text: $label)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)

            Toggle("All-day (no time)", isOn: $allDay)
                .toggleStyle(.switch)

            DatePicker(
                "Target",
                selection: $date,
                displayedComponents: allDay ? [.date] : [.date, .hourAndMinute])
                .datePickerStyle(.compact)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save") { onSave(label, date, allDay) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 300)
    }
}

// MARK: - Settings UI

private struct CountdownsSettings: View {
    @Bindable var plugin: CountdownsPlugin

    var body: some View {
        SettingsPage("Countdowns") {
            SettingsToggleRow("Show seconds in the readout", isOn: $plugin.showSeconds)

            Divider()

            SettingsSectionHeader("Your countdowns")
            SettingsHelp("Add and edit countdowns from the glance popover. Reorder or remove them here.")

            if plugin.items.isEmpty {
                SettingsHelp("No countdowns yet.")
            } else {
                ForEach(plugin.sortedItems()) { item in
                    HStack(spacing: 8) {
                        Image(systemName: item.targetDate <= Date() ? "checkmark.seal" : "hourglass")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(item.label)
                            Text(item.targetDate.formatted(
                                date: .abbreviated, time: item.allDay ? .omitted : .shortened))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            plugin.delete(item.id)
                        } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .help("Delete countdown")
                    }
                    .font(.callout)
                }
            }
        }
    }
}
