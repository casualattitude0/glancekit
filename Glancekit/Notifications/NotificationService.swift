import Foundation
import AppKit
import SwiftUI
import UserNotifications

/// The app-wide way to notify the user.
///
/// Any glance calls `NotificationService.post(…)` and gets, subject to the
/// user's preferences: an on-screen panel Glancekit draws itself, a system
/// notification for the Notification Center record, and a sound. Nothing else
/// in the app should talk to `UNUserNotificationCenter` directly — the delegate
/// below is process-wide, so a second one would silently displace it.
///
/// Self-contained on purpose: everything under `Notifications/` can be lifted
/// into another branch or project as a unit. The only integration points are
/// `post(…)` from a caller and one entry in the Settings sidebar.
@MainActor
enum NotificationService {

    static let preferences = NotificationPreferences()

    private static var didPrepare = false
    private static var didRequestAuthorization = false

    /// Set once the presenter is attached, for the diagnostics panel.
    private(set) static var presenterInstalled = false
    /// How many times the system has actually consulted our delegate.
    ///
    /// The one fact that separates "our delegate never runs" from "our delegate
    /// runs and asks for a banner the system then declines to draw" — states
    /// that are indistinguishable from outside and need opposite fixes.
    private(set) static var foregroundPresentCalls = 0
    private(set) static var lastDeliveryError: String?

    /// Retained for the process lifetime — the notification centre holds its
    /// delegate weakly, and one that deallocates is the same as none.
    private static let presenter = ForegroundPresenter()

    // MARK: Lifecycle

    /// Attach the delegate and request permission.
    ///
    /// Call as early as possible: `UNUserNotificationCenter` wants its delegate
    /// assigned *before the app finishes launching*, and attaching it later
    /// means the system has already decided how to present the first
    /// notification. That mistake is invisible — delivery succeeds, no error is
    /// returned, the alert still reaches Notification Center, and the only
    /// symptom is a banner that never appears.
    ///
    /// Idempotent, so calling it from several places is fine.
    static func prepare() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        if !didPrepare {
            didPrepare = true
            center.delegate = presenter
            presenterInstalled = center.delegate === presenter
        }
        guard !didRequestAuthorization else { return }
        didRequestAuthorization = true
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // MARK: Posting

    /// Raise a notification.
    ///
    /// - Parameters:
    ///   - identifier: a stable key for this notification. Re-posting an identifier
    ///     that is still in Notification Center *updates* that row instead of
    ///     delivering a new one, and an update draws no banner — so callers
    ///     that want a fresh alert must vary it.
    ///   - source: which glance raised it; namespaces the identifier.
    ///   - sound: whether this event wants an audible cue at all. Pass `false`
    ///     from a caller that has already played its own — Timers lets the user
    ///     pick a finish sound, and adding the beep on top would be two noises
    ///     for one event. The user's `playsSound` preference still has the final
    ///     say when this is `true`.
    static func post(title: String,
                     body: String = "",
                     tint: Color = .accentColor,
                     identifier: String,
                     source: String,
                     sound: Bool = true) {
        if sound, preferences.playsSound { NSSound.beep() }

        if preferences.showsPanel {
            NotificationPanel.show(title: title, body: body, tint: tint,
                            corner: preferences.corner,
                            dismissAfter: preferences.panelDuration)
        }

        guard preferences.postsSystemNotification,
              Bundle.main.bundleIdentifier != nil else { return }
        prepare()

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        // Always silent: the beep above is the audible cue, and two noises for
        // one event is worse than either.
        content.sound = nil

        let request = UNNotificationRequest(
            identifier: "glancekit.\(source).\(identifier)",
            content: content,
            trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            Task { @MainActor in lastDeliveryError = error?.localizedDescription }
        }
    }

    /// A self-test that exercises both delivery paths.
    static func postTestNotification() {
        // A fresh id each time: the second press would otherwise only rewrite
        // the first notification's row and appear to do nothing.
        let unique = UUID().uuidString.prefix(8)
        post(title: "Glancekit test notification",
             body: "If both paths are working you'll see this panel and find a matching entry in Notification Center.",
             tint: .accentColor,
             identifier: "test-\(unique)",
             source: "alerts")
    }

    // MARK: Diagnostics

    /// The system's own account of what it will do with our notifications —
    /// which is not always what the Settings UI appears to say.
    struct Diagnostics {
        var authorization = "?"
        var alertSetting = "?"
        var alertStyle = "?"
        var notificationCentre = "?"
        var presenterInstalled = false
        var presentCalls = 0
        var lastError: String?

        var line: String {
            var text = "auth \(authorization) · alert \(alertSetting) · style \(alertStyle)"
            text += " · centre \(notificationCentre)"
            text += " · delegate " + (presenterInstalled ? "attached" : "missing")
            text += " · willPresent \(presentCalls)"
            if let error = lastError { text += " · error \(error)" }
            return text
        }
    }

    static func diagnostics() async -> Diagnostics {
        var out = Diagnostics()
        out.presenterInstalled = presenterInstalled
        out.presentCalls = foregroundPresentCalls
        out.lastError = lastDeliveryError
        guard Bundle.main.bundleIdentifier != nil else { return out }

        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized: out.authorization = "authorized"
        case .denied: out.authorization = "denied"
        case .notDetermined: out.authorization = "notDetermined"
        case .provisional: out.authorization = "provisional"
        case .ephemeral: out.authorization = "ephemeral"
        @unknown default: out.authorization = "unknown"
        }
        switch settings.alertSetting {
        case .enabled: out.alertSetting = "enabled"
        case .disabled: out.alertSetting = "DISABLED"
        case .notSupported: out.alertSetting = "notSupported"
        @unknown default: out.alertSetting = "unknown"
        }
        switch settings.alertStyle {
        case .none: out.alertStyle = "NONE"
        case .banner: out.alertStyle = "banner"
        case .alert: out.alertStyle = "alert"
        @unknown default: out.alertStyle = "unknown"
        }
        switch settings.notificationCenterSetting {
        case .enabled: out.notificationCentre = "enabled"
        case .disabled: out.notificationCentre = "disabled"
        case .notSupported: out.notificationCentre = "notSupported"
        @unknown default: out.notificationCentre = "unknown"
        }
        return out
    }

    static func openSystemNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
        else { return }
        NSWorkspace.shared.open(url)
    }

    fileprivate static func recordForegroundPresentation() {
        foregroundPresentCalls += 1
    }
}

/// Presents notifications on screen even while Glancekit is the active app.
///
/// Without a delegate, macOS assumes an app already in front has no need to
/// interrupt itself and routes the notification straight to Notification Center
/// with no banner. For a menu-bar app that assumption is wrong in exactly the
/// moments that matter: clicking the menu-bar item, opening a tool window or
/// hitting Quick Switch all activate the app, so the alerts most likely to be
/// missed were the ones raised while looking at the glance that raised them.
private final class ForegroundPresenter: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                    @escaping (UNNotificationPresentationOptions) -> Void) {
        Task { @MainActor in NotificationService.recordForegroundPresentation() }
        // `.list` keeps it in Notification Center too, so the record survives
        // even when the banner is missed. Sound is omitted: already beeped.
        completionHandler([.banner, .list])
    }
}
