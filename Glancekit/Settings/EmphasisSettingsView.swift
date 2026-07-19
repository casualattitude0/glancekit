import SwiftUI

/// The "Emphasis" settings page: how much weight each glance carries in the
/// Smart Panel's ranked feed and the one-line brief above it.
///
/// The panel already ranks by what each glance reports about the machine. This
/// page adds what the *user* cares about on top: raising a glance pushes its
/// signals one urgency bucket up, lowering it pushes them one down (see
/// `GlanceSignal.Priority.emphasised(by:)`). That's enough to put the calendar
/// above the memory gauge for someone who lives in meetings, without either
/// glance knowing the other exists.
///
/// A segmented Low/Normal/High control per row rather than a slider or a number:
/// the ranking has four buckets, so anything finer would promise a precision the
/// feed can't honour — and three fixed stops stay readable down the column,
/// which a row of sliders wouldn't.
///
/// Laid out like the Quick Switch page, which answers the same question about
/// the same list of glances: the ones you can act on in one section, the ones
/// turned off on the Glances page in an "Off in Glances" section beneath, dimmed
/// and without a control. A glance that's off never reaches the feed, so a
/// weight on it would be a dead control — it's listed only so its absence is
/// explained rather than looking like the page forgot it.
struct EmphasisSettingsView: View {
    @Environment(PluginRegistry.self) private var registry
    @Environment(GlanceEmphasisStore.self) private var store
    @Environment(MenuPanelSettings.self) private var panelSettings

    /// Pinned to the Smart Panel's footer, so they never enter the ranked feed
    /// and have no emphasis to set. Mirrors `SmartPanelView.pinnedIDs`.
    private static let pinnedIDs: Set<String> = [PluginRegistry.assistantPluginID, "notes"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Emphasis")
                .font(.headline)

            Text(intro)
                .font(.caption)
                .foregroundStyle(.secondary)

            // The whole page only affects the Smart Panel; say so rather than
            // letting someone tune a column of controls that does nothing in the
            // layout they're actually using.
            if !panelSettings.useSmartPanel {
                Label(
                    "The Smart Panel is off, so the classic row shows every enabled glance in the order set on the Glances page. Emphasis applies once you turn it back on.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            List {
                if !enabledRows.isEmpty {
                    Section("Enabled") {
                        ForEach(enabledRows, id: \.id, content: rowBody)
                    }
                }

                if !disabledRows.isEmpty {
                    Section("Off in Glances") {
                        ForEach(disabledRows, id: \.id, content: disabledRowBody)
                    }
                }
            }
            .frame(minHeight: 280)

            HStack {
                Spacer()
                Button("Reset to Normal") { store.resetAll() }
                    .buttonStyle(.link)
                    .disabled(!store.isCustomised)
            }

            Spacer(minLength: 0)
        }
    }

    /// A row in the "Enabled" section: the glance and the weight it carries.
    private func rowBody(_ row: Row) -> some View {
        HStack(spacing: 12) {
            Label(row.title, systemImage: row.icon)

            Spacer(minLength: 8)

            Picker("", selection: Binding(
                get: { store.emphasis(for: row.id) },
                set: { store.setEmphasis($0, for: row.id) }
            )) {
                ForEach(GlanceEmphasis.allCases) { level in
                    Text(level.title).tag(level)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            // Fixed width so every row's control lines up into a column, however
            // long the glance titles are.
            .frame(width: 190)
        }
        .help("How strongly \(row.title) is surfaced in the Smart Panel")
    }

    /// A row in the "Off in Glances" section: no weight control, since a glance
    /// that's off never reaches the feed to be weighted. Dimmed and shown only
    /// so the glance's absence from the list above is explained.
    private func disabledRowBody(_ row: Row) -> some View {
        HStack {
            Label(row.title, systemImage: row.icon)
            Spacer()
            Text("Turn on in Glances to use")
                .font(.caption)
        }
        .foregroundStyle(.secondary)
    }

    private var intro: String {
        "Choose how much each glance is worth surfacing. High glances lead the Smart Panel and its summary whenever they have something to say; Low ones settle beneath the rest. This changes the order things are shown in — it never hides a glance. Glances you've turned off on the Glances page are listed under “Off in Glances” — turn one back on there to weight it here."
    }

    /// Every glance in the user's order, whether it's on or off — the page shows
    /// the off ones for context. The Assistant and Notes are pinned to the
    /// panel's footer rather than ranked into the feed, so they're dropped
    /// entirely: there's no ordering for a weight to affect.
    private var rows: [Row] {
        registry.orderedPlugins.compactMap { plugin in
            guard !Self.pinnedIDs.contains(plugin.id) else { return nil }
            return Row(
                id: plugin.id,
                title: plugin.title,
                icon: plugin.iconSystemName,
                isEnabled: registry.isEnabled(plugin.id)
            )
        }
    }

    private var enabledRows: [Row] { rows.filter(\.isEnabled) }

    /// Glances turned off on the Glances page: shown for context, no control.
    private var disabledRows: [Row] { rows.filter { !$0.isEnabled } }

    private struct Row {
        let id: String
        let title: String
        let icon: String
        /// Whether the glance is on at all, over on the Glances page.
        let isEnabled: Bool
    }
}
