import SwiftUI

/// The popover window shown when the menu-bar item is clicked. Stacks each
/// enabled plugin's `popoverSection()` in the user's chosen order, with a
/// header row (refresh + settings + quit).
struct PopoverRootView: View {
    @Environment(PluginRegistry.self) private var registry
    @Environment(RefreshCoordinator.self) private var coordinator
    @Environment(UpdateChecker.self) private var updater
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
        // LSUIElement apps aren't "active", so the Settings window opens behind
        // other apps (or not at all). Activate first, then open.
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
        popover?.close()
        // The menu-bar popover is a floating window that otherwise stays above
        // the Settings window; explicitly raise Settings to the front once it
        // exists (next runloop).
        DispatchQueue.main.async {
            guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "com_apple_SwiftUI_Settings_window" }) else { return }
            window.level = .normal
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }

    private var header: some View {
        HStack {
            Text("Glancekit")
                .font(.headline)
            Spacer()
            updateButton

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

    /// Checks GitHub Releases and downloads a newer build. The glyph reflects the
    /// updater's phase so the single button doubles as its own status indicator.
    @ViewBuilder
    private var updateButton: some View {
        Button {
            Task { await updater.checkAndDownload() }
        } label: {
            switch updater.phase {
            case .checking, .downloading:
                ProgressView()
                    .controlSize(.small)
            case .upToDate:
                Image(systemName: "checkmark.circle")
            case .downloaded:
                Image(systemName: "checkmark.circle.fill")
            case .updateAvailable:
                Image(systemName: "arrow.down.circle.fill")
            case .failed:
                Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
            case .idle:
                Image(systemName: "arrow.down.circle")
            }
        }
        .buttonStyle(.borderless)
        .disabled(isUpdateBusy)
        .help(updateHelp)
    }

    private var isUpdateBusy: Bool {
        switch updater.phase {
        case .checking, .downloading: return true
        default: return false
        }
    }

    private var updateHelp: String {
        switch updater.phase {
        case .idle: return "Download latest version"
        case .checking: return "Checking for updates…"
        case .downloading: return "Downloading update…"
        case .upToDate: return "You're on the latest version (\(updater.currentVersion))"
        case .downloaded(let url): return "Downloaded to \(url.lastPathComponent) — click to check again"
        case .updateAvailable(let r): return "Version \(r.version) available — opened the release page"
        case .failed(let msg): return "Update check failed: \(msg)"
        }
    }
}
