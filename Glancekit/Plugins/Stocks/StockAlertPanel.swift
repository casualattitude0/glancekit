import AppKit
import SwiftUI

/// An on-screen alert Glancekit draws itself, instead of asking macOS to.
///
/// The notification route was exhausted first and every link in it verified:
/// permission authorized, alert style `banner`, Notification Center enabled,
/// the delegate installed at launch and demonstrably consulted, unique
/// identifiers, delivery reporting no error. Notifications still arrived in
/// Notification Center and no banner was ever drawn. At that point the cause
/// lies somewhere in the system's presentation layer, outside this app's
/// reach — and a price alert that *might* appear is not much better than one
/// that doesn't, because you can't tell the difference until after the trade.
///
/// So the banner is ours. A window either orders front or it doesn't; there is
/// no Focus mode, summarisation, alert-style setting, coalescing rule or
/// daemon state between the alert and the screen. The system notification is
/// still posted alongside it, which keeps the history in Notification Center
/// where it belongs — it just stops being the thing you depend on.
@MainActor
enum StockAlertPanel {

    private static var panels: [AlertWindow] = []
    private static let maxVisible = 4
    private static let width: CGFloat = 340
    private static let margin: CGFloat = 14

    /// Show an alert. Safe to call repeatedly; older ones slide down and the
    /// oldest is dropped once the stack is full.
    static func show(title: String, body: String, tint: Color, dismissAfter: TimeInterval = 12) {
        let window = AlertWindow(title: title, body: body, tint: tint) { window in
            dismiss(window)
        }
        panels.insert(window, at: 0)
        if panels.count > maxVisible, let last = panels.popLast() { last.close() }
        layout()
        window.orderFrontRegardless()

        DispatchQueue.main.asyncAfter(deadline: .now() + dismissAfter) { [weak window] in
            guard let window else { return }
            dismiss(window)
        }
    }

    private static func dismiss(_ window: AlertWindow) {
        guard let index = panels.firstIndex(where: { $0 === window }) else { return }
        panels.remove(at: index)
        window.close()
        layout()
    }

    /// Stack top-right of whichever screen holds the pointer — that is the one
    /// the user is looking at, which a fixed "main screen" need not be.
    private static func layout() {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }

        var y = frame.maxY - margin
        for panel in panels {
            let height = panel.frame.height
            panel.setFrameOrigin(NSPoint(x: frame.maxX - width - margin, y: y - height))
            y -= height + 8
        }
    }
}

/// A borderless, non-activating floating window.
///
/// `.nonactivatingPanel` matters: an alert that steals focus while you are
/// typing an order into a broker is worse than no alert.
private final class AlertWindow: NSPanel {
    private let onDismiss: (AlertWindow) -> Void

    init(title: String, body: String, tint: Color, onDismiss: @escaping (AlertWindow) -> Void) {
        self.onDismiss = onDismiss
        super.init(contentRect: NSRect(x: 0, y: 0, width: 340, height: 90),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)

        isFloatingPanel = true
        level = .statusBar               // above normal windows, below the menu bar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        ignoresMouseEvents = false
        // Follow the user across Spaces and over full-screen apps, which is
        // exactly where a chart or a broker window tends to live.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let content = StockAlertPanelView(title: title, message: body, tint: tint) { [weak self] in
            guard let self else { return }
            self.onDismiss(self)
        }
        let hosting = NSHostingView(rootView: content)
        hosting.frame.size = hosting.fittingSize
        contentView = hosting
        setContentSize(hosting.fittingSize)
    }

    // Borderless panels refuse key by default; allow it so the click-to-dismiss
    // and text selection behave, without ever activating the app.
    override var canBecomeKey: Bool { false }
}

private struct StockAlertPanelView: View {
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
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
