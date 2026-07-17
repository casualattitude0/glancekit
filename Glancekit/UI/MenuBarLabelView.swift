import SwiftUI

/// The compact status-bar readout. Rotates through the `menuBarSummary` of each
/// glance the user has opted into the menu bar (see the Menu Bar settings page),
/// every few seconds, showing that glance's icon next to its summary. Falls back
/// to the app glyph when nothing contributes a summary.
struct MenuBarLabelView: View {
    @Environment(PluginRegistry.self) private var registry
    @Environment(RefreshCoordinator.self) private var coordinator
    @Environment(\.openWindow) private var openWindow

    @State private var index = 0
    @State private var didOfferOnboarding = false
    @State private var tick = Timer.publish(every: 4, on: .main, in: .common).autoconnect()

    /// One rotating entry per summary: the glance's icon paired with that
    /// summary. A glance may contribute several (Stocks emits one per symbol),
    /// so the bar cycles through every entry, not one per glance.
    private var items: [(icon: String, text: String)] {
        registry.menuBarPluginsInOrder.flatMap { plugin in
            plugin.menuBarSummaries.map { (plugin.iconSystemName, $0) }
        }
    }

    var body: some View {
        Group {
            let entries = items
            if entries.isEmpty {
                Image(systemName: "square.grid.2x2")
            } else {
                let entry = entries[index % entries.count]
                Label(entry.text, systemImage: entry.icon)
            }
        }
        .onReceive(tick) { _ in
            let count = items.count
            guard count > 0 else { return }
            index = (index + 1) % count
        }
        .onAppear {
            // Offer first-run onboarding once, in its own window, without
            // touching the menu-bar popover.
            guard !didOfferOnboarding, OnboardingState.shouldShow() else { return }
            didOfferOnboarding = true
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: OnboardingState.windowID)
        }
    }
}
