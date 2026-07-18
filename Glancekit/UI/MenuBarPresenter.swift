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
