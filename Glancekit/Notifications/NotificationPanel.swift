import AppKit
import SwiftUI

/// On-screen notifications drawn by Glancekit itself, rather than asked of macOS.
///
/// This exists because the system route was exhausted first and every link in
/// it verified: permission authorized, alert style `banner`, Notification
/// Center enabled, the delegate installed at launch and demonstrably consulted,
/// unique identifiers, delivery reporting no error. Notifications still arrived
/// in Notification Center and no banner was ever drawn. The cause lies in the
/// system's presentation layer, past where an app can reach.
///
/// A window, by contrast, either orders front or it doesn't. No Focus mode,
/// summarisation feature, alert-style setting, coalescing rule or daemon state
/// sits between the notification and the screen. For anything time-critical that is
/// the difference between a mechanism and a hope.
@MainActor
enum NotificationPanel {

    private static var panels: [NotificationWindow] = []
    private static let maxVisible = 4
    private static let width: CGFloat = 340
    private static let margin: CGFloat = 14
    private static let gap: CGFloat = 8

    static func show(title: String,
                     body: String,
                     tint: Color,
                     corner: NotificationCorner,
                     dismissAfter: TimeInterval) {
        let window = NotificationWindow(title: title, body: body, tint: tint) { window in
            dismiss(window)
        }
        panels.insert(window, at: 0)
        if panels.count > maxVisible, let oldest = panels.popLast() { oldest.close() }
        layout(corner: corner)
        window.orderFrontRegardless()

        guard dismissAfter > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + dismissAfter) { [weak window] in
            guard let window else { return }
            dismiss(window)
        }
    }

    /// Close everything on screen — used when the user turns panels off.
    static func dismissAll() {
        panels.forEach { $0.close() }
        panels.removeAll()
    }

    private static func dismiss(_ window: NotificationWindow) {
        guard let index = panels.firstIndex(where: { $0 === window }) else { return }
        panels.remove(at: index)
        window.close()
        layout(corner: NotificationService.preferences.corner)
    }

    /// Stack in the chosen corner of whichever screen holds the pointer.
    ///
    /// The pointer's screen, not `NSScreen.main`: on a multi-display setup the
    /// "main" screen is wherever the menu bar lives, which need not be the one
    /// being looked at.
    private static func layout(corner: NotificationCorner) {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }

        var offset: CGFloat = 0
        for panel in panels {
            let height = panel.frame.height
            let x = corner.isRight ? visible.maxX - width - margin : visible.minX + margin
            let y = corner.isTop
                ? visible.maxY - margin - height - offset
                : visible.minY + margin + offset
            panel.setFrameOrigin(NSPoint(x: x, y: y))
            offset += height + gap
        }
    }
}

/// A borderless, non-activating floating window.
///
/// `.nonactivatingPanel` matters: a notification that steals focus while you
/// are typing an order into a broker is worse than none at all.
private final class NotificationWindow: NSPanel {
    private let onDismiss: (NotificationWindow) -> Void

    init(title: String, body: String, tint: Color, onDismiss: @escaping (NotificationWindow) -> Void) {
        self.onDismiss = onDismiss
        super.init(contentRect: NSRect(x: 0, y: 0, width: 340, height: 90),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)

        isFloatingPanel = true
        // ARC owns these through `panels`; the AppKit default would add a
        // release on `close()` and over-release the window.
        isReleasedWhenClosed = false
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        // Follow the user across Spaces and over full-screen apps — which is
        // exactly where a chart or a broker window tends to live.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let content = NotificationPanelView(title: title, message: body, tint: tint) { [weak self] in
            guard let self else { return }
            self.onDismiss(self)
        }
        let hosting = NSHostingView(rootView: content)
        hosting.frame.size = hosting.fittingSize
        contentView = hosting
        setContentSize(hosting.fittingSize)
    }

    /// Never take key: a notification must not interrupt typing.
    override var canBecomeKey: Bool { false }
}

private struct NotificationPanelView: View {
    let title: String
    let message: String
    let tint: Color
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(tint)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if !message.isEmpty {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(width: 340, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(tint.opacity(0.35), lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture(perform: onDismiss)
    }
}
