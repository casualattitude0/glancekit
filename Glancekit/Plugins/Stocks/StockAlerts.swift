import Foundation
import AppKit
import UserNotifications

/// Best-effort, never-crashing user alerts for the Stocks glance.
///
/// Same shape as the Power glance's alerts — deliberately duplicated rather
/// than shared, because plugins don't import each other (plugin contract rule
/// 5). The guaranteed path is an audible beep; a real banner is attempted on
/// top of it, but only inside a proper app bundle, since `.current()` can trap
/// when called from a non-bundled context. A denied or unavailable notification
/// centre degrades silently to the beep.
enum StockAlerts {

    private static var didRequestAuthorization = false

    /// Fire an alert. Always beeps; additionally posts a banner when possible.
    /// `identifier` should be the alert's dedupe key so a repeat delivery
    /// replaces the previous banner instead of stacking a second one.
    static func notify(title: String, body: String, identifier: String) {
        NSSound.beep()

        guard Bundle.main.bundleIdentifier != nil else { return }

        let center = UNUserNotificationCenter.current()

        if !didRequestAuthorization {
            didRequestAuthorization = true
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = nil // we already beeped; avoid a double sound

        let request = UNNotificationRequest(
            identifier: "glancekit.stocks." + identifier,
            content: content,
            trigger: nil
        )
        center.add(request, withCompletionHandler: nil)
    }
}
