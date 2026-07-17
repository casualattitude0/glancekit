import AppKit
import Carbon.HIToolbox
import Observation

/// The things a global shortcut can trigger. Most actions open one glance's
/// tool window (see `ToolWindowManager`); `quickSwitch` steps through the ring
/// of glances the user picked on the Quick Switch settings page.
///
/// Declaration order is the order the Shortcuts settings page lists them in.
///
/// The raw value is the persistence key — never change it once shipped.
enum ShortcutAction: String, CaseIterable, Identifiable {
    case quickSwitch = "quickswitch"
    case colors = "colors"
    case notes = "notes"
    case settings = "settings"

    var id: String { rawValue }

    /// The `GlancePlugin.id` this action opens, or `nil` if it isn't tied to a
    /// single glance. Distinct from `rawValue` (the persistence key) so the two
    /// can be renamed independently.
    var pluginID: String? {
        switch self {
        case .quickSwitch: nil
        case .colors: "colors"
        case .notes: "notes"
        case .settings: nil
        }
    }

    var title: String {
        switch self {
        case .quickSwitch: "Quick Switch"
        case .colors: "Open Colors"
        case .notes: "Open Notes"
        case .settings: "Open Settings"
        }
    }

    var subtitle: String? {
        switch self {
        case .quickSwitch: "Steps through the glances chosen on the Quick Switch page."
        case .colors: nil
        case .notes: "Opens the note field ready to type. ⌘↩ saves."
        case .settings: "Opens this window from any app. Press again, or ⎋, to close it."
        }
    }

    var iconSystemName: String {
        switch self {
        case .quickSwitch: "rectangle.stack"
        case .colors: "eyedropper"
        case .notes: "note.text"
        case .settings: "gearshape"
        }
    }

    var defaultShortcut: GlobalShortcut {
        switch self {
        case .quickSwitch:
            GlobalShortcut(keyCode: UInt16(kVK_Tab), modifiers: [.option])
        case .colors:
            GlobalShortcut(keyCode: UInt16(kVK_ANSI_1), modifiers: [.option])
        case .notes:
            GlobalShortcut(keyCode: UInt16(kVK_ANSI_2), modifiers: [.option])
        case .settings:
            GlobalShortcut(keyCode: UInt16(kVK_ANSI_Grave), modifiers: [.option])
        }
    }

}

/// Registers the app's global shortcuts with the system and dispatches presses.
///
/// Uses Carbon's `RegisterEventHotKey`, which — unlike an `NSEvent` global
/// monitor — needs no Accessibility permission and swallows the key press
/// rather than letting it fall through to the focused app. The API is
/// deprecated-in-spirit but has no modern replacement for system-wide hotkeys
/// outside the App Store sandbox.
///
/// Bindings are persisted per `ShortcutAction` in `UserDefaults`. A `nil`
/// binding means the user cleared it, which is distinct from "never set"
/// (the latter falls back to `defaultShortcut`).
@MainActor
@Observable
final class HotkeyCenter {

    /// Four-char code identifying this app's hotkeys to Carbon ('GLKT').
    private static let signature: OSType = 0x474C_4B54

    /// Current binding per action. Reading is cheap; writing re-registers.
    private(set) var bindings: [ShortcutAction: GlobalShortcut] = [:]

    /// Actions whose last registration attempt was rejected by the system —
    /// almost always because another app already owns that combination.
    private(set) var failedActions: Set<ShortcutAction> = []

    private var handlers: [ShortcutAction: () -> Void] = [:]
    private var hotKeyRefs: [ShortcutAction: EventHotKeyRef] = [:]
    /// Carbon hotkey id → action, for routing a press back to its handler.
    private var actionsByHotKeyID: [UInt32: ShortcutAction] = [:]
    private var nextHotKeyID: UInt32 = 1
    private var eventHandler: EventHandlerRef?

