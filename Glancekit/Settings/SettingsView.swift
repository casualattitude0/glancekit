import SwiftUI

/// The Settings window: a sidebar of sections beside a detail pane, matching the
/// standard macOS settings layout (System Settings, Xcode, Mail).
///
/// The sidebar replaces an earlier custom chip bar — and, before that, a native
/// `TabView`, whose tab bar overflowed extra plugins into a `>>` dropdown. A
/// sidebar list scrolls vertically and stays legible however many plugins are
/// registered. The first group holds the app-wide pages ("Glances" — toggle +
/// drag-to-reorder, with the update check below — and "Shortcuts"); the second lists each plugin's own
/// `settingsSection()`.
struct SettingsView: View {
    @Environment(PluginRegistry.self) private var registry
    @Environment(RefreshCoordinator.self) private var coordinator
    @Environment(UpdateChecker.self) private var updater

    /// Sentinel `settingsSelection` values for the pages that aren't a plugin's
    /// own section. `registry.settingsSelection` uses `nil` for the Glances page
    /// (that's the deep-link contract the popover writes to), but a `List`
    /// selection reads `nil` as "nothing selected" — so the sidebar swaps in
    /// this sentinel and `sidebarSelection` maps it back at the boundary.
    private static let glancesSelection = "__glances__"
    private static let shortcutsSelection = "__shortcuts__"
    private static let quickSwitchSelection = "__quickswitch__"

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
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: sidebarSelection) {
            Section("General") {
                Label("Glances", systemImage: "square.grid.2x2")
                    .tag(Self.glancesSelection)
                Label("Shortcuts", systemImage: "command")
                    .tag(Self.shortcutsSelection)
                Label("Quick Switch", systemImage: "rectangle.stack")
                    .tag(Self.quickSwitchSelection)
            }

            Section("Glances") {
                ForEach(registry.orderedPlugins, id: \.id) { plugin in
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
            Text("Enable and reorder glances. Order controls the popover layout.")
                .font(.caption)
                .foregroundStyle(.secondary)

            List {
                ForEach(registry.orderedPlugins, id: \.id) { plugin in
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
                .onMove { offsets, dest in
                    registry.move(fromOffsets: offsets, toOffset: dest)
                    coordinator.reconcile()
                }
            }
            .frame(minHeight: 300)

            Divider()

            updateRow
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

            if isUpdateBusy {
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
        case .checking, .downloading: return true
        default: return false
        }
    }

    private var updateStatus: String {
        switch updater.phase {
        case .idle: return "Version \(updater.currentVersion)"
        case .checking: return "Checking for updates…"
        case .downloading: return "Downloading update…"
        case .upToDate: return "You're on the latest version (\(updater.currentVersion))"
        case .downloaded(let url): return "Downloaded to \(url.lastPathComponent)"
        case .updateAvailable(let r): return "Version \(r.version) available — opened the release page"
        case .failed(let msg): return "Update check failed: \(msg)"
        }
    }
}
