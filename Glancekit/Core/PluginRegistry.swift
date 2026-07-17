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
