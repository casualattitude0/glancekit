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
    @Bindable private var prefs = NotificationService.preferences
    @State private var diagnostics = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Notifications")
                .font(.headline)

            Text("How glances tell you something happened. The on-screen panel is drawn by Glancekit itself, so Focus, notification summaries and the system alert style can't suppress it.")
                .font(.caption)
                .foregroundStyle(.secondary)

            NotificationSettingsGroup(title: "On-screen panel") {
                NotificationSettingsRow(
                    title: "Show on-screen panel",
                    detail: "A floating panel in the corner of the screen holding the pointer."
                ) {
                    Toggle("", isOn: $prefs.showsPanel)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }

                if prefs.showsPanel {
                    Divider()
                    NotificationSettingsRow(title: "Position") {
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
                    NotificationSettingsRow(title: "Dismiss after") {
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

            NotificationSettingsGroup(title: "System notification") {
                NotificationSettingsRow(
                    title: "Also post a system notification",
                    detail: "Keeps a record in Notification Center. Whether macOS draws a banner for it is out of the app's hands."
                ) {
                    Toggle("", isOn: $prefs.postsSystemNotification)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }

                Divider()
                NotificationSettingsRow(title: "Play a sound") {
                    Toggle("", isOn: $prefs.playsSound)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }

            NotificationSettingsGroup(title: "Diagnostics") {
                NotificationSettingsRow(
                    title: "Test",
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

            Text("If style is not banner or alert, macOS will never draw a banner for Glancekit and that has to be changed in System Settings. The on-screen panel is unaffected by it.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Reset to defaults") { prefs.resetToDefaults() }

            Spacer(minLength: 0)
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

/// A titled, bordered group — the same container `ShortcutsSettingsView` uses,
/// so the two pages read as one design rather than two.
private struct NotificationSettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                content
            }
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.quaternary)
            )
        }
    }
}

/// One label-plus-control row, matching `ShortcutRow`'s metrics.
///
/// Controls share a 190pt trailing column so switches, pickers and buttons line
/// up down the page instead of each ending wherever its own content happens to.
private struct NotificationSettingsRow<Control: View>: View {
    /// Every control sits in a column of this width, so switches, pickers,
    /// sliders and buttons share one right edge down the page. Letting each
    /// control size itself is what made them ragged.
    static var controlColumn: CGFloat { 190 }

    let title: String
    var detail: String? = nil
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)

            control
                .frame(width: Self.controlColumn, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
