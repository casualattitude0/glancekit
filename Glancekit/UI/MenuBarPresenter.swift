import AppKit

/// Opens the menu-bar popover from outside a click on the status item.
///
/// SwiftUI's `MenuBarExtra` owns an `NSStatusItem` but exposes no way to open
/// its window in code — so the Open Menu Bar global shortcut reaches the popover
/// the only way left: it finds the status-item's button and clicks it, exactly
/// as if the user had. `performClick` toggles the window, so a second press of
/// the shortcut dismisses what the first opened, matching the other shortcuts.
@MainActor
enum MenuBarPresenter {

    /// Opens the popover if it's closed, closes it if it's open.
    static func toggle() {
        guard let button = statusItemButton else { return }
        // LSUIElement apps aren't active off a hotkey, and the popover opens
        // behind the frontmost app without this — same dance as the tool windows.
        NSApp.activate(ignoringOtherApps: true)
        button.performClick(nil)
    }

    // MARK: - Right-click menu

    /// SwiftUI's `MenuBarExtra` owns the status button's left-click action (it
    /// opens the popover) and wires up nothing for the right button — so a
    /// right-click just falls through and does nothing. Rather than reassign the
    /// button's target/action (which would break the popover), we watch for a
    /// right-mouse-down over our own status-bar window and pop a small menu. The
    /// left-click popover path is untouched.
    private static var rightClickMonitor: Any?
    private static let menuActions = StatusMenuActions()

    /// Installs the right-click Settings/Quit menu. Idempotent, and safe to call
    /// before the status item exists — the button is resolved lazily at click
    /// time, not here.
    static func installRightClickMenu() {
        guard rightClickMonitor == nil else { return }
        rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { event in
            guard let button = statusItemButton, event.window === button.window else {
                return event
            }
            showRightClickMenu(from: button)
            return nil // consume: don't let it fall through as a dead click
        }
    }

    private static func showRightClickMenu(from button: NSStatusBarButton) {
        let menu = NSMenu()

        let settings = NSMenuItem(title: "Settings…",
                                  action: #selector(StatusMenuActions.openSettings),
                                  keyEquivalent: ",")
        settings.target = menuActions
        menu.addItem(settings)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Glancekit",
                              action: #selector(StatusMenuActions.quit),
                              keyEquivalent: "q")
        quit.target = menuActions
        menu.addItem(quit)

        // Pop up anchored under the button, like a standard status-item menu.
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: button.bounds.height + 4),
                   in: button)
    }

    /// The `MenuBarExtra`'s status-item button, dug out of the `NSStatusBarWindow`
    /// AppKit hosts it in. There's no public handle to it, so this walks the
    /// window list; it returns `nil` before the item exists (it's built lazily).
    private static var statusItemButton: NSStatusBarButton? {
        for window in NSApp.windows where window.className.contains("NSStatusBarWindow") {
            if let button = statusBarButton(in: window.contentView) { return button }
        }
        return nil
    }

    private static func statusBarButton(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton { return button }
        for subview in view.subviews {
            if let button = statusBarButton(in: subview) { return button }
        }
        return nil
    }
}

/// Target for the right-click menu items. `NSMenuItem` needs an `@objc` target,
/// which a SwiftUI view or an `enum` can't be — so the actions live on this tiny
/// object, forwarding to the same presenters the rest of the app uses.
@MainActor
private final class StatusMenuActions: NSObject {
    @objc func openSettings() {
        SettingsWindowPresenter.present()
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }
}
