import SwiftUI
import Observation

/// Where on screen notification panels stack.
enum NotificationCorner: String, CaseIterable, Identifiable {
    case topRight, topLeft, bottomRight, bottomLeft

    var id: String { rawValue }

    var title: String {
        switch self {
        case .topRight: return "Top right"
        case .topLeft: return "Top left"
        case .bottomRight: return "Bottom right"
        case .bottomLeft: return "Bottom left"
        }
    }

    var isTop: Bool { self == .topRight || self == .topLeft }
    var isRight: Bool { self == .topRight || self == .bottomRight }
}

/// User-facing settings for the notification module.
///
/// Persisted under `glancekit.notifications.*` and deliberately independent of any one
/// glance: the module is app-wide, so its preferences are too.
@MainActor
@Observable
final class NotificationPreferences {

    /// Draw our own on-screen panel. This is the delivery path that actually
    /// works; see `NotificationPanel` for why it exists at all.
    var showsPanel: Bool {
        didSet { defaults.set(showsPanel, forKey: Keys.showsPanel) }
    }

    /// Also post a system notification, so they accumulate in Notification
    /// Center as a history. Off by default only if the user finds it noisy —
    /// on, it costs nothing and keeps the record.
    var postsSystemNotification: Bool {
        didSet { defaults.set(postsSystemNotification, forKey: Keys.postsSystem) }
    }

    /// Seconds a panel stays up before dismissing itself.
    var panelDuration: Double {
        didSet { defaults.set(panelDuration, forKey: Keys.duration) }
    }

    var corner: NotificationCorner {
        didSet { defaults.set(corner.rawValue, forKey: Keys.corner) }
    }

    /// Audible cue. Separate from the system notification's own sound, which we
    /// always suppress to avoid two noises for one event.
    var playsSound: Bool {
        didSet { defaults.set(playsSound, forKey: Keys.sound) }
    }

    private let defaults: UserDefaults

    private enum Keys {
        static let showsPanel = "glancekit.notifications.showsPanel"
        static let postsSystem = "glancekit.notifications.postsSystemNotification"
        static let duration = "glancekit.notifications.panelDuration"
        static let corner = "glancekit.notifications.corner"
        static let sound = "glancekit.notifications.playsSound"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // `object(forKey:)` rather than `bool(forKey:)` so an unset preference
        // takes the intended default instead of `false`.
        showsPanel = defaults.object(forKey: Keys.showsPanel) as? Bool ?? true
        postsSystemNotification = defaults.object(forKey: Keys.postsSystem) as? Bool ?? true
        panelDuration = defaults.object(forKey: Keys.duration) as? Double ?? 12
        corner = NotificationCorner(rawValue: defaults.string(forKey: Keys.corner) ?? "") ?? .topRight
        playsSound = defaults.object(forKey: Keys.sound) as? Bool ?? true
    }

    func resetToDefaults() {
        showsPanel = true
        postsSystemNotification = true
        panelDuration = 12
        corner = .topRight
        playsSound = true
    }
}
