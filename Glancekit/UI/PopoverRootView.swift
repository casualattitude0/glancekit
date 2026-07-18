import SwiftUI

/// The popover window shown when the menu-bar item is clicked. Stacks each
/// enabled plugin's `popoverSection()` in the user's chosen order, with a
/// header row (refresh + settings + quit).
struct PopoverRootView: View {
    @Environment(PluginRegistry.self) private var registry
    @Environment(RefreshCoordinator.self) private var coordinator
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            header

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

    /// Open the Settings window, deep-linking to `pluginID` (nil = Glances tab).
    private func openSettings(for pluginID: String?) {
        registry.settingsSelection = pluginID
        // The menu-bar popover is the key window at click time; capture it now so
        // we can dismiss it once Settings is open.
        let popover = NSApp.keyWindow
        SettingsWindowPresenter.present { openSettings() }
        popover?.close()
    }

    private var header: some View {
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
                openSettings(for: nil)
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
}