    private let defaults: UserDefaults
    private static let bindingsKey = "glancekit.shortcuts.bindings"
    /// Marks an action as deliberately unbound (so it doesn't re-take its default).
    private static let clearedSentinel = "cleared"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        bindings = Self.loadBindings(from: defaults)
    }

    // No `deinit` teardown: the center is owned by the `App` for the whole
    // process lifetime, and `deinit` is nonisolated so it cannot reach the
    // main-actor-isolated Carbon refs anyway. The OS reclaims the registrations
    // on exit. Rebinding unregisters through `register(_:)`.

    // MARK: - Wiring

    /// Attaches the action's handler and registers its current binding.
    /// Call once per action at startup.
    func setHandler(for action: ShortcutAction, _ handler: @escaping () -> Void) {
        handlers[action] = handler
        register(action)
    }

    func shortcut(for action: ShortcutAction) -> GlobalShortcut? {
        bindings[action]
    }

    /// Assigns a new binding (or `nil` to clear it), persists, and re-registers.
    ///
    /// A combination can only drive one action, so assigning one that another
    /// action already owns clears it there first — otherwise the second
    /// `RegisterEventHotKey` would fail and the shortcut would silently do the
    /// wrong thing.
    func setShortcut(_ shortcut: GlobalShortcut?, for action: ShortcutAction) {
        if let shortcut {
            for (other, existing) in bindings where other != action && existing == shortcut {
                bindings[other] = nil
                register(other)
            }
        }
        bindings[action] = shortcut
        register(action)
        persist()
    }

    func resetToDefault(_ action: ShortcutAction) {
        setShortcut(action.defaultShortcut, for: action)
    }

    /// The action currently bound to `shortcut`, ignoring `excluding`. Lets the
    /// settings UI warn about a clash before committing it.
    func conflictingAction(for shortcut: GlobalShortcut, excluding: ShortcutAction) -> ShortcutAction? {
        bindings.first { $0.key != excluding && $0.value == shortcut }?.key
    }

    // MARK: - Registration

    private func register(_ action: ShortcutAction) {
        unregister(action)
        failedActions.remove(action)

        guard let shortcut = bindings[action], shortcut.hasRequiredModifier else { return }

        installEventHandlerIfNeeded()

        let hotKeyID = nextHotKeyID
        nextHotKeyID += 1

        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(shortcut.keyCode),
            shortcut.carbonModifiers,
            EventHotKeyID(signature: Self.signature, id: hotKeyID),
            GetApplicationEventTarget(),
            0,
            &ref
        )

        guard status == noErr, let ref else {
            // Most often eventHotKeyExistsErr: another app owns the combo.
            failedActions.insert(action)
            return
        }

        hotKeyRefs[action] = ref
        actionsByHotKeyID[hotKeyID] = action
    }

    private func unregister(_ action: ShortcutAction) {
        if let ref = hotKeyRefs.removeValue(forKey: action) {
            UnregisterEventHotKey(ref)
        }
        actionsByHotKeyID = actionsByHotKeyID.filter { $0.value != action }
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        // C callback: no captures allowed, so `self` travels via userData.
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }

            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr, hotKeyID.signature == HotkeyCenter.signature else {
                return OSStatus(eventNotHandledErr)
            }

            let center = Unmanaged<HotkeyCenter>.fromOpaque(userData).takeUnretainedValue()
            let pressedID = hotKeyID.id
            // Carbon delivers on the main thread, but hop anyway to satisfy the
            // main-actor isolation the handlers (window/UI work) require.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { center.handlePress(hotKeyID: pressedID) }
            }
            return noErr
        }

        InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
    }

    private func handlePress(hotKeyID: UInt32) {
        guard let action = actionsByHotKeyID[hotKeyID] else { return }
        handlers[action]?()
    }

    // MARK: - Persistence

    private func persist() {
        var stored: [String: String] = [:]
        for action in ShortcutAction.allCases {
            if let shortcut = bindings[action],
               let data = try? JSONEncoder().encode(shortcut) {
                stored[action.rawValue] = String(decoding: data, as: UTF8.self)
            } else {
                stored[action.rawValue] = Self.clearedSentinel
            }
        }
        defaults.set(stored, forKey: Self.bindingsKey)
    }

    private static func loadBindings(from defaults: UserDefaults) -> [ShortcutAction: GlobalShortcut] {
        let stored = defaults.dictionary(forKey: bindingsKey) as? [String: String] ?? [:]
        var result: [ShortcutAction: GlobalShortcut] = [:]

        for action in ShortcutAction.allCases {
            let raw = stored[action.rawValue]

            guard let raw else {
                result[action] = action.defaultShortcut // never configured
                continue
            }
            guard raw != clearedSentinel,
                  let shortcut = try? JSONDecoder().decode(GlobalShortcut.self, from: Data(raw.utf8))
            else { continue } // deliberately unbound
            result[action] = shortcut
        }
        return result
    }
}
