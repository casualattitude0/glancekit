import SwiftUI

/// Stable identifiers for the three app-wide "General" sidebar pages. These are
/// sentinel `settingsSelection` values — not plugin ids — shared between
/// `SettingsView` (which renders and selects them) and `TutorialController`
/// (which drives the selection to walk the tour through them). Keeping them in
/// one place stops the two from drifting apart.
///
/// Note the Glances page maps to `settingsSelection == nil` at the registry
/// boundary (see `SettingsView.sidebarSelection`); `SettingsSection.glances` is
/// only ever used as a `List` tag and a tutorial anchor id, never written to the
/// registry directly.
enum SettingsSection {
    static let glances = "__glances__"
    static let shortcuts = "__shortcuts__"
    static let quickSwitch = "__quickswitch__"
}

/// The Settings window: a sidebar of sections beside a detail pane, matching the
/// standard macOS settings layout (System Settings, Xcode, Mail).
///
/// The sidebar replaces an earlier custom chip bar — and, before that, a native
/// `TabView`, whose tab bar overflowed extra plugins into a `>>` dropdown. A
/// sidebar list scrolls vertically and stays legible however many plugins are
/// registered. The first group holds the app-wide pages ("Glances" — toggle +
/// drag-to-reorder, with the update check above — and "Shortcuts"); the second
/// lists each plugin's own
/// `settingsSection()`.
struct SettingsView: View {
    @Environment(PluginRegistry.self) private var registry
    @Environment(RefreshCoordinator.self) private var coordinator
    @Environment(UpdateChecker.self) private var updater
    @Environment(TutorialController.self) private var tutorial
    @Environment(MenuPanelSettings.self) private var panelSettings

    /// Sentinel `settingsSelection` values for the pages that aren't a plugin's
    /// own section. `registry.settingsSelection` uses `nil` for the Glances page
    /// (that's the deep-link contract the popover writes to), but a `List`
    /// selection reads `nil` as "nothing selected" — so the sidebar swaps in
    /// this sentinel and `sidebarSelection` maps it back at the boundary.
    private static let glancesSelection = SettingsSection.glances
    private static let shortcutsSelection = SettingsSection.shortcuts
    private static let quickSwitchSelection = SettingsSection.quickSwitch

    /// The Assistant glance's id — promoted to a top-of-General sidebar entry.
    /// Its detail pane is its plugin `settingsSection()`, resolved the same way
    /// as any other plugin selection (`detail` / `detailTitle` need no change).
    private static let assistantPluginID = "ai"

