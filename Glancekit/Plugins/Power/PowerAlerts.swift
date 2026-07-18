import Foundation
import AppKit
import UserNotifications

/// Best-effort, never-crashing user alerts for the Power glance.
///
/// The guaranteed path is an audible `NSSound.beep()`. On top of that we try to
/// post a real user notification via `UNUserNotificationCenter`, but only when
/// running inside a proper app bundle (calling `.current()` from a non-bundled
/// context can trap). Authorization is requested lazily and once; a denied or
/// unavailable notification centre degrades silently to just the beep.
enum PowerAlerts {

    private static var didRequestAuthorization = false

    /// Fire an alert. Always beeps; additionally posts a banner when possible.
    static func notify(title: String, body: String) {
        NSSound.beep()

        // A notification centre is only safe to touch inside a real app bundle.
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
            identifier: "glancekit.power." + UUID().uuidString,
            content: content,
            trigger: nil
        )
        center.add(request, withCompletionHandler: nil)
    }
}
