import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// PRESENTATION
// ─────────────────────────────────────────────────────────────────────────────
// Onboarding is a STANDALONE `Window` scene (id `OnboardingState.windowID`), NOT
// a sheet — a sheet presented inside the tiny MenuBarExtra popover would cover
// the glances window entirely. GlancekitApp declares the `Window` scene and opens
// it once on first launch (via MenuBarLabelView's onAppear). The view dismisses
// its own window and marks the "seen" flag through `Get started`.
// ─────────────────────────────────────────────────────────────────────────────

/// Persistence helper for the "has the user seen onboarding?" flag.
/// Key is namespaced per the plugin contract (`glancekit.<name>`).
enum OnboardingState {
    /// Scene identifier for the standalone onboarding `Window`.
    static let windowID = "glancekit.onboarding"
    static let seenKey = "glancekit.onboarding.seen"

    /// True only on the very first launch (flag not yet set).
    static func shouldShow(defaults: UserDefaults = .standard) -> Bool {
        !defaults.bool(forKey: seenKey)
    }

    /// Record that onboarding has been presented so it never shows again.
    static func markSeen(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: seenKey)
    }
}

/// First-run welcome sheet. Shows the app name + pitch, then a live list of all
/// registered plugins each with an enable toggle wired through the registry
/// (mirrors `SettingsView.glancesTab`). "Get started" dismisses and marks seen.
struct OnboardingView: View {
    @Environment(PluginRegistry.self) private var registry
    @Environment(RefreshCoordinator.self) private var coordinator
    @Environment(TutorialController.self) private var tutorial
    @Environment(\.dismiss) private var dismissWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            Text("Pick the glances you want. You can change these anytime in Settings.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 8)

            List {
                ForEach(registry.orderedPlugins, id: \.id) { plugin in
                    HStack {
                        Label(plugin.title, systemImage: plugin.iconSystemName)
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { registry.isEnabled(plugin.id) },
                            set: { newValue in
                                registry.setEnabled(plugin.id, newValue)
                                coordinator.reconcile()
                            }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }
                }
            }
            .frame(minHeight: 220)

            Divider()

            HStack {
                Button("Skip") { dismiss() }
                    .buttonStyle(.bordered)
                Spacer()
                Button {
                    startTour()
                } label: {
                    Label("Take a quick tour", systemImage: "sparkles")
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
        .frame(width: 420, height: 460)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.grid.2x2.fill")
                .font(.largeTitle)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Welcome to Glancekit")
                    .font(.title2.weight(.semibold))
                Text("At-a-glance info in your menu bar.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(20)
    }

    private func dismiss() {
        OnboardingState.markSeen()
        dismissWindow()
    }

    /// Close the welcome window and hand off to the guided tour, which opens
    /// Settings and walks through the Glances and Shortcuts pages.
    private func startTour() {
        OnboardingState.markSeen()
        dismissWindow()
        tutorial.start()
    }
}
