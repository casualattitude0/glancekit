import SwiftUI

/// The status-bar item's label: the app glyph. Clicking it opens the popover,
/// which is where every glance's content lives.
struct MenuBarLabelView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(RefreshCoordinator.self) private var coordinator

    @State private var didOfferOnboarding = false

    var body: some View {
        Image(systemName: "square.grid.2x2")
            .onAppear {
                // Hand the presenter SwiftUI's `openSettings` action so the Open
                // Settings hotkey (and the guided tour) can open the window on
                // the first press, instead of no-opping until Settings has been
                // opened some other way. The label is built at launch, so this
                // registers before any hotkey can fire.
                SettingsWindowPresenter.registerOpenAction { openSettings() }

                // Add the right-click Settings/Quit menu to the status item.
                // Left-click still opens the popover — this only handles the
                // right button, which SwiftUI leaves dead.
                MenuBarPresenter.installRightClickMenu()

                // The label is the one view MenuBarExtra builds at launch; the
                // popover content stays unbuilt until the first click. Starting
                // here is a deliberate call by the owner: glances refresh from
                // launch, before anyone has looked at them, so a hotkeyed tool
                // window or the first popover opens on fresh data instead of
                // empty sections. `start()` reconciles rather than respawns, so
                // a repeat onAppear cannot double a plugin's loops.
                coordinator.start()

                // Offer first-run onboarding once, in its own window, without
                // touching the menu-bar popover.
                guard !didOfferOnboarding, OnboardingState.shouldShow() else { return }
                didOfferOnboarding = true
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: OnboardingState.windowID)
            }
    }
}
