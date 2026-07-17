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
                        if !row.isEnabled {
                            Text("Off in Glances")
                                .font(.caption)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            // A glance that's off can't be in the ring, so the
                            // switch reads off however the row is stored. The
                            // stored value is left alone rather than cleared:
                            // re-enable the glance on the Glances page and the
                            // ring it was part of comes back intact.
                            get: { row.isEnabled && quickSwitch.isIncluded(row.id) },
                            set: { quickSwitch.setIncluded(row.id, $0) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }
                    // Grays the whole row and blocks the switch; `moveDisabled`
                    // covers what `disabled` doesn't reach — a List row stays
                    // draggable otherwise, and a row you can't switch but can
                    // drag is a strange half-inert thing.
                    .disabled(!row.isEnabled)
                    .moveDisabled(!row.isEnabled)
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
        return "\(press) to open the next glance below; press again to keep going, and it wraps around to the top. Drag to set the order. A glance you've turned off on the Glances page is grayed out here and can't take part — turn it back on there to use it."
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
