import SwiftUI
import AppKit
import Carbon.HIToolbox

/// The "Shortcuts" settings page: an "App" group for the two app-level actions
/// and a "Glances" group with one recorder row per registered glance.
struct ShortcutsSettingsView: View {
    @Environment(HotkeyCenter.self) private var hotkeys
    @Environment(PluginRegistry.self) private var registry

    var body: some View {
        SettingsPage(
            "Global Shortcuts",
            intro: "These work anywhere in macOS, even when Glancekit isn't frontmost. Most open a glance in its own window at the mouse. Press the shortcut again — or click outside the window, or press Close — to dismiss it."
        ) {
            ShortcutSectionGroup(title: "App", rows: appRows)
            ShortcutSectionGroup(title: "Glances", rows: glanceRows)

            SettingsHelp("Click a shortcut to record a new one; it needs at least one of ⌘, ⌥ or ⌃. Press ⎋ to cancel or ⌫ to clear.")
        }
    }

    private var appRows: [ShortcutRowInfo] {
        [ShortcutAction.quickSwitch, .settings, .openMenubar].compactMap { action in
            action.appDisplay.map { display in
                ShortcutRowInfo(
                    action: action,
                    title: display.title,
                    subtitle: display.subtitle,
                    iconSystemName: display.iconSystemName
                )
            }
        }
    }

    private var glanceRows: [ShortcutRowInfo] {
        registry.plugins.map { plugin in
            ShortcutRowInfo(
                action: .glance(pluginID: plugin.id),
                title: plugin.title,
                subtitle: nil,
                iconSystemName: plugin.iconSystemName
            )
        }
    }
}

/// The bits a shortcut row needs to render. App actions carry their own
/// display text; glance rows pull theirs from the `GlancePlugin`.
private struct ShortcutRowInfo: Identifiable {
    let action: ShortcutAction
    let title: String
    let subtitle: String?
    let iconSystemName: String

    var id: String { action.id }
}

/// One titled group of shortcut rows (e.g. "App" or "Glances").
private struct ShortcutSectionGroup: View {
    let title: String
    let rows: [ShortcutRowInfo]

    var body: some View {
        SettingsCard(title) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { Divider() }
                ShortcutRow(info: row)
            }
        }
    }
}

private struct ShortcutRow: View {
    let info: ShortcutRowInfo
    @Environment(HotkeyCenter.self) private var hotkeys

    var body: some View {
        let action = info.action
        let shortcut = hotkeys.shortcut(for: action)

        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(info.title, systemImage: info.iconSystemName)

                Spacer()

                ShortcutRecorderField(shortcut: shortcut) { newValue in
                    hotkeys.setShortcut(newValue, for: action)
                }

                Button {
                    hotkeys.resetToDefault(action)
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .help(resetHelp)
                .disabled(shortcut == action.defaultShortcut)
            }

            if let subtitle = info.subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if hotkeys.failedActions.contains(action) {
                Label(
                    "Another app is already using this shortcut. Pick a different one.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(GlanceStyle.warning)
            } else if shortcut == nil {
                Text("No shortcut set.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// "Reset to ⌥1" when there's a default, "Clear shortcut" when there isn't.
    private var resetHelp: String {
        if let def = info.action.defaultShortcut {
            "Reset to \(def.displayString)"
        } else {
            "Clear shortcut"
        }
    }
}

/// A click-to-record shortcut field.
///
/// While recording it installs a *local* `NSEvent` monitor, which sees key
/// events destined for this app's key window only — the Settings window has
/// focus during recording, so no global monitor (and no Accessibility prompt)
/// is needed. Returning `nil` from the monitor swallows the event so recording
/// ⌘S doesn't also trigger a Save somewhere.
private struct ShortcutRecorderField: View {
    let shortcut: GlobalShortcut?
    let onChange: (GlobalShortcut?) -> Void

    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            isRecording ? stopRecording() : startRecording()
        } label: {
            Text(label)
                .font(.body.monospaced())
                .frame(minWidth: 86)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isRecording ? Color.accentColor.opacity(0.18) : Color(nsColor: .controlColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(isRecording ? Color.accentColor : Color.secondary.opacity(0.4))
                )
                .foregroundStyle(isRecording ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
        .help(isRecording ? "Press the new shortcut" : "Click to record a shortcut")
        .onDisappear(perform: stopRecording)
    }

    private var label: String {
        if isRecording { return "Recording…" }
        return shortcut?.displayString ?? "Not set"
    }

    private func startRecording() {
        guard monitor == nil else { return }
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            handle(event)
            return nil // swallow: never let a recorded key reach the app
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }

    private func handle(_ event: NSEvent) {
        switch Int(event.keyCode) {
        case kVK_Escape:
            stopRecording()
            return
        case kVK_Delete, kVK_ForwardDelete:
            onChange(nil)
            stopRecording()
            return
        default:
            break
        }

        let candidate = GlobalShortcut(keyCode: event.keyCode, modifiers: event.modifierFlags)
        // Ignore bare keys and Shift-only combos: registering those globally
        // would swallow ordinary typing in every other app. Keep recording so
        // the user can just try again.
        guard candidate.hasRequiredModifier else { return }

        onChange(candidate)
        stopRecording()
    }
}
