import SwiftUI

/// The "Notifications" settings page: how every glance interrupts you, in one
/// place.
///
/// Laid out to match `ShortcutsSettingsView` and `QuickSwitchSettingsView` — a
/// leading-aligned `VStack` of titled groups, no `Form`. The detail pane
/// already supplies the `ScrollView` and the 20pt inset (see
/// `SettingsView.detail`), so a `Form` here would nest its own scroller and
/// insets inside those and sit misaligned against every other page.
struct NotificationSettingsView: View {
    @Environment(PluginRegistry.self) private var registry
    @Bindable private var prefs = NotificationService.preferences
    @State private var diagnostics = ""

    /// Every glance, in the user's chosen order, each with its own mute switch.
    /// The pinned Assistant is left out for the same reason the enable/reorder
    /// lists drop it — it's an app-wide page, not a toggleable glance.
    private var notifyingPlugins: [any GlancePlugin] {
        registry.orderedPlugins.filter { $0.id != PluginRegistry.assistantPluginID }
    }

    var body: some View {
        SettingsPage(
            "Notifications",
            intro: "How glances tell you something happened. The on-screen panel is drawn by Glancekit itself, so Focus, notification summaries and the system alert style can't suppress it."
        ) {
            SettingsCard("On-screen panel") {
                SettingsToggleRow(
                    "Show on-screen panel",
                    detail: "A floating panel in the corner of the screen holding the pointer.",
                    isOn: $prefs.showsPanel
                )

                if prefs.showsPanel {
                    Divider()
                    SettingsRow("Position") {
                        Picker("", selection: $prefs.corner) {
                            ForEach(NotificationCorner.allCases) { corner in
                                Text(corner.title).tag(corner)
                            }
                        }
                        .labelsHidden()
                        // No maxWidth: filling the column centres the popup
                        // button inside it, which breaks the shared right edge
                        // every other control lines up on.
                        .fixedSize()
                    }

                    Divider()
                    SettingsRow("Dismiss after") {
                        HStack(spacing: 8) {
                            Slider(value: $prefs.panelDuration, in: 4...30, step: 1)
                                .frame(width: 140)
                            Text("\(Int(prefs.panelDuration))s")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 34, alignment: .trailing)
                        }
                    }
                }
            }

            SettingsCard("System notification") {
                SettingsToggleRow(
                    "Also post a system notification",
                    detail: "Keeps a record in Notification Center. Whether macOS draws a banner for it is out of the app's hands.",
                    isOn: $prefs.postsSystemNotification
                )

                Divider()
                SettingsToggleRow("Play a sound", isOn: $prefs.playsSound)
            }

            if !notifyingPlugins.isEmpty {
                SettingsCard("Per glance") {
                    ForEach(Array(notifyingPlugins.enumerated()), id: \.element.id) { index, plugin in
                        if index > 0 { Divider() }
                        SettingsToggleRow(
                            plugin.title,
                            isOn: Binding(
                                get: { prefs.isSourceEnabled(plugin.id) },
                                set: { prefs.setSourceEnabled(plugin.id, $0) }
                            )
                        )
                    }
                }
                SettingsHelp("Muting a glance silences it on both paths — no on-screen panel and no Notification Center entry. Some glances don't raise notifications yet, so their switch has nothing to silence today.")
            }

            SettingsCard("Diagnostics") {
                SettingsRow(
                    "Test",
                    detail: "Sends one notification through both paths."
                ) {
                    HStack(spacing: 8) {
                        Button("Send") { NotificationService.postTestNotification() }
                        Button("Refresh") { Task { await refresh() } }
                    }
                }

                Divider()
                // Read from `UNNotificationSettings` — what the system actually
                // intends, which has disagreed with the System Settings UI
                // before. `willPresent` counts how often the system consulted
                // our delegate: the only way to tell "never asked" from "asked
                // and declined".
                VStack(alignment: .leading, spacing: 4) {
                    Text(diagnostics.isEmpty ? "—" : diagnostics)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open System Settings…") {
                        NotificationService.openSystemNotificationSettings()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }

            SettingsHelp("If style is not banner or alert, macOS will never draw a banner for Glancekit and that has to be changed in System Settings. The on-screen panel is unaffected by it.")

            Button("Reset to defaults") { prefs.resetToDefaults() }
        }
        .onAppear { Task { await refresh() } }
        .onChange(of: prefs.showsPanel) { _, shows in
            // Turning panels off should clear what is already on screen, not
            // leave the last one stranded until its timer runs out.
            if !shows { NotificationPanel.dismissAll() }
        }
    }

    private func refresh() async {
        diagnostics = await NotificationService.diagnostics().line
    }
}
