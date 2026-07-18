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

            // Split the same way the Glances page is, so the rows the shortcut
            // actually steps through read as a ring on their own rather than
            // having to be picked out of a mixed list. A grayed-out row sorts
            // below with the excluded ones — its switch reads off, so grouping
            // it as included would contradict the switch beside it.
            List {
                if !includedRows.isEmpty {
                    Section("Included") {
                        ForEach(includedRows, id: \.id, content: rowBody)
                            .onMove { offsets, destination in
                                move(includedRows, offsets, destination)
                            }
                    }
                }

                if !excludedRows.isEmpty {
                    Section("Not included") {
                        ForEach(excludedRows, id: \.id, content: rowBody)
                            .onMove { offsets, destination in
                                move(excludedRows, offsets, destination)
                            }
                    }
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

    private func rowBody(_ row: Row) -> some View {
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
                // A glance that's off can't be in the ring, so the switch reads
                // off however the row is stored. The stored value is left alone
                // rather than cleared: re-enable the glance on the Glances page
                // and the ring it was part of comes back intact.
                get: { row.isIncluded },
                set: { quickSwitch.setIncluded(row.id, $0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
        }
        // Grays the whole row and blocks the switch; `moveDisabled` covers what
        // `disabled` doesn't reach — a List row stays draggable otherwise, and a
        // row you can't switch but can drag is a strange half-inert thing.
        .disabled(!row.isEnabled)
        .moveDisabled(!row.isEnabled)
    }

    private func move(_ group: [Row], _ offsets: IndexSet, _ destination: Int) {
        quickSwitch.move(
            group.map(\.id),
            within: rows.map(\.id),
            fromOffsets: offsets,
            toOffset: destination
        )
    }

    private var intro: String {
        let key = hotkeys.shortcut(for: .quickSwitch)?.displayString
        let press = key.map { "Press \($0)" } ?? "The Quick Switch shortcut"
        return "\(press) to open the next glance below; press again to keep going, and it wraps around to the top. Drag to set the order. A glance you've turned off on the Glances page is grayed out here and can't take part — turn it back on there to use it."
    }

    /// Every glance in ring order, whether it's in the ring or not — the page
    /// has to show the excluded ones for there to be anything to switch on.
    /// This stays the full stored order: the two groups below are how it's
    /// displayed, not a second order to keep in step.
    private var rows: [Row] {
        quickSwitch.orderedIDs.compactMap { id in
            guard let plugin = registry.plugin(id: id) else { return nil }
            let isEnabled = registry.isEnabled(id)
            return Row(
                id: id,
                title: plugin.title,
                icon: plugin.iconSystemName,
                isEnabled: isEnabled,
                isIncluded: isEnabled && quickSwitch.isIncluded(id)
            )
        }
    }

    private var includedRows: [Row] { rows.filter(\.isIncluded) }
    private var excludedRows: [Row] { rows.filter { !$0.isIncluded } }

    private var ringCount: Int { quickSwitch.ring(in: registry).count }

    private struct Row {
        let id: String
        let title: String
        let icon: String
        /// Whether the glance is on at all, over on the Glances page.
        let isEnabled: Bool
        /// Whether it takes part in the ring right now — which a glance that's
        /// off never does, however it's stored.
        let isIncluded: Bool
    }
}
