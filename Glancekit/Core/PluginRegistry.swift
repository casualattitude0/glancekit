import SwiftUI
import Observation

/// Owns the full set of glances and their user-controlled enabled/order state.
///
/// Every plugin is registered once at launch (see `GlancekitApp`). Enabled and
/// ordering state is keyed by each plugin's stable `id` and persisted to
/// `UserDefaults`, so adding a new plugin never disturbs existing preferences.
@MainActor
@Observable
final class PluginRegistry {

    /// The Assistant glance's id. It's a pinned, app-wide page (its settings live
    /// at the top of the General sidebar and it stays in the popover regardless of
    /// the Smart Panel choice), so it's deliberately kept out of the enable/reorder
    /// and Quick Switch lists — the settings views filter on this.
    static let assistantPluginID = "ai"

    /// All known plugins, in registration order. This is the master list;
    /// user ordering is applied on top via `orderedIDs`.
    private(set) var plugins: [any GlancePlugin] = []

    /// User-facing order of plugin IDs. Any registered plugin not present here
    /// is appended in registration order.
    private(set) var orderedIDs: [String] = []

    /// Set of enabled plugin IDs.
    private(set) var enabledIDs: Set<String> = []

    /// The section the Settings window should show. `nil` = the Glances tab.
    /// Set from the popover (clicking a glance) to deep-link into that plugin's
    /// settings; the Settings view observes and follows it.
    var settingsSelection: String? = nil

    private let defaults = UserDefaults.standard
    private let orderKey = "glancekit.plugin.order"
    private let enabledKey = "glancekit.plugin.enabled"

    init() {
        orderedIDs = defaults.stringArray(forKey: orderKey) ?? []
        if let saved = defaults.stringArray(forKey: enabledKey) {
            enabledIDs = Set(saved)
        } else {
            enabledIDs = [] // seeded on first register() call below
        }
        migrateColorGlances()
        migratePomodoroSplit()
        migrateTimeProdSplit()
    }

    // MARK: - Migrations

    /// One-shot: the "colorpicker" and "colorpalette" glances merged into a
    /// single "colors" glance. Carries the retired ids' state onto the new one
    /// and prunes them, so the merged glance lands in the same slot and stays
    /// visible for anyone who had either half enabled.
    ///
    /// Stale ids in `orderedIDs` are harmless on their own (`orderedPlugins`
    /// resolves against registered plugins), but "colors" would be missing from
    /// `enabledIDs` entirely — and `register()` only seeds enabled state on a
    /// first-ever launch, so without this the merged glance would silently be
    /// off for every existing user.
    private func migrateColorGlances() {
        let migrationKey = "glancekit.migration.colors"
        guard !defaults.bool(forKey: migrationKey) else { return }
        defaults.set(true, forKey: migrationKey)

        let retired = ["colorpicker", "colorpalette"]
        let merged = "colors"

        // Fresh install: nothing to carry over. Returning before `persist()`
        // matters — writing the (empty) keys here would make `register()` think
        // this isn't a first launch and skip seeding every glance on.
        guard orderedIDs.contains(where: retired.contains)
                || enabledIDs.contains(where: retired.contains)
        else { return }

        if !orderedIDs.contains(merged),
           let slot = orderedIDs.firstIndex(where: retired.contains) {
            orderedIDs.insert(merged, at: slot)
        }
        // Either half being on is enough: the merged tool does both jobs.
        if enabledIDs.contains(where: retired.contains) { enabledIDs.insert(merged) }

        orderedIDs.removeAll { retired.contains($0) }
        enabledIDs.subtract(retired)

        persist()
    }

    /// One-shot: the Pomodoro timer left the "timeprod" glance and became the
    /// standalone "pomodoro" glance. Lands it next to the glance it came out of
    /// and carries over whether the user had the sub-feature switched on.
    ///
    /// Without this the new glance would be missing from `enabledIDs` — and
    /// `register()` only seeds enabled state on a first-ever launch — so anyone
    /// already using the Pomodoro timer would find it silently gone.
    private func migratePomodoroSplit() {
        let migrationKey = "glancekit.migration.pomodoroSplit"
        guard !defaults.bool(forKey: migrationKey) else { return }
        defaults.set(true, forKey: migrationKey)

        let source = "timeprod"
        let split = "pomodoro"
        let featureKey = "glancekit.timeprod.pomodoro"

        // Fresh install: nothing to carry over. Returning before `persist()`
        // matters — writing the (empty) keys here would make `register()` think
        // this isn't a first launch and skip seeding every glance on.
        guard orderedIDs.contains(source) else { return }

        if !orderedIDs.contains(split), let slot = orderedIDs.firstIndex(of: source) {
            orderedIDs.insert(split, at: slot + 1)
        }
        // The sub-feature defaulted on, so a missing key means it was on.
        let wasShowingPomodoro = defaults.object(forKey: featureKey) as? Bool ?? true
        if enabledIDs.contains(source), wasShowingPomodoro {
            enabledIDs.insert(split)
        }
        defaults.removeObject(forKey: featureKey)

        persist()
    }

