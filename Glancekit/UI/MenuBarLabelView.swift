import SwiftUI

/// The compact status-bar readout. Rotates through the `menuBarSummary` of each
/// enabled plugin every few seconds; falls back to the app glyph when no plugin
/// contributes a summary.
struct MenuBarLabelView: View {
    @Environment(PluginRegistry.self) private var registry
    @Environment(RefreshCoordinator.self) private var coordinator
    @Environment(\.openWindow) private var openWindow

    @State private var index = 0
    @State private var didOfferOnboarding = false
    @State private var tick = Timer.publish(every: 4, on: .main, in: .common).autoconnect()

    private var summaries: [String] {
        registry.enabledPluginsInOrder.compactMap { $0.menuBarSummary }
    }

    var body: some View {
        Group {
            let items = summaries
            if items.isEmpty {
                Image(systemName: "square.grid.2x2")
            } else {
                let safeIndex = index % items.count
                Text(items[safeIndex])
            }
        }
        .onReceive(tick) { _ in
            let count = summaries.count
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
