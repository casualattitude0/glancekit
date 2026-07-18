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
            // having to be picked out of a mixed list. The glances that are off
            // over on the Glances page get a section of their own, with no
            // switch: a glance that's off can't cycle, so a toggle there would
            // be a dead control — they're listed only so you can see why they're
            // missing and know to re-enable them on the Glances page.
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

                if !disabledRows.isEmpty {
                    Section("Off in Glances") {
                        ForEach(disabledRows, id: \.id, content: disabledRowBody)
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

    /// A row in the Included / Not included sections: draggable, with a switch
    /// that adds or removes the glance from the ring. Only enabled glances land
    /// here — the disabled ones live in their own section (`disabledRowBody`).
    private func rowBody(_ row: Row) -> some View {
        HStack {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
            Label(row.title, systemImage: row.icon)
            Spacer()
            Toggle("", isOn: Binding(
                get: { row.isIncluded },
                set: { quickSwitch.setIncluded(row.id, $0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
        }
    }

    /// A row in the "Off in Glances" section: no drag handle and no switch,
    /// since a glance that's off can't be in the ring. It's dimmed and shown
    /// only so the glance's absence from the ring is explained.
    private func disabledRowBody(_ row: Row) -> some View {
        HStack {
            Label(row.title, systemImage: row.icon)
            Spacer()
            Text("Turn on in Glances to use")
                .font(.caption)
        }
        .foregroundStyle(.secondary)
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
        return "\(press) to open the next glance below; press again to keep going, and it wraps around to the top. Drag to set the order. Glances you've turned off on the Glances page are listed under “Off in Glances” — turn one back on there to make it available here."
    }

    /// Every glance in ring order, whether it's in the ring or not — the page
    /// has to show the excluded ones for there to be anything to switch on.
    /// This stays the full stored order: the two groups below are how it's
    /// displayed, not a second order to keep in step.
    private var rows: [Row] {
        quickSwitch.orderedIDs.compactMap { id in
            // The Assistant is a pinned, app-wide page, not a glance the ring
            // steps through — keep it out of the Quick Switch lists entirely.
            guard id != PluginRegistry.assistantPluginID else { return nil }
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

    /// Enabled glances that aren't in the ring — the ones a switch can add.
    /// Disabled glances are pulled out into `disabledRows` so they don't sit
    /// beside a switch they can't meaningfully use.
    private var excludedRows: [Row] { rows.filter { $0.isEnabled && !$0.isIncluded } }

    /// Glances turned off on the Glances page: shown for context, no switch.
    private var disabledRows: [Row] { rows.filter { !$0.isEnabled } }

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
