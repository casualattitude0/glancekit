import SwiftUI
import AppKit
import Carbon.HIToolbox

/// The "Shortcuts" settings page: one recorder row per `ShortcutAction`.
struct ShortcutsSettingsView: View {
    @Environment(HotkeyCenter.self) private var hotkeys

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Global Shortcuts")
                .font(.headline)

            Text("These work anywhere in macOS, even when Glancekit isn't frontmost. They open a glance in its own window at the mouse. Press the shortcut again — or click outside the window, or press Close — to dismiss it.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                ForEach(Array(ShortcutAction.allCases.enumerated()), id: \.element.id) { index, action in
                    if index > 0 { Divider() }
                    ShortcutRow(action: action)
                }
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

            Text("Click a shortcut to record a new one; it needs at least one of ⌘, ⌥ or ⌃. Press ⎋ to cancel or ⌫ to clear.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)
        }
    }
}

private struct ShortcutRow: View {
    let action: ShortcutAction
    @Environment(HotkeyCenter.self) private var hotkeys

    var body: some View {
        let shortcut = hotkeys.shortcut(for: action)

        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(action.title, systemImage: action.iconSystemName)

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
                .help("Reset to \(action.defaultShortcut.displayString)")
                .disabled(shortcut == action.defaultShortcut)
            }

            if let subtitle = action.subtitle {
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
                .foregroundStyle(.orange)
            } else if shortcut == nil {
                Text("No shortcut set.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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
