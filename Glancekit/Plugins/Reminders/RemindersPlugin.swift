import SwiftUI
import Observation
import EventKit
import AppKit

/// A standalone, focused Reminders glance. Grew out of the retired Time &
/// Productivity glance's single read-only reminder list into a first-class
/// tool: it groups open reminders into Overdue / Today / Upcoming / No date,
/// lets you tick them complete in place, filter by list, and surfaces overdue
/// and due-today counts to the Smart Panel.
///
/// It owns its own EventKit feed (`RemindersFeed`) and never imports another
/// plugin. All EventKit access is best-effort: denied/undetermined
/// authorization never crashes `refresh()`, it just surfaces a grant prompt via
/// `requiredPermissions` (see `docs/PLUGIN_CONTRACT.md` rule 4).
@MainActor
@Observable
final class RemindersPlugin: GlancePlugin {
    nonisolated var id: String { "reminders" }
    nonisolated var title: String { "Reminders" }
    nonisolated var iconSystemName: String { "checklist" }
    var refreshInterval: TimeInterval { 60 }

    // MARK: Persisted settings

    /// How many days ahead the "Upcoming" group reaches. Reminders due beyond
    /// this window are hidden so the glance stays about what's near.
    var lookAheadDays: Int {
        didSet { UserDefaults.standard.set(lookAheadDays, forKey: Keys.lookAheadDays) }
    }
    /// Include reminders that have no due date at all.
    var showUndated: Bool {
        didSet { UserDefaults.standard.set(showUndated, forKey: Keys.showUndated) }
    }
    /// Max reminders shown per group before a "+N more" line.
    var perGroupLimit: Int {
        didSet { UserDefaults.standard.set(perGroupLimit, forKey: Keys.perGroupLimit) }
    }
    /// Selected reminder-list identifiers. `nil` = every list (the default); an
    /// empty set = the user explicitly chose none.
    var selectedListIDs: Set<String>? {
        didSet {
            if let selectedListIDs {
                UserDefaults.standard.set(Array(selectedListIDs), forKey: Keys.selectedLists)
            } else {
                UserDefaults.standard.removeObject(forKey: Keys.selectedLists)
            }
        }
    }

    // MARK: Live state

    private(set) var reminders: [ReminderSnapshot] = []
    private(set) var lastError: String?

    private let feed = RemindersFeed()

    private enum Keys {
        static let lookAheadDays = "glancekit.reminders.lookAheadDays"
        static let showUndated = "glancekit.reminders.showUndated"
        static let perGroupLimit = "glancekit.reminders.perGroupLimit"
        static let selectedLists = "glancekit.reminders.selectedLists"
    }

    init() {
        let defaults = UserDefaults.standard
        lookAheadDays = defaults.object(forKey: Keys.lookAheadDays) as? Int ?? 7
        showUndated = defaults.object(forKey: Keys.showUndated) as? Bool ?? true
        perGroupLimit = defaults.object(forKey: Keys.perGroupLimit) as? Int ?? 5
        if let ids = defaults.object(forKey: Keys.selectedLists) as? [String] {
            selectedListIDs = Set(ids)
        } else {
            selectedListIDs = nil
        }
    }

    private var queryOptions: RemindersQueryOptions {
        RemindersQueryOptions(listIDs: selectedListIDs)
    }

    // MARK: GlancePlugin

    func refresh() async {
        lastError = nil
        guard feed.authState == .authorized else {
            reminders = []
            return
        }
        let loaded = await feed.loadIncomplete(options: queryOptions)
        // Drop anything due beyond the look-ahead window; undated survive only
        // when the user asked to keep them.
        let horizon = Calendar.current.date(byAdding: .day, value: max(1, lookAheadDays), to: Date())
        reminders = loaded.filter { r in
            guard let due = r.dueDate else { return showUndated }
            guard let horizon else { return true }
            return due <= horizon
        }
    }

    func toggleCompleted(_ id: String) {
        let current = reminders.first { $0.id == id }?.isCompleted ?? false
        feed.setCompleted(id, !current)
        // Optimistic: drop it from the open list immediately, then reconcile.
        reminders.removeAll { $0.id == id }
        Task { await refresh() }
    }

    func availableLists() -> [ReminderList] { feed.availableLists() }

    func isListSelected(_ id: String) -> Bool {
        guard let selectedListIDs else { return true }
        return selectedListIDs.contains(id)
    }

    /// Toggle a list in/out of the selection. Starting from "all" (`nil`), the
    /// first toggle expands to the concrete set so the choice is explicit; a set
    /// covering every list collapses back to `nil` so newly-added lists stay in
    /// by default.
    func setList(_ id: String, included: Bool, allIDs: [String]) {
        var set = selectedListIDs ?? Set(allIDs)
        if included { set.insert(id) } else { set.remove(id) }
        selectedListIDs = (set == Set(allIDs)) ? nil : set
    }

    func selectAllLists() { selectedListIDs = nil }
    func selectNoLists() { selectedListIDs = [] }

