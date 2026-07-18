import Foundation

/// Merges the assistant's three tool sources behind the one seam the agentic
/// loop uses (`specs` + `execute`):
///
/// 1. `AIToolbox` — the built-in palette / notes / glance-enable tools.
/// 2. `AIGlanceToolbox` — tools that operate the newer glances (timers, habits,
///    currency, feeds, world clock, …).
/// 3. `MCPStore` — tools discovered from connected MCP servers, namespaced
///    `mcp__<handle>__<tool>`.
///
/// It also classifies each tool for the approval gate: read-only tools run
/// silently; mutations and every external MCP call ask first.
@MainActor
struct AIToolRouter {
    private let builtin: AIToolbox
    private let glance: AIGlanceToolbox
    private let mcp: MCPStore

    init(registry: PluginRegistry, coordinator: RefreshCoordinator, mcp: MCPStore) {
        self.builtin = AIToolbox(registry: registry, coordinator: coordinator)
        self.glance = AIGlanceToolbox(registry: registry, coordinator: coordinator)
        self.mcp = mcp
    }

    /// The full tool list offered to the model this turn.
    var specs: [AIToolSpec] {
        builtin.specs + glance.specs + mcp.toolSpecs()
    }

    /// Run one call, routing to whichever source owns it. MCP first (by prefix),
    /// then the glance toolbox (which reports what it `handles`), else the
    /// built-in toolbox (which answers "Unknown tool" for anything it doesn't).
    func execute(_ call: AIToolCall) async -> String {
        if mcp.handles(call.name) {
            return await mcp.execute(call.name, arguments: call.arguments)
        }
        if glance.handles(call.name) {
            return await glance.execute(call)
        }
        return await builtin.execute(call)
    }

    // MARK: - Approval classification

    /// Built-in / glance tools that only read state — safe to run without asking.
    private static let readOnly: Set<String> = [
        "list_palettes", "list_notes", "list_tools",
        "timer_list", "habit_list", "currency_list_rates", "feed_list_unread",
        "worldclock_list", "clipboard_recent", "nextmeeting_agenda",
        "network_status", "power_status",
    ]

    /// Whether a call needs the user's OK: every MCP (external) call, and any
    /// built-in/glance tool that isn't on the read-only list (i.e. a mutation).
    func requiresApproval(_ name: String) -> Bool {
        if name.hasPrefix("mcp__") { return true }
        return !Self.readOnly.contains(name)
    }

    func isMCP(_ name: String) -> Bool { name.hasPrefix("mcp__") }

    /// A friendly label for the approval prompt.
    func displayName(for name: String) -> String {
        mcp.displayName(for: name) ?? name
    }
}
