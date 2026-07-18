import SwiftUI

/// The popover window shown when the menu-bar item is clicked.
///
/// Two layouts share this window, chosen by the `Smart Panel` preference
/// (`MenuPanelSettings`, default on):
///   • `SmartPanelView` — the dynamic feed that surfaces only the glances that
///     need attention right now, with the Assistant and Notes pinned.
///   • `ClassicPanelView` — every enabled plugin's `popoverSection()` stacked
///     side by side in the user's chosen order.
struct PopoverRootView: View {
    @Environment(MenuPanelSettings.self) private var settings

    var body: some View {
        if settings.useSmartPanel {
            SmartPanelView()
        } else {
            ClassicPanelView()
        }
    }
}

// MARK: - Shared header

/// The header row shared by both panel layouts: title, refresh, settings, quit.
struct PanelHeader: View {
    @Environment(PluginRegistry.self) private var registry
    @Environment(RefreshCoordinator.self) private var coordinator
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack {
            Text("Glancekit")
                .font(.headline)
            Spacer()

            Button {
                coordinator.refreshAllNow()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh all")

            Button {
                openSettingsWindow()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings")
            .keyboardShortcut(",", modifiers: .command)

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.borderless)
            .help("Quit Glancekit")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// Open the Settings window on the Glances tab.
    private func openSettingsWindow() {
        registry.settingsSelection = nil
        // The menu-bar popover is the key window at click time; capture it now so
        // we can dismiss it once Settings is open.
        let popover = NSApp.keyWindow
        SettingsWindowPresenter.present { openSettings() }
        popover?.close()
    }
}

// MARK: - Classic layout

/// The original layout: stacks each enabled plugin's `popoverSection()` in the
/// user's chosen order, scrolling horizontally.
struct ClassicPanelView: View {
    @Environment(PluginRegistry.self) private var registry
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader()

            Divider()

            let plugins = registry.enabledPluginsInOrder
            if plugins.isEmpty {
                ContentUnavailableView(
                    "No glances enabled",
                    systemImage: "square.grid.2x2",
                    description: Text("Enable glances in Settings.")
                )
                .padding(.vertical, 24)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(plugins, id: \.id) { plugin in
                            VStack(alignment: .leading, spacing: 6) {
                                Label(plugin.title, systemImage: plugin.iconSystemName)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                PermissionGatedSection(plugin: plugin)
                                Spacer(minLength: 0)
                            }
                            .frame(width: 240, alignment: .leading)
                            .frame(maxHeight: .infinity, alignment: .top)
                            // Clicking a section's empty space deep-links into
                            // that plugin's Settings tab.
                            .contentShape(Rectangle())
                            .onTapGesture { openSettings(for: plugin.id) }

                            if plugin.id != plugins.last?.id {
                                Divider()
                                    .padding(.horizontal, 14)
                            }
                        }
                    }
                    .padding(14)
                }
                .frame(maxHeight: 460)
            }
        }
    }

    /// Open the Settings window, deep-linking to `pluginID`.
    private func openSettings(for pluginID: String?) {
        registry.settingsSelection = pluginID
        let popover = NSApp.keyWindow
        SettingsWindowPresenter.present { openSettings() }
        popover?.close()
    }
}
