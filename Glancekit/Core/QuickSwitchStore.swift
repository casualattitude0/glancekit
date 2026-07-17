import Foundation
import Observation

/// Owns the ring of glances the Quick Switch shortcut steps through: which
/// glances are in it, and in what order.
///
/// Kept separate from `PluginRegistry.orderedIDs` on purpose — the popover's
/// layout order and the order you want to tab through are different questions,
/// and folding them together would mean rearranging the popover to change what
/// ⌥⇥ does. State is keyed by plugin `id` and persisted to `UserDefaults`.
@MainActor
@Observable
final class QuickSwitchStore {

    /// Every glance the store has seen, in the user's chosen ring order.
    private(set) var orderedIDs: [String] = []

    /// Ids of the glances that actually take part in the ring.
    private(set) var includedIDs: Set<String> = []

    private let defaults: UserDefaults
    private static let orderKey = "glancekit.quickswitch.order"
    private static let includedKey = "glancekit.quickswitch.included"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        orderedIDs = defaults.stringArray(forKey: Self.orderKey) ?? []
        includedIDs = Set(defaults.stringArray(forKey: Self.includedKey) ?? [])
    }

    /// Appends any glance the store hasn't seen yet, in registration order.
    /// Call once at startup with every registered plugin id.
    ///
    /// Mirrors how `PluginRegistry` seeds enabled state: on a first-ever launch
    /// every glance joins the ring, so ⌥⇥ does something useful before the user
    /// has configured anything. A glance shipped by a later release is only
    /// added to the order — silently splicing it into an existing ring would
    /// change what a shortcut the user already has muscle memory for does.
    func seed(with ids: [String]) {
        let isFirstLaunch = defaults.stringArray(forKey: Self.includedKey) == nil
        for id in ids where !orderedIDs.contains(id) {
            orderedIDs.append(id)
            if isFirstLaunch { includedIDs.insert(id) }
        }
        persist()
    }

    func isIncluded(_ id: String) -> Bool { includedIDs.contains(id) }

    func setIncluded(_ id: String, _ included: Bool) {
        if included { includedIDs.insert(id) } else { includedIDs.remove(id) }
        persist()
    }

    /// Move a glance within one group of the ring order (for drag-to-reorder in
    /// Settings, which lists the included and excluded glances separately).
    ///
    /// `displayed` is every row on the page in display order, and `group` the
    /// rows of the dragged group alone — the offsets are relative to that group.
    /// Rebuilding from `displayed` rather than reordering `orderedIDs` directly
    /// keeps the offsets meaningful when the stored order still holds a retired
    /// id, and prunes that id on the way through.
    ///
    /// The moved ids go back into the slots the group already held, so putting
    /// the ring in the order you want to tab through never shifts an excluded
    /// glance away from the neighbors it will rejoin when switched on.
    func move(
        _ group: [String],
        within displayed: [String],
        fromOffsets offsets: IndexSet,
        toOffset destination: Int
    ) {
        var group = group
        group.move(fromOffsets: offsets, toOffset: destination)

        let slots = Set(group)
        var next = group.makeIterator()
        orderedIDs = displayed.map { slots.contains($0) ? (next.next() ?? $0) : $0 }
        persist()
    }

    /// The glances ⌥⇥ cycles through right now, in ring order.
    ///
    /// Disabled glances drop out: they're hidden from the popover, so tabbing
    /// into one would surface a glance the user has explicitly turned off.
    func ring(in registry: PluginRegistry) -> [any GlancePlugin] {
        orderedIDs.compactMap { id in
            guard includedIDs.contains(id), registry.isEnabled(id) else { return nil }
            return registry.plugin(id: id)
        }
    }

    private func persist() {
        defaults.set(orderedIDs, forKey: Self.orderKey)
        defaults.set(Array(includedIDs), forKey: Self.includedKey)
    }
}
