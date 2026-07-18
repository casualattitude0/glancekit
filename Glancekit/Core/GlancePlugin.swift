import SwiftUI

/// The single contract every Glancekit tool ("glance") conforms to.
///
/// A glance contributes a rich `popoverSection()` view, shown in the popover
/// window when the user clicks the menu-bar item.
///
/// Plugins are reference types marked `@Observable` (Observation framework) so
/// SwiftUI views re-render automatically when their data changes after a
/// `refresh()`. See `Core/PLUGIN_CONTRACT.md` for the full authoring guide and
/// the Stocks plugin as the worked example.
@MainActor
protocol GlancePlugin: AnyObject {
    /// Stable, unique identifier (e.g. "stocks", "system", "github").
    /// Used as the persistence key for enabled/order state — never change it.
    var id: String { get }

    /// Human-readable name shown in Settings and as the popover section header.
    var title: String { get }

    /// SF Symbol name used as the glance's icon.
    var iconSystemName: String { get }

    /// Desired auto-refresh cadence in seconds. Return 0 to opt out of the
    /// shared refresh loop (e.g. purely event-driven or on-demand glances).
    var refreshInterval: TimeInterval { get }

    /// Fetch/recompute this glance's data. Called on the main actor by the
    /// `RefreshCoordinator`. Must not throw — handle and surface errors
    /// internally (e.g. store an error string for the popover).
    func refresh() async

    /// System permissions this glance needs before its feature can be shown.
    /// Return only permissions that are currently relevant AND not yet granted
    /// (e.g. based on the active source or enabled sub-features). The popover
    /// shows a grant prompt for these instead of `popoverSection()`. Default: none.
    var requiredPermissions: [GlancePermission] { get }

    /// Rich content shown inside the popover window.
    func popoverSection() -> AnyView

    /// Per-glance controls shown in the Settings window. Defaults to empty.
    func settingsSection() -> AnyView

    /// The size the standalone tool window should open at for this glance.
    /// Return `nil` to use the default. A glance with a real editing surface
    /// (e.g. Notes) can ask for more room; most glances don't need to.
    var preferredToolWindowSize: CGSize? { get }

    /// Whether the glance manages its own vertical layout and should fill the
    /// tool window rather than being wrapped in the default scroll-to-fit chrome.
    /// Return `true` for a glance that pins content to the window edges — e.g. a
    /// chat that keeps its composer at the bottom. Default: `false`.
    var fillsToolWindow: Bool { get }
}

extension GlancePlugin {
    func settingsSection() -> AnyView { AnyView(EmptyView()) }
    var refreshInterval: TimeInterval { 0 }
    var requiredPermissions: [GlancePermission] { [] }
    var preferredToolWindowSize: CGSize? { nil }
    var fillsToolWindow: Bool { false }
}