    /// Bridges the registry's `nil`-means-Glances contract to a `List` selection
    /// where `nil` means nothing is selected.
    private var sidebarSelection: Binding<String?> {
        Binding(
            get: { registry.settingsSelection ?? Self.glancesSelection },
            set: { registry.settingsSelection = $0 == Self.glancesSelection ? nil : $0 }
        )
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            detail
        }
        .frame(width: 620, height: 460)
        // Settings has no Cancel button to bind ⎋ to, so nothing else claims it.
        // The shortcut recorder swallows ⎋ while recording via a local event
        // monitor, which runs before the responder chain — so cancelling a
        // recording never falls through to closing the window.
        .onExitCommand {
            // ⎋ dismisses the guided tour if it's running; otherwise it closes
            // the window as before. Otherwise a stray ⎋ mid-tour would shut the
            // whole window instead of just stepping out of the coach mark.
            if tutorial.isActive { tutorial.finish() } else { SettingsWindowPresenter.close() }
        }
        // The guided tour paints a spotlight over the relevant sidebar page and
        // a callout beside it. It reads the sidebar rows' frames through the
        // anchor preferences the `.tutorialAnchor` rows publish. Inert (and fully
        // click-through) whenever no tour is running.
        .overlayPreferenceValue(TutorialAnchorKey.self) { anchors in
            GeometryReader { proxy in
                TutorialOverlay(anchors: anchors, proxy: proxy)
            }
            .allowsHitTesting(tutorial.isActive)
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: sidebarSelection) {
            Section("General") {
                // The Assistant is promoted out of the plugin list to the top of
                // General: it configures the app as a whole (provider keys, the
                // tools it can drive), so it reads as an app-wide page, not one
                // glance among many. It's still an ordinary glance elsewhere
                // (popover, enable/reorder) — only its settings entry moves here.
                if let assistant = registry.plugin(id: Self.assistantPluginID) {
                    Label(assistant.title, systemImage: assistant.iconSystemName)
                        .tag(Self.assistantPluginID)
                }
                Label("Glances", systemImage: "square.grid.2x2")
                    .tag(Self.glancesSelection)
                    .tutorialAnchor(SettingsSection.glances)
                Label("Shortcuts", systemImage: "command")
                    .tag(Self.shortcutsSelection)
                    .tutorialAnchor(SettingsSection.shortcuts)
                Label("Quick Switch", systemImage: "rectangle.stack")
                    .tag(Self.quickSwitchSelection)
                    .tutorialAnchor(SettingsSection.quickSwitch)
            }

            Section("Glances") {
                // Enabled first, then disabled; alphabetical by title within each
                // group — so the sidebar mirrors the enable grouping on the
                // Glances page but reads in a predictable A–Z order. The
                // Assistant is filtered out here — it lives in General above.
                let byTitle: (any GlancePlugin, any GlancePlugin) -> Bool = {
                    $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                }
                let sidebarPlugins = (registry.enabledPluginsInOrder.sorted(by: byTitle)
                    + registry.disabledPluginsInOrder.sorted(by: byTitle))
                    .filter { $0.id != Self.assistantPluginID }
                ForEach(sidebarPlugins, id: \.id) { plugin in
                    Label(plugin.title, systemImage: plugin.iconSystemName)
                        // Dim the disabled ones: their settings stay reachable,
                        // but the sidebar shows at a glance what's turned off.
                        .foregroundStyle(registry.isEnabled(plugin.id) ? .primary : .secondary)
                        .tag(plugin.id)
                }
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        let selection = registry.settingsSelection

        ScrollView {
            Group {
                if selection == Self.shortcutsSelection {
                    ShortcutsSettingsView()
                } else if selection == Self.quickSwitchSelection {
                    QuickSwitchSettingsView()
                } else if let plugin = registry.orderedPlugins.first(where: { $0.id == selection }) {
                    plugin.settingsSection()
                } else {
                    glancesPage
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(detailTitle)
    }

    private var detailTitle: String {
        switch registry.settingsSelection {
        case Self.shortcutsSelection: "Shortcuts"
        case Self.quickSwitchSelection: "Quick Switch"
        case let id?: registry.plugin(id: id)?.title ?? "Glances"
        case nil: "Glances"
        }
    }

    // MARK: - Glances page

    private var glancesPage: some View {
        VStack(alignment: .leading, spacing: 8) {
            updateRow

            Divider()

            menuPanelRow

            Divider()

            Text("Enable and reorder glances. Order controls the popover layout.")
                .font(.caption)
                .foregroundStyle(.secondary)

            // Two groups rather than one mixed list: the enabled order is the
            // only one that shows up in the popover, so dragging is worth doing
            // among those rows alone. A disabled glance keeps its slot behind the
            // scenes and returns to it when switched back on.
            List {
                if !registry.enabledPluginsInOrder.isEmpty {
                    Section("Enabled") {
                        ForEach(registry.enabledPluginsInOrder, id: \.id, content: row)
                            .onMove { offsets, dest in
                                registry.move(enabled: true, fromOffsets: offsets, toOffset: dest)
                                coordinator.reconcile()
                            }
                    }
                }

                if !registry.disabledPluginsInOrder.isEmpty {
                    Section("Disabled") {
                        ForEach(registry.disabledPluginsInOrder, id: \.id, content: row)
                            .onMove { offsets, dest in
                                registry.move(enabled: false, fromOffsets: offsets, toOffset: dest)
                            }
                    }
                }
            }
            .frame(minHeight: 300)

            // Re-runnable entry point for the guided tour, so it isn't a
            // first-launch-only thing the user can never see again.
            HStack {
                Spacer()
                Button {
                    tutorial.start()
                } label: {
                    Label("Show tutorial", systemImage: "sparkles")
                }
                .buttonStyle(.link)
            }
        }
    }

    private func row(_ plugin: any GlancePlugin) -> some View {
        HStack {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
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

    /// The Smart Panel toggle: the app-wide choice between the dynamic feed and
    /// the classic side-by-side layout for the menu-bar panel.
    private var menuPanelRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(
                get: { panelSettings.useSmartPanel },
                set: { panelSettings.useSmartPanel = $0 }
            )) {
                Text("Smart Panel")
            }
            .toggleStyle(.switch)

            Text("Automatically surface the glances that need attention — high memory, a big market move, unread GitHub notifications, and more. Turn off to show every enabled glance in a row instead. The Assistant and Notes stay pinned either way.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Checks GitHub Releases and downloads a newer build. The status text spells
    /// out the updater's phase, which the popover's icon-only button could only
    /// convey through its glyph and tooltip.
    private var updateRow: some View {
        HStack(spacing: 8) {
            Button("Check for Updates") {
                Task { await updater.checkAndDownload() }
            }
            .disabled(isUpdateBusy)

            // A determinate bar only once the server has told us how many bytes
            // are coming; a spinner covers the check and the sizeless download,
            // where there is no fraction to draw.
            if case .downloading(let progress?) = updater.phase {
                ProgressView(value: progress)
                    .controlSize(.small)
                    .frame(width: 90)
            } else if isUpdateBusy {
                ProgressView()
                    .controlSize(.small)
            }

            Text(updateStatus)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()
        }
    }

    private var isUpdateBusy: Bool {
        switch updater.phase {
        case .checking, .downloading, .installing, .relaunching: return true
        default: return false
        }
    }

    private var updateStatus: String {
        switch updater.phase {
        case .idle: return "Version \(updater.currentVersion)"
        case .checking: return "Checking for updates…"
        // No percentage when the response carried no Content-Length: the bytes
        // are arriving, but nothing here knows how many are left.
        case .downloading(let progress?): return "Downloading update… \(Int(progress * 100))%"
        case .downloading: return "Downloading update…"
        case .installing: return "Installing update…"
        case .relaunching: return "Update installed — relaunching…"
        case .upToDate: return "You're on the latest version (\(updater.currentVersion))"
        case .downloaded(let url): return "Downloaded to \(url.lastPathComponent)"
        case .updateAvailable(let r): return "Version \(r.version) available — opened the release page"
        case .failed(let msg): return "Update check failed: \(msg)"
        }
    }
}
