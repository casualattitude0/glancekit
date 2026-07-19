import Foundation
import AppKit
import SwiftUI
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

    /// Set once the presenter is attached, for the Settings diagnostic.
    private(set) static var presenterInstalled = false
    /// Whatever the notification centre last complained about, if anything.
    private(set) static var lastDeliveryError: String?
    /// How many times the system has actually consulted our delegate.
    ///
    /// This is the one fact that separates "our delegate never runs" from "our
    /// delegate runs and asks for a banner that the system then declines to
    /// draw" — indistinguishable from outside, and they need opposite fixes.
    static var foregroundPresentCalls = 0

    /// Retained for the lifetime of the process — `UNUserNotificationCenter`
    /// holds its delegate weakly, and a delegate that deallocates is the same
    /// as never having set one.
    private static let presenter = ForegroundPresenter()

    /// Attach the foreground presenter and ask for permission, at launch.
    ///
    /// Timing is the whole point. `UNUserNotificationCenter` requires its
    /// delegate to be assigned *before the app finishes launching* — attaching
    /// it lazily on the first notification is too late, and the system has
    /// already decided how to present that notification by the time the
    /// assignment lands. That mistake is invisible: delivery still succeeds and
    /// the alert still reaches Notification Center, so the only symptom is the
    /// missing banner.
    static func prepare() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = presenter
        presenterInstalled = center.delegate === presenter
        if !didRequestAuthorization {
            didRequestAuthorization = true
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }

    }


    /// Fire an alert. Always beeps; additionally posts a banner when possible.
    /// `identifier` should be the alert's dedupe key so a repeat delivery
    /// replaces the previous banner instead of stacking a second one.
    static func notify(title: String, body: String, identifier: String,
                       tint: Color = .accentColor) {
        NSSound.beep()

        // Our own panel is the one that is actually guaranteed to appear. The
        // system notification below is posted as well, so the alert still lands
        // in Notification Center for later reference — it is the record, not
        // the delivery mechanism.
        Task { @MainActor in
            StockAlertPanel.show(title: title, body: body, tint: tint)
        }

        guard Bundle.main.bundleIdentifier != nil else { return }

        // Idempotent; the real attachment happened at launch.
        prepare()
        let center = UNUserNotificationCenter.current()

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = nil // we already beeped; avoid a double sound
        // Deliberately left at the default `.active`. `.timeSensitive` only
        // pierces Focus with an entitlement that needs a paid developer
        // account, so here it buys nothing while adding a variable to any
        // future "why didn't this appear" investigation.

        let request = UNNotificationRequest(
            identifier: "glancekit.stocks." + identifier,
            content: content,
            trigger: nil
        )
        center.add(request) { error in
            Task { @MainActor in
                lastDeliveryError = error?.localizedDescription
            }
        }
    }

    /// Fire two test notifications that separate the two delivery paths.
    ///
    /// A banner reaches the screen by one of two routes, and they fail for
    /// completely different reasons: while Glancekit is frontmost the decision
    /// belongs to our delegate, and while it is not it belongs to System
    /// Settings. Testing only the first (which is what pressing a button in our
    /// own window does) cannot distinguish "our code is wrong" from "the system
    /// is configured to stay quiet". So this sends one of each and lets the
    /// pair of outcomes name the culprit.
    static func runDiagnostic() {
        // A fresh id per press, and the old ones cleared first.
        //
        // Re-posting an identifier that is still sitting in Notification Center
        // *updates* that entry instead of delivering a new notification, and an
        // update draws no banner. A test button with a constant id therefore
        // works exactly once — every later press silently rewrites the same
        // row, which looks identical to the notification system being broken.
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [
            "glancekit.stocks.test-foreground", "glancekit.stocks.test-background"])

        let stamp = UUID().uuidString.prefix(8)
        notify(title: "測試 1/2 · 前景",
               body: "這則在 Glancekit 是最前景時發出。看得到橫幅=前景代理正常。",
               identifier: "test-foreground-\(stamp)")

        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = "測試 2/2 · 背景"
        content.body = "這則延遲 6 秒。看得到橫幅=系統設定正常。"
        content.sound = nil
        let request = UNNotificationRequest(
            identifier: "glancekit.stocks.test-background-\(stamp)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 6, repeats: false))
        UNUserNotificationCenter.current().add(request) { error in
            Task { @MainActor in
                if let error { lastDeliveryError = error.localizedDescription }
            }
        }
    }

    /// The system's own view of what it will do with our notifications.
    struct Diagnostics {
        var authorization = "?"
        var alertSetting = "?"
        var alertStyle = "?"
        var notificationCentre = "?"
        var presenterInstalled = false
        var presentCalls = 0
        var lastError: String?

        /// One line, copyable.
        var line: String {
            var text = "權限 \(authorization) · 提醒 \(alertSetting) · 樣式 \(alertStyle)"
            text += " · 通知中心 \(notificationCentre)"
            text += " · 代理 " + (presenterInstalled ? "已裝" : "未裝")
            text += " · willPresent \(presentCalls) 次"
            if let lastError { text += " · 錯誤 \(lastError)" }
            return text
        }
    }

    /// Just the permission status, for the plain-language hint in Settings.
    static func authorizationStatus() async -> UNAuthorizationStatus {
        guard Bundle.main.bundleIdentifier != nil else { return .denied }
        return await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
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
        // The decisive field: `.none` means the system will never draw a banner
        // no matter what the delegate asks for.
        switch settings.alertStyle {
        case .none: out.alertStyle = "NONE(不顯示)"
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

    /// Open the System Settings pane where the alert style lives.
    static func openSystemNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
        else { return }
        NSWorkspace.shared.open(url)
    }

}

/// Makes notifications appear on screen even while Glancekit is the active app.
///
/// Without a delegate, macOS assumes an app that is already in front has no
/// need to interrupt itself, and routes the notification straight to
/// Notification Center with no banner. For a menu-bar glance that assumption is
/// wrong in exactly the moments that matter: clicking the menu-bar item, opening
/// a tool window, or hitting Quick Switch all activate the app, so the alerts
/// most likely to be missed were the ones fired while you were looking at the
/// very glance that raised them. The test-notification button could never show a
/// banner at all, because pressing it guarantees the app is frontmost.
///
/// The delegate is process-wide, so this also fixes the Power and Timers
/// glances, which post notifications and set no delegate either. It lives here
/// only because a plugin may not edit `GlancekitApp` or `Core/`; the app
/// delegate would be its natural home if that rule is ever relaxed.
private final class ForegroundPresenter: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                    @escaping (UNNotificationPresentationOptions) -> Void) {
        StockAlerts.foregroundPresentCalls += 1
        // `.list` keeps it in Notification Center as well, so nothing is lost
        // if the banner is missed. Sound is omitted: the caller already beeped.
        completionHandler([.banner, .list])
    }
}
