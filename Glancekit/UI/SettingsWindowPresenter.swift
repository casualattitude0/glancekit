import AppKit

/// Opens and fronts the Settings window.
///
/// The raising dance is shared between the popover's gear button and the
/// Open Settings global shortcut, which reach the window from different places:
/// a view can use SwiftUI's `openSettings` action, a hotkey handler can't.
@MainActor
enum SettingsWindowPresenter {
    private static let windowIdentifier = "com_apple_SwiftUI_Settings_window"

    /// SwiftUI's `openSettings` environment action, captured from a long-lived
    /// view at launch (see `MenuBarLabelView`). The `showSettingsWindow:`
    /// selector `present()` falls back to only reaches a target once the
    /// `Settings` scene has already been instantiated — so the first ⌥-shortcut
    /// press did nothing until the user had opened Settings some other way. The
    /// SwiftUI action instantiates the scene itself, so it works on the very
    /// first press. `nil` only in the sliver before the label's `onAppear` runs.
    private static var openSettingsAction: (() -> Void)?

    /// Register SwiftUI's `openSettings` action so the hotkey path can open
    /// Settings as reliably as the popover's gear button does.
    static func registerOpenAction(_ action: @escaping () -> Void) {
        openSettingsAction = action
    }

    private static var window: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue == windowIdentifier }
    }

    /// Closes Settings if it's already frontmost, otherwise opens and fronts it.
    /// This is what the Open Settings shortcut calls, so a second press dismisses
    /// what the first press opened.
    ///
    /// Unlike a glance's tool window, Settings is an ordinary window that can sit
    /// buried behind other apps — so "visible" isn't enough to mean "the user can
    /// see it". Only close when it's genuinely in front; otherwise a press while
    /// it's buried would close a window the user never saw.
    static func toggle() {
        if let window, window.isVisible, window.isKeyWindow {
            window.close()
            return
        }
        present()
    }

    static func close() {
        window?.close()
    }

    /// Runs `open` — SwiftUI's `openSettings` action — with the activation and
    /// fronting an LSUIElement app needs around it.
    static func present(using open: () -> Void) {
        // LSUIElement apps aren't "active", so the Settings window opens behind
        // other apps (or not at all). Activate first, then open.
        NSApp.activate(ignoringOtherApps: true)
        open()
        // The menu-bar popover is a floating window that otherwise stays above
        // the Settings window; explicitly raise Settings to the front once it
        // exists (next runloop).
        DispatchQueue.main.async {
            guard let window else { return }
            window.level = .normal
            moveToActiveScreen(window)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }

    /// Brings the Settings window onto the screen the user is working on before
    /// it's shown. The `Settings` scene restores its last frame, so on a
    /// multi-display Mac it otherwise reappears on whatever screen it closed on —
    /// not the one you're on now. "Active" is the screen under the cursor, the
    /// same anchor the glance tool windows use.
    ///
    /// Only moves the window when it isn't already on that screen, so a window you
    /// positioned deliberately on the active screen keeps its spot; a wrong-screen
    /// one is re-centered on the active screen's visible area.
    private static func moveToActiveScreen(_ window: NSWindow) {
        let mouse = NSEvent.mouseLocation
        guard let target = NSScreen.screens.first(where: { $0.frame.contains(mouse) })
            ?? NSScreen.main else { return }

        // Already on the active screen: leave a deliberately-placed window put.
        if let current = window.screen, current.frame == target.frame { return }

        let visible = target.visibleFrame
        let size = window.frame.size
        // Centered, then clamped so an oversized window still shows its top-left
        // controls rather than opening half off the edge or under the menu bar.
        let origin = NSPoint(
            x: max(visible.minX, min(visible.midX - size.width / 2, visible.maxX - size.width)),
            y: max(visible.minY, min(visible.midY - size.height / 2, visible.maxY - size.height))
        )
        window.setFrameOrigin(origin)
    }

    /// Opens Settings from outside a SwiftUI view (the hotkey handler, the tour).
    /// Prefers the registered `openSettings` action, which reliably creates the
    /// `Settings` scene on the first press; the `showSettingsWindow:` selector is
    /// only a fallback for the brief window before that action is registered, and
    /// it silently does nothing until the scene already exists.
    static func present() {
        if let openSettingsAction {
            present(using: openSettingsAction)
        } else {
            present { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
        }
    }
}