    var hasNoListsSelected: Bool {
        if let selectedListIDs { return selectedListIDs.isEmpty }
        return false
    }

    func requestAccess() async {
        _ = await feed.requestAccess()
        await refresh()
    }

    var authorized: Bool { feed.authState == .authorized }

    var requiredPermissions: [GlancePermission] {
        guard feed.authState != .authorized else { return [] }
        return [GlancePermission(
            id: "reminders.reminders",
            title: "Reminders",
            iconSystemName: "checklist",
            rationale: "Show and complete your reminders.",
            status: { Self.eventKitStatus(EKEventStore.authorizationStatus(for: .reminder)) },
            request: { [weak self] in await self?.requestAccess() },
            settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders"
        )]
    }

    private static func eventKitStatus(_ status: EKAuthorizationStatus) -> GlancePermission.Status {
        switch status {
        case .fullAccess, .authorized: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    // MARK: Grouping

    /// The four buckets, in display order. Computed from `reminders` each read
    /// so a tick-complete reflows without extra bookkeeping.
    struct Groups {
        var overdue: [ReminderSnapshot] = []
        var today: [ReminderSnapshot] = []
        var upcoming: [ReminderSnapshot] = []
        var undated: [ReminderSnapshot] = []
    }

    func groups(now: Date = Date()) -> Groups {
        let cal = Calendar.current
        var g = Groups()
        for r in reminders {
            guard let due = r.dueDate else { g.undated.append(r); continue }
            if due < now && !cal.isDate(due, inSameDayAs: now) {
                g.overdue.append(r)
            } else if cal.isDateInToday(due) || due < now {
                // A time earlier today still reads as "today", not overdue.
                g.today.append(r)
            } else {
                g.upcoming.append(r)
            }
        }
        let byDue: (ReminderSnapshot, ReminderSnapshot) -> Bool = { a, b in
            (a.dueDate ?? .distantFuture) < (b.dueDate ?? .distantFuture)
        }
        g.overdue.sort(by: byDue)
        g.today.sort(by: byDue)
        g.upcoming.sort(by: byDue)
        g.undated.sort { Self.priorityRank($0.priority) < Self.priorityRank($1.priority) }
        return g
    }

    /// EventKit priority is 1 (high) … 9 (low), 0 = none. Map to a sort rank
    /// where high sorts first and "none" sorts last.
    static func priorityRank(_ priority: Int) -> Int {
        priority == 0 ? Int.max : priority
    }

    // MARK: Smart Panel

    func currentSignal() -> GlanceSignal? {
        guard authorized else { return nil }
        let g = groups()
        let openCount = reminders.count
        guard openCount > 0 else { return nil }

        if let first = g.overdue.first {
            let n = g.overdue.count
            return GlanceSignal(
                priority: .urgent, score: Double(1000 + n),
                headline: n == 1 ? "1 overdue reminder" : "\(n) overdue reminders",
                detail: first.title,
                systemImage: "exclamationmark.circle", tint: .red)
        }
        if let first = g.today.first {
            let n = g.today.count
            return GlanceSignal(
                priority: .elevated, score: Double(500 + n),
                headline: n == 1 ? "1 reminder due today" : "\(n) reminders due today",
                detail: first.title,
                systemImage: "checklist", tint: .orange)
        }
        return GlanceSignal(
            priority: .ambient, score: Double(openCount),
            headline: openCount == 1 ? "1 open reminder" : "\(openCount) open reminders",
            detail: (g.upcoming.first ?? g.undated.first)?.title,
            systemImage: "checklist", tint: .secondary)
    }

    func popoverSection() -> AnyView { AnyView(RemindersPopover(plugin: self)) }
    func settingsSection() -> AnyView { AnyView(RemindersSettings(plugin: self)) }

    // MARK: Helpers

    /// A compact due-date label for a reminder row.
    static func dueLabel(_ r: ReminderSnapshot, now: Date = Date()) -> String? {
        guard let due = r.dueDate else { return nil }
        let cal = Calendar.current
        if cal.isDateInToday(due) {
            return r.hasTime ? due.formatted(date: .omitted, time: .shortened) : "Today"
        }
        if cal.isDateInTomorrow(due) {
            return r.hasTime
                ? "Tomorrow " + due.formatted(date: .omitted, time: .shortened)
                : "Tomorrow"
        }
        if r.hasTime {
            return due.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        }
        return due.formatted(.dateTime.month(.abbreviated).day())
    }
}

// MARK: - Popover UI

private struct RemindersPopover: View {
    let plugin: RemindersPlugin

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let err = plugin.lastError {
                Label(err, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(GlanceStyle.warning)
            }

            if plugin.hasNoListsSelected {
                RemindersEmptyState(
                    icon: "checklist.unchecked",
                    text: "No lists selected. Choose lists in Settings.")
            } else if plugin.reminders.isEmpty {
                RemindersEmptyState(
                    icon: "checkmark.circle",
                    text: "You're all caught up — no open reminders.")
            } else {
                let g = plugin.groups()
                RemindersGroup(title: "Overdue", tint: .red, reminders: g.overdue, plugin: plugin)
                RemindersGroup(title: "Today", tint: .orange, reminders: g.today, plugin: plugin)
                RemindersGroup(title: "Upcoming", tint: .secondary, reminders: g.upcoming, plugin: plugin)
                RemindersGroup(title: "No due date", tint: .secondary, reminders: g.undated, plugin: plugin)
            }
        }
        .task { await plugin.refresh() }
    }
}

private struct RemindersEmptyState: View {
    let icon: String
    let text: String