    /// One-shot: the catch-all "timeprod" glance was retired. Its calendar +
    /// meeting-join features were already superseded by the standalone
    /// "nextmeeting" glance; its two remaining features became standalone
    /// glances of their own — "reminders" and "countdowns". This lands each new
    /// glance next to where timeprod sat and carries over whether the user had
    /// that sub-feature switched on.
    ///
    /// Without this the new glances would be missing from `enabledIDs` — and
    /// `register()` only seeds enabled state on a first-ever launch — so anyone
    /// already using reminders or the countdown would find them silently gone.
    /// (The countdown's *data* is migrated separately, inside `CountdownsPlugin`.)
    private func migrateTimeProdSplit() {
        let migrationKey = "glancekit.migration.timeprodSplit"
        guard !defaults.bool(forKey: migrationKey) else { return }
        defaults.set(true, forKey: migrationKey)

        let source = "timeprod"

        // Fresh install: nothing to carry over. Returning before `persist()`
        // matters — writing the (empty) keys here would make `register()` think
        // this isn't a first launch and skip seeding every glance on.
        guard orderedIDs.contains(source) else { return }

        // Both sub-features defaulted on, so a missing key means it was on.
        let remindersOn = defaults.object(forKey: "glancekit.timeprod.reminders") as? Bool ?? true
        let countdownOn = defaults.object(forKey: "glancekit.timeprod.countdown") as? Bool ?? true
        let timeProdEnabled = enabledIDs.contains(source)

        // Insert the split glances right after timeprod's old slot, in order.
        if let slot = orderedIDs.firstIndex(of: source) {
            for (offset, newID) in ["reminders", "countdowns"].enumerated()
            where !orderedIDs.contains(newID) {
                orderedIDs.insert(newID, at: slot + 1 + offset)
            }
        }

        if timeProdEnabled, remindersOn { enabledIDs.insert("reminders") }
        if timeProdEnabled, countdownOn { enabledIDs.insert("countdowns") }

        // Retire the old glance and its now-defunct feature toggles.
        orderedIDs.removeAll { $0 == source }
        enabledIDs.remove(source)
        for key in ["glancekit.timeprod.reminders", "glancekit.timeprod.countdown",
                    "glancekit.timeprod.calendar", "glancekit.timeprod.worldClocks",
                    "glancekit.timeprod.meetingJoin", "glancekit.timeprod.zones"] {
            defaults.removeObject(forKey: key)
        }

        persist()
    }

    /// Register a plugin. Call once per plugin during app startup.
    func register(_ plugin: any GlancePlugin) {
        guard !plugins.contains(where: { $0.id == plugin.id }) else { return }
        plugins.append(plugin)

        // First-ever launch: enable everything by default.
        if defaults.stringArray(forKey: enabledKey) == nil {
            enabledIDs.insert(plugin.id)
        }
        if !orderedIDs.contains(plugin.id) {
            orderedIDs.append(plugin.id)
        }
        persist()
    }

    /// Plugins the user has enabled, in the user's chosen order.
    var enabledPluginsInOrder: [any GlancePlugin] {
        orderedPlugins.filter { enabledIDs.contains($0.id) }
    }

    /// All plugins in user order (regardless of enabled state) — for Settings.
    var orderedPlugins: [any GlancePlugin] {
        orderedIDs.compactMap { id in plugins.first { $0.id == id } }
    }

    func isEnabled(_ id: String) -> Bool { enabledIDs.contains(id) }

    func setEnabled(_ id: String, _ enabled: Bool) {
        if enabled { enabledIDs.insert(id) } else { enabledIDs.remove(id) }
        persist()
    }

    /// Plugins the user has disabled, in the user's chosen order. Disabled
    /// glances keep their slot in `orderedIDs`, so re-enabling one drops it back
    /// where it was rather than at the end.
    var disabledPluginsInOrder: [any GlancePlugin] {
        orderedPlugins.filter { !enabledIDs.contains($0.id) }
    }

    /// Reorder a group of glances shown together in Settings (the enabled or the
    /// disabled section), where `group` is exactly the ids the list displayed and
    /// the offsets are relative to that list. Passing the displayed ids — rather
    /// than deriving them here — lets a caller drag among a filtered subset (e.g.
    /// with the pinned Assistant hidden) without the offsets drifting.
    ///
    /// The moved ids are written back into the slots that group already occupied
    /// in `orderedIDs`, so reordering the enabled glances never shifts a disabled
    /// (or filtered-out) one out from between its neighbors — it stays put and
    /// keeps the position it will reappear at when switched back on.
    func move(group: [String], fromOffsets: IndexSet, toOffset: Int) {
        var group = group
        group.move(fromOffsets: fromOffsets, toOffset: toOffset)

        // Only ids that resolved to a registered plugin are in `group`; matching
        // on that set keeps a stale id in `orderedIDs` from consuming a slot.
        let slots = Set(group)
        var next = group.makeIterator()
        orderedIDs = orderedIDs.map { slots.contains($0) ? (next.next() ?? $0) : $0 }
        persist()
    }

    func plugin(id: String) -> (any GlancePlugin)? {
        plugins.first { $0.id == id }
    }

    private func persist() {
        defaults.set(orderedIDs, forKey: orderKey)
        defaults.set(Array(enabledIDs), forKey: enabledKey)
    }
}
