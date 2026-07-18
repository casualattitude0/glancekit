import SwiftUI
import AppKit

// ─────────────────────────────────────────────────────────────────────────────
// PRESENTATION
// ─────────────────────────────────────────────────────────────────────────────
// A tool window shows one glance's `popoverSection()` in a real, standalone
// window rather than in the MenuBarExtra popover, so a global shortcut can open
// it from any app.
//
// PLACEMENT: the window opens at the mouse, so it lands where the user is
// already looking rather than pulling their eye to a fixed spot. It is clamped
// to the visible frame of whichever screen holds the cursor, so it never opens
// half off an edge or under the menu bar.
//
// DISMISSAL: the window closes when it loses key status — i.e. when the user
// clicks outside it — mirroring the popover it stands in for. The Close button
// and a second press of the shortcut do the same thing explicitly.
//
// The catch is the eyedropper: `NSColorSampler`'s whole job is to click
// somewhere else on screen, which takes key away from this window and would
// otherwise slam it shut mid-pick (and discard the result the user just asked
// for). So auto-close is *suspended* around interactions that legitimately move
// focus off-window — see `suspendAutoClose()` / `resumeAutoClose()`, which
// `ColorsPlugin.pickColor()` brackets the sampler with.
//
// Windows are cached per plugin id and reused, preserving live state across
// repeated hotkey presses.
// ─────────────────────────────────────────────────────────────────────────────

/// Opens, reuses, and auto-dismisses one floating window per glance.
@MainActor
final class ToolWindowManager {
    static let shared = ToolWindowManager()

    private var windows: [String: NSWindow] = [:]
    /// `NSWindow.delegate` is weak, so the manager owns the delegates.
    private var delegates: [String: ToolWindowDelegate] = [:]
    private var lastShownPluginID: String?

    /// Nesting depth of `suspendAutoClose()` calls. A count rather than a flag
    /// so overlapping suspensions (two windows sampling in sequence) can't have
    /// the first one to finish re-arm auto-close under the other.
    private var autoCloseSuspensions = 0

    private init() {}

    var isAutoCloseSuspended: Bool { autoCloseSuspensions > 0 }

    /// Opens the glance's window at the mouse, or closes it if it's already up.
    /// This is what the global shortcut calls: the same key both summons and
    /// dismisses.
    func toggle(plugin: any GlancePlugin) {
        if let window = windows[plugin.id], window.isVisible {
            // An eyedrop in progress is exactly when the window is up but not
            // key. Closing here would kill the pick the user is mid-way through.
            guard !isAutoCloseSuspended else { return }
            window.close()
            return
        }
        show(plugin: plugin)
    }

    /// Shows the glance after the visible one in `plugins`, wrapping at the end.
    /// With no tool window up, opens the first. This is what the Quick Switch
    /// shortcut calls: each press advances one step around the ring.
    ///
    /// The window being stepped away from is closed rather than left behind, so
    /// a lap around the ring doesn't litter the screen with every glance in it.
    func quickSwitch(among plugins: [any GlancePlugin]) {
        guard !plugins.isEmpty else { return }
        // Same reasoning as `toggle`: an eyedrop in progress owns the screen,
        // and swapping windows underneath it would discard the pick.
        guard !isAutoCloseSuspended else { return }

        guard let current = visiblePluginID,
              let index = plugins.firstIndex(where: { $0.id == current })
        else {
            // Nothing up, or what's up isn't in the ring: start at the top.
            // A window that is up but out of the ring still has to be closed
            // here — it is floating, and once it resigns key to the window we
            // are about to show it will never fire `windowDidResignKey` again,
            // so nothing else would ever take it off the screen.
            if let current = visiblePluginID { close(pluginID: current) }
            show(plugin: plugins[0])
            return
        }

        close(pluginID: current)
        show(plugin: plugins[(index + 1) % plugins.count])
    }

    /// The glance whose tool window is currently on screen, if any. Only the
    /// most recently shown one counts — the others were closed on the way here.
    private var visiblePluginID: String? {
        guard let id = lastShownPluginID, windows[id]?.isVisible == true else { return nil }
        return id
    }

