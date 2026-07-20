import SwiftUI

/// The "Notifications" page in Settings — how every glance interrupts you, in
/// one place.
struct NotificationSettingsView: View {
    @Bindable private var prefs = NotificationService.preferences
    @State private var diagnostics = ""

    var body: some View {
        Form {
            Section {
                Toggle("Show on-screen panel", isOn: $prefs.showsPanel)
                Text("Drawn by Glancekit itself rather than handed to macOS, so Focus, notification summaries and the system alert style can't suppress it.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if prefs.showsPanel {
                    Picker("Position", selection: $prefs.corner) {
                        ForEach(NotificationCorner.allCases) { corner in
                            Text(corner.title).tag(corner)
                        }
                    }

                    HStack {
                        Text("Dismiss after")
                        Slider(value: $prefs.panelDuration, in: 4...30, step: 1)
                        Text("\(Int(prefs.panelDuration))s")
                            .font(.callout.monospacedDigit())
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            } header: {
                Text("On-screen panel")
            }

            Section {
                Toggle("Also post a system notification", isOn: $prefs.postsSystemNotification)
                Text("Keeps a record in Notification Center. Whether macOS draws a banner for it is out of the app's hands.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Play a sound", isOn: $prefs.playsSound)
            } header: {
                Text("System notification")
            }

            Section {
                HStack {
                    Button("Send test") { NotificationService.postTestNotification() }
                    Button("System Settings…") { NotificationService.openSystemNotificationSettings() }
                    Spacer()
                    Button("Refresh") { Task { await refresh() } }
                        .controlSize(.small)
                }

                // Read from `UNNotificationSettings` — what the system actually
                // intends, which has disagreed with the System Settings UI
                // before. `willPresent` counts how often the system consulted
                // our delegate: the only way to tell "never asked" from "asked
                // and declined".
                Text(diagnostics.isEmpty ? "—" : diagnostics)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("If style is not banner or alert, macOS will never draw a banner and that has to be changed in System Settings. The on-screen panel is unaffected.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Button("Reset to defaults") { prefs.resetToDefaults() }
            }
        }
        .formStyle(.grouped)
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
