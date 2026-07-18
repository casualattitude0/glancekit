import SwiftUI
import Observation

/// App-wide preference for how the menu-bar panel lays itself out.
///
/// `useSmartPanel` (default **on**) picks the dynamic **Smart Panel** — a
/// priority-ranked feed of the glances that need attention (see `SmartPanelView`)
/// — over the classic layout that shows every enabled glance in a fixed row
/// (`ClassicPanelView`). Backed by a single `UserDefaults` bool so the choice
/// survives relaunches; an absent key reads as `true` so new installs get the
/// new layout.
@MainActor
@Observable
final class MenuPanelSettings {
    private let defaults = UserDefaults.standard
    private let smartKey = "glancekit.menupanel.smart"

    var useSmartPanel: Bool {
        didSet { defaults.set(useSmartPanel, forKey: smartKey) }
    }

    init() {
        // Absent key ⇒ default on, so a fresh install opens on the Smart Panel.
        useSmartPanel = defaults.object(forKey: smartKey) as? Bool ?? true
    }
}