    /// Brings the given glance's tool window to front at the current mouse
    /// position, creating it on first use.
    func show(plugin: any GlancePlugin) {
        let window = windows[plugin.id] ?? makeWindow(for: plugin)
        windows[plugin.id] = window
        lastShownPluginID = plugin.id

        window.setFrameOrigin(originNearMouse(for: window.frame.size))

        // LSUIElement apps aren't activated by a hotkey press, so the window
        // would open behind the frontmost app without this.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Bottom-left origin placing a window of `size` just below-right of the
    /// cursor, kept wholly within the visible frame of the screen under it.
    ///
    /// Screen coordinates are y-up with the origin at the bottom-left of the
    /// main display, so "below the cursor" means subtracting the height.
    private func originNearMouse(for size: NSSize) -> NSPoint {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
        // No screens at all is not a real state, but it is a representable one.
        guard let visible = screen?.visibleFrame else { return mouse }

        // A small offset keeps the cursor off the titlebar, so the press that
        // opened the window doesn't leave the pointer poised to drag it.
        let offset: CGFloat = 12
        let x = mouse.x + offset
        let y = mouse.y - offset - size.height

        // `max` last: if the window is bigger than the screen, pinning the
        // left/bottom edge beats pinning the right/top and hiding the controls.
        return NSPoint(
            x: max(visible.minX, min(x, visible.maxX - size.width)),
            y: max(visible.minY, min(y, visible.maxY - size.height))
        )
    }

    func close(pluginID: String) {
        windows[pluginID]?.close()
    }

    /// Pauses click-outside dismissal for an interaction that intentionally
    /// takes focus off the window (the eyedropper). Always pair with
    /// `resumeAutoClose()`, including on the cancelled path.
    func suspendAutoClose() {
        autoCloseSuspensions += 1
    }

    /// Re-arms click-outside dismissal.
    ///
    /// Re-focuses the window the interaction belonged to: the sampler left it
    /// visible but not key, and a window that is already non-key will never
    /// fire `windowDidResignKey` again — so without this the next outside click
    /// would leave it stranded on screen forever.
    func resumeAutoClose() {
        autoCloseSuspensions = max(0, autoCloseSuspensions - 1)
        guard autoCloseSuspensions == 0 else { return }

        if let id = lastShownPluginID, let window = windows[id], window.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func makeWindow(for plugin: any GlancePlugin) -> NSWindow {
        let pluginID = plugin.id

        // Most glances open at the default; ones with a real editing surface can
        // ask for more room via `preferredToolWindowSize`.
        let size = plugin.preferredToolWindowSize ?? CGSize(width: 360, height: 520)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = plugin.title
        window.titlebarAppearsTransparent = true
        // Background dragging would swallow drags on the saturation/brightness
        // field and the hue slider — AppKit claims them before SwiftUI's
        // gesture sees them, so aiming at a color would move the window
        // instead. The titlebar remains the way to drag.
        window.isMovableByWindowBackground = false
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        // The manager holds the only strong reference; without this, closing
        // the window would deallocate it and reopening would crash.
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: ToolWindowContent(plugin: plugin, contentSize: size) { [weak self] in
                self?.close(pluginID: pluginID)
            }
        )

        let delegate = ToolWindowDelegate { [weak self] in
            self?.handleResignKey(pluginID: pluginID)
        }
        window.delegate = delegate
        delegates[pluginID] = delegate

        // Deliberately no `setFrameAutosaveName`: every open is positioned at
        // the mouse, so a restored frame would only fight that — and a frame
        // saved on a since-detached display would restore off-screen.
        return window
    }

    private func handleResignKey(pluginID: String) {
        guard !isAutoCloseSuspended else { return }

        // Resign fires *before* the new key window is installed, so decide on
        // the next runloop turn — otherwise `NSApp.keyWindow` is still stale
        // and every sibling-window click would read as an outside click.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                // Re-check: an interaction (e.g. the sampler) may have started
                // in the meantime, which is exactly what suspension protects.
                guard !self.isAutoCloseSuspended else { return }
                guard let window = self.windows[pluginID], window.isVisible else { return }
                guard !window.isKeyWindow else { return } // regained focus

                // Clicking from one tool window to another isn't "outside".
                if let key = NSApp.keyWindow, self.windows.values.contains(where: { $0 === key }) {
                    return
                }
                window.close()
            }
        }
    }
}

/// Forwards `windowDidResignKey` to the manager. `NSWindowDelegate` needs an
/// `NSObject`, which `ToolWindowManager` isn't.
private final class ToolWindowDelegate: NSObject, NSWindowDelegate {
    private let onResignKey: () -> Void

    init(onResignKey: @escaping () -> Void) {
        self.onResignKey = onResignKey
    }

    func windowDidResignKey(_ notification: Notification) {
        onResignKey()
    }
}

/// Chrome around a glance's popover section: a title row, a scrolling body, and
/// an explicit Close button.
private struct ToolWindowContent: View {
    let plugin: any GlancePlugin
    var contentSize: CGSize = CGSize(width: 360, height: 520)
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label(plugin.title, systemImage: plugin.iconSystemName)
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            Divider()

            ScrollView {
                plugin.popoverSection()
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            HStack {
                Spacer()
                Button("Close", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        // Leaves room for the transparent titlebar the content draws under.
        .padding(.top, 28)
        // Reserve ~100pt for the titlebar + close-button chrome around the body.
        .frame(minWidth: contentSize.width, minHeight: contentSize.height - 100)
    }
}
