import SwiftUI

/// The status-bar item's label: the app glyph. Clicking it opens the popover,
/// which is where every glance's content lives.
struct MenuBarLabelView: View {
    @Environment(\.openWindow) private var openWindow

    @State private var didOfferOnboarding = false

    var body: some View {
        Image(systemName: "square.grid.2x2")
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
