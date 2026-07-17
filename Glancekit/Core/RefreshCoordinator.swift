import SwiftUI
import Observation

/// Drives per-plugin refresh loops.
///
/// Each enabled plugin with a positive `refreshInterval` gets its own async
/// task that calls `refresh()` immediately, then repeats on its cadence. The
/// coordinator reconciles its running tasks with the registry whenever the
/// enabled set changes.
@MainActor
@Observable
final class RefreshCoordinator {
    private let registry: PluginRegistry
    private var tasks: [String: Task<Void, Never>] = [:]

    /// Timestamp of the most recent successful refresh across all plugins.
    private(set) var lastRefresh: Date?

    init(registry: PluginRegistry) {
        self.registry = registry
    }

    /// Start (or restart) refresh loops for all currently-enabled plugins.
    func start() {
        reconcile()
    }

    /// Manually refresh every enabled plugin right now (e.g. a "Refresh" button).
    func refreshAllNow() {
        for plugin in registry.enabledPluginsInOrder {
            Task { @MainActor in
                await plugin.refresh()
                self.lastRefresh = Date()
            }
        }
    }

    /// Align running loops with the registry's enabled set. Call after the user
    /// toggles a plugin in Settings.
    func reconcile() {
        let enabled = registry.enabledPluginsInOrder
        let enabledIDs = Set(enabled.map { $0.id })

        // Cancel loops for plugins that are no longer enabled.
        for (id, task) in tasks where !enabledIDs.contains(id) {
            task.cancel()
            tasks[id] = nil
        }

        // Launch loops for newly-enabled plugins.
        for plugin in enabled where tasks[plugin.id] == nil {
            tasks[plugin.id] = makeLoop(for: plugin)
        }
    }

    private func makeLoop(for plugin: any GlancePlugin) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            // Always refresh once on start, even for interval == 0 plugins.
            await plugin.refresh()
            self?.lastRefresh = Date()

            let interval = plugin.refreshInterval
            guard interval > 0 else { return }

            while !Task.isCancelled {
                let nanos = UInt64(interval * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
                if Task.isCancelled { break }
                await plugin.refresh()
                self?.lastRefresh = Date()
            }
        }
    }

    func stop() {
        for (_, task) in tasks { task.cancel() }
        tasks.removeAll()
    }
}
