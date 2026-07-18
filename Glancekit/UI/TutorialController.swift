import SwiftUI
import Observation

// ─────────────────────────────────────────────────────────────────────────────
// GUIDED TOUR
// ─────────────────────────────────────────────────────────────────────────────
// A short, driveable walkthrough of the Settings window. Unlike `OnboardingView`
// (a one-shot list of toggles in its own window), the tour steers the *real*
// Settings UI: each step selects a sidebar page — so the user sees the actual
// controls — while `TutorialOverlay` spotlights that page and explains it.
//
// The controller owns only the step state and the page-selection side effect.
// The overlay (rendering, anchors, buttons) lives in `TutorialOverlay.swift`; it
// reads `currentStep` and calls `next()` / `back()` / `finish()`.
// ─────────────────────────────────────────────────────────────────────────────

@MainActor
@Observable
final class TutorialController {

    /// The ordered steps of the tour. `rawValue` order is the walk order, so
    /// `next()`/`back()` are index arithmetic and nothing has to hard-code the
    /// neighbours.
    enum Step: Int, CaseIterable {
        /// The Glances page — what to show or hide in the menu bar.
        case glances
        /// The Shortcuts page — quick-open a glance from anywhere.
        case quickOpen
        /// The Quick Switch page — cycle favourite glances with one shortcut.
        case quickSwitch

        /// The sidebar row this step spotlights — also the `tutorialAnchor` id
        /// whose frame the overlay looks up.
        var anchorID: String {
            switch self {
            case .glances: SettingsSection.glances
            case .quickOpen: SettingsSection.shortcuts
            case .quickSwitch: SettingsSection.quickSwitch
            }
        }

        /// The `registry.settingsSelection` value that shows this step's page.
        /// The Glances page is `nil` at that boundary (see `SettingsView`), the
        /// others carry their sentinel.
        var pageSelection: String? {
            switch self {
            case .glances: nil
            case .quickOpen: SettingsSection.shortcuts
            case .quickSwitch: SettingsSection.quickSwitch
            }
        }

        var iconSystemName: String {
            switch self {
            case .glances: "square.grid.2x2.fill"
            case .quickOpen: "bolt.fill"
            case .quickSwitch: "rectangle.stack.fill"
            }
        }

        var title: String {
            switch self {
            case .glances: "Your glances"
            case .quickOpen: "Quick-open shortcuts"
            case .quickSwitch: "Quick Switch"
            }
        }

        var message: String {
            switch self {
            case .glances:
                "This is the Glances page. Flip a switch to show or hide a glance in the menu-bar popover, and drag the enabled ones to set the order they appear in."
            case .quickOpen:
                "On the Shortcuts page you can give any glance a global keyboard shortcut. Press it anywhere in macOS to pop that glance open in its own window at your pointer — no trip to the menu bar."
            case .quickSwitch:
                "Quick Switch flips through your favourite glances with one shortcut (⌥⇥ by default). Choose which glances join the ring and drag their order here, then tap the shortcut to cycle them."
            }
        }
    }

    /// The step currently on screen, or `nil` when no tour is running.
    private(set) var currentStep: Step?

    var isActive: Bool { currentStep != nil }

    /// One-based position for the progress dots ("2 of 3").
    var stepNumber: Int { (currentStep?.rawValue ?? 0) + 1 }
    var stepCount: Int { Step.allCases.count }

    /// Persisted so `MenuBarLabelView` can decide whether to auto-offer the tour
    /// on a fresh launch, and so it never nags twice.
    static let seenKey = "glancekit.tutorial.seen"
    static func hasSeen(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: seenKey)
    }

    private let registry: PluginRegistry

    init(registry: PluginRegistry) {
        self.registry = registry
    }

    /// Begin (or restart) the tour at the first step and bring Settings forward.
    func start() {
        go(to: .glances)
    }

    func next() {
        guard let current = currentStep else { return }
        if let following = Step(rawValue: current.rawValue + 1) {
            go(to: following)
        } else {
            finish()
        }
    }

    func back() {
        guard let current = currentStep,
              let previous = Step(rawValue: current.rawValue - 1) else { return }
        go(to: previous)
    }

    /// End the tour and remember it was seen. Leaves the last-selected page up —
    /// the user lands wherever the tour left them rather than being yanked back.
    func finish() {
        currentStep = nil
        UserDefaults.standard.set(true, forKey: Self.seenKey)
    }

    private func go(to step: Step) {
        currentStep = step
        // Drive the actual Settings selection so the page behind the spotlight is
        // the one the step is talking about.
        registry.settingsSelection = step.pageSelection
        // Make sure Settings is open and frontmost — the tour is meaningless if
        // its window is buried or was never opened (e.g. launched from the
        // onboarding window or the popover).
        SettingsWindowPresenter.present()
    }
}
