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

    /// Selection state for the unified Quick Switch window, shared between its nav
    /// bar and the shortcut. Long-lived so closing the window doesn't forget which
    /// tool was on screen — reopening resumes it.
    let quickSwitchModel = QuickSwitchModel()

    /// The unified Quick Switch window is stored in `windows` under this reserved
    /// key — not a real plugin id — so the auto-close, resign-key, and eyedropper
    /// suspend/resume paths, all keyed by id, treat it like any other tool window.
    private static let quickSwitchWindowID = "__glancekit.quickswitch__"

    /// One size for every tool in the Quick Switch window — the whole point of the
    /// unified window is that switching never resizes it. Content scrolls to fit.
    private static let quickSwitchWindowSize = CGSize(width: 440, height: 600)

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

    /// Opens the unified Quick Switch window, or steps it to the next tool if it's
    /// already up. This is what the Quick Switch shortcut calls: one window with a
    /// nav bar of every glance in `plugins`, its body swapped in place rather than
    /// a fresh window per glance.
    ///
    /// With the window already up, a press advances one tool around the ring —
    /// exactly what a nav-bar click does, so the shortcut and the bar stay in
    /// step. With it down, it reopens on the tool last shown (the model keeps the
    /// selection across closes), falling back to the first when that glance has
    /// dropped out of the ring.
    func quickSwitch(among plugins: [any GlancePlugin]) {
        guard !plugins.isEmpty else { return }
        // Same reasoning as `toggle`: an eyedrop in progress owns the screen, and
        // swapping the window's body underneath it would discard the pick.
        guard !isAutoCloseSuspended else { return }

        quickSwitchModel.setRing(plugins)

        if let window = windows[Self.quickSwitchWindowID], window.isVisible {
            quickSwitchModel.advance()
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        showQuickSwitchWindow()
    }

    /// Brings the unified Quick Switch window to front at the mouse, creating it
    /// on first use. The selection is already set on `quickSwitchModel`.
    private func showQuickSwitchWindow() {
        let id = Self.quickSwitchWindowID
        let window = windows[id] ?? makeQuickSwitchWindow()
        windows[id] = window
        lastShownPluginID = id

        window.setFrameOrigin(originNearMouse(for: window.frame.size))
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
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

    /// Bottom-left origin placing a window of `size` centered on the cursor, so
    /// the mouse lands at the window's middle. Kept wholly within the visible
    /// frame of the screen under the cursor, so it never opens half off an edge
    /// or under the menu bar.
    ///
    /// Screen coordinates are y-up with the origin at the bottom-left of the
    /// main display, so centering means offsetting the origin by half the size.
    private func originNearMouse(for size: NSSize) -> NSPoint {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
        // No screens at all is not a real state, but it is a representable one.
        guard let visible = screen?.visibleFrame else { return mouse }

        let x = mouse.x - size.width / 2
        let y = mouse.y - size.height / 2

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

    private func makeQuickSwitchWindow() -> NSWindow {
        let id = Self.quickSwitchWindowID
        let size = Self.quickSwitchWindowSize

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
            // No `.resizable`: the window keeps one size across every tool.
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Quick Switch"
        window.titlebarAppearsTransparent = true
        // Same reason as the per-glance window: a color glance's drag fields must
        // win over background dragging. The titlebar remains the way to drag.
        window.isMovableByWindowBackground = false
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: QuickSwitchWindowContent(model: quickSwitchModel) { [weak self] in
                self?.close(pluginID: id)
            }
        )

        let delegate = ToolWindowDelegate { [weak self] in
            self?.handleResignKey(pluginID: id)
        }
        window.delegate = delegate
        delegates[id] = delegate

        return window
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

            // A glance that owns its own layout (e.g. the chat, which pins its
            // composer to the bottom) fills the window; everything else scrolls
            // to fit its intrinsic height.
            if plugin.fillsToolWindow {
                plugin.popoverSection()
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView {
                    plugin.popoverSection()
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
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