    var body: some View {
        Label(text, systemImage: icon)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.05)))
    }
}

private struct RemindersGroup: View {
    let title: String
    let tint: Color
    let reminders: [ReminderSnapshot]
    let plugin: RemindersPlugin

    var body: some View {
        if !reminders.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tint == .secondary ? Color.secondary : tint)
                    Text("\(reminders.count)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                }
                let limit = max(1, plugin.perGroupLimit)
                VStack(spacing: 4) {
                    ForEach(reminders.prefix(limit)) { reminder in
                        RemindersRow(reminder: reminder, tint: tint, plugin: plugin)
                    }
                }
                if reminders.count > limit {
                    Text("+\(reminders.count - limit) more")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct RemindersRow: View {
    let reminder: ReminderSnapshot
    let tint: Color
    let plugin: RemindersPlugin

    private var components: (Double, Double, Double, Double) { reminder.listColor.swiftUIColorComponents }
    private var listColor: Color {
        Color(.sRGB, red: components.0, green: components.1, blue: components.2, opacity: components.3)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button {
                plugin.toggleCompleted(reminder.id)
            } label: {
                Image(systemName: "circle")
                    .font(.body)
                    .foregroundStyle(tint == .secondary ? Color.secondary : tint)
            }
            .buttonStyle(.plain)
            .help("Mark complete")

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    if reminder.priority != 0, reminder.priority <= 5 {
                        Image(systemName: "exclamationmark")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(GlanceStyle.warning)
                    }
                    Text(reminder.title)
                        .font(.body)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    Circle().fill(listColor).frame(width: 6, height: 6)
                    Text(reminder.listTitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if let due = RemindersPlugin.dueLabel(reminder) {
                Text(due)
                    .font(.caption2)
                    .foregroundStyle(tint == .red ? Color.red : .secondary)
            }
        }
    }
}

// MARK: - Settings UI

private struct RemindersSettings: View {
    @Bindable var plugin: RemindersPlugin

    var body: some View {
        SettingsPage("Reminders") {
            SettingsSectionHeader("What to show")
            Stepper(
                "Look ahead \(plugin.lookAheadDays) day\(plugin.lookAheadDays == 1 ? "" : "s")",
                value: $plugin.lookAheadDays, in: 1...60)
            SettingsHelp("Reminders due beyond this window are hidden so the glance stays about what's near.")
            SettingsToggleRow("Show reminders with no due date", isOn: $plugin.showUndated)
            Stepper(
                "Show up to \(plugin.perGroupLimit) per group",
                value: $plugin.perGroupLimit, in: 1...20)

            Divider()

            RemindersListPicker(plugin: plugin)

            Divider()

            SettingsSectionHeader("Access")
            Button("Grant Reminders access") {
                Task { await plugin.requestAccess() }
            }
        }
    }
}

/// Multi-select list of the user's reminder lists. "All lists" is the default
/// (nil selection); toggling any off makes the selection explicit.
private struct RemindersListPicker: View {
    let plugin: RemindersPlugin
    @State private var lists: [ReminderList] = []

    private var allIDs: [String] { lists.map(\.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SettingsSectionHeader("Lists")
                Spacer()
                Button("All") { plugin.selectAllLists() }.controlSize(.small)
                Button("None") { plugin.selectNoLists() }.controlSize(.small)
            }

            if !plugin.authorized {
                SettingsHelp("Grant Reminders access to choose lists.")
            } else if lists.isEmpty {
                SettingsHelp("No reminder lists found.")
            } else {
                ForEach(lists) { list in
                    Toggle(isOn: Binding(
                        get: { plugin.isListSelected(list.id) },
                        set: { plugin.setList(list.id, included: $0, allIDs: allIDs) }
                    )) {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(Color(
                                    .sRGB,
                                    red: list.color.red, green: list.color.green,
                                    blue: list.color.blue, opacity: list.color.alpha))
                                .frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(list.title)
                                if !list.sourceTitle.isEmpty {
                                    Text(list.sourceTitle)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                if plugin.hasNoListsSelected {
                    Text("No lists selected — the glance will be empty.")
                        .font(.caption)
                        .foregroundStyle(GlanceStyle.warning)
                }
            }
        }
        .onAppear { lists = plugin.availableLists() }
    }
}
