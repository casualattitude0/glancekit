import SwiftUI

/// The "Quick Switch" settings page: pick which glances the Quick Switch
/// shortcut steps through, and drag them into the order it steps in.
struct QuickSwitchSettingsView: View {
    @Environment(PluginRegistry.self) private var registry
    @Environment(QuickSwitchStore.self) private var quickSwitch
    @Environment(HotkeyCenter.self) private var hotkeys

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Quick Switch")
                .font(.headline)

            Text(intro)
                .font(.caption)
                .foregroundStyle(.secondary)

            List {
                ForEach(rows, id: \.id) { row in
                    HStack {
                        Image(systemName: "line.3.horizontal")
                            .foregroundStyle(.tertiary)
                        Label(row.title, systemImage: row.icon)
                            // Dim what ⌥⇥ will skip over, matching the sidebar.
                            .foregroundStyle(row.isEnabled ? .primary : .secondary)
                        if !row.isEnabled {
                            Text("Off")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { quickSwitch.isIncluded(row.id) },
                            set: { quickSwitch.setIncluded(row.id, $0) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .disabled(!row.isEnabled)
                    }
                }
                .onMove { offsets, destination in
                    quickSwitch.move(rows.map(\.id), fromOffsets: offsets, toOffset: destination)
                }
            }
            .frame(minHeight: 260)

            if ringCount < 2 {
                Label(
                    "Pick at least two glances for the shortcut to switch between.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
    }

    private var intro: String {
        let key = hotkeys.shortcut(for: .quickSwitch)?.displayString
        let press = key.map { "Press \($0)" } ?? "The Quick Switch shortcut"
        return "\(press) to open the next glance below; press again to keep going, and it wraps around to the top. Drag to set the order. Glances you've turned off on the Glances page are skipped."
    }

    /// Every glance in ring order, whether it's in the ring or not — the page
    /// has to show the excluded ones for there to be anything to switch on.
    private var rows: [Row] {
        quickSwitch.orderedIDs.compactMap { id in
            guard let plugin = registry.plugin(id: id) else { return nil }
            return Row(
                id: id,
                title: plugin.title,
                icon: plugin.iconSystemName,
                isEnabled: registry.isEnabled(id)
            )
        }
    }

    private var ringCount: Int { quickSwitch.ring(in: registry).count }

    private struct Row {
        let id: String
        let title: String
        let icon: String
        let isEnabled: Bool
    }
}
