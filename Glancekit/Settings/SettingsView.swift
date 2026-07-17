import SwiftUI

/// The Settings window. A horizontally-scrolling row of section chips replaces
/// the native `TabView` tab bar (which overflowed extra plugins into a `>>`
/// dropdown drawer). The first chip is a uniform "Glances" list (toggle +
/// drag-to-reorder); the rest are each plugin's own `settingsSection()`.
struct SettingsView: View {
    @Environment(PluginRegistry.self) private var registry
    @Environment(RefreshCoordinator.self) private var coordinator

    var body: some View {
        // `registry.settingsSelection` is the source of truth so the popover can
        // deep-link into a section: nil = Glances tab, else a plugin id.
        @Bindable var registry = registry
        let selection = registry.settingsSelection

        return VStack(spacing: 0) {
            chipBar

            Divider()

            ScrollView {
                Group {
                    if let plugin = registry.orderedPlugins.first(where: { $0.id == selection }) {
                        plugin.settingsSection()
                    } else {
                        glancesTab
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 460, height: 420)
    }

    // MARK: - Chip bar

    private var chipBar: some View {
        let selection = registry.settingsSelection
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(title: "Glances", systemImage: "square.grid.2x2", isSelected: selection == nil) {
                    registry.settingsSelection = nil
                }

                ForEach(registry.orderedPlugins, id: \.id) { plugin in
                    chip(title: plugin.title, systemImage: plugin.iconSystemName, isSelected: selection == plugin.id) {
                        registry.settingsSelection = plugin.id
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private func chip(title: String, systemImage: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.callout.weight(isSelected ? .semibold : .regular))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
                )
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    // MARK: - Glances list

    private var glancesTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Enable and reorder glances. Order controls the menu-bar rotation and popover layout.")
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
            .frame(minHeight: 280)
        }
    }
}
