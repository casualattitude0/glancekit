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

    /// Move a plugin within the ordered list (for drag-to-reorder in Settings).
    func move(fromOffsets: IndexSet, toOffset: Int) {
        var ids = orderedPlugins.map { $0.id }
        ids.move(fromOffsets: fromOffsets, toOffset: toOffset)
        orderedIDs = ids
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
