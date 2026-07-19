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
struct EmphasisSettingsView: View {
    @Environment(PluginRegistry.self) private var registry
    @Environment(GlanceEmphasisStore.self) private var store
    @Environment(MenuPanelSettings.self) private var panelSettings

    /// Pinned to the Smart Panel's footer, so they never enter the ranked feed
    /// and have no emphasis to set. Mirrors `SmartPanelView.pinnedIDs`.
    private static let pinnedIDs: Set<String> = [PluginRegistry.assistantPluginID, "notes"]

    /// Only enabled, unpinned glances can appear in the feed — those are the
    /// only rows where this control does anything.
    private var rows: [any GlancePlugin] {
        registry.enabledPluginsInOrder.filter { !Self.pinnedIDs.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Emphasis")
                .font(.headline)

            Text("Choose how much each glance is worth surfacing. High glances lead the Smart Panel and its summary whenever they have something to say; Low ones settle beneath the rest. This changes the order things are shown in — it never hides a glance.")
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

            if rows.isEmpty {
                ContentUnavailableView(
                    "No glances enabled",
                    systemImage: "square.grid.2x2",
                    description: Text("Turn some on from the Glances page to weight them here.")
                )
                .padding(.vertical, 24)
            } else {
                List(rows, id: \.id, rowContent: row)
                    .frame(minHeight: 280)
            }

            HStack {
                Spacer()
                Button("Reset to Normal") { store.resetAll() }
                    .buttonStyle(.link)
                    .disabled(!store.isCustomised)
            }

            Spacer(minLength: 0)
        }
    }

    private func row(_ plugin: any GlancePlugin) -> some View {
        HStack(spacing: 12) {
            Label(plugin.title, systemImage: plugin.iconSystemName)

            Spacer(minLength: 8)

            Picker("", selection: Binding(
                get: { store.emphasis(for: plugin.id) },
                set: { store.setEmphasis($0, for: plugin.id) }
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
        .help("How strongly \(plugin.title) is surfaced in the Smart Panel")
    }
}
