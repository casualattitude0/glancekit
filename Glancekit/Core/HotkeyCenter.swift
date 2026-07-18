import AppKit
import Carbon.HIToolbox
import Observation

/// The things a global shortcut can trigger.
///
/// The two app-level actions (`quickSwitch`, `settings`) aren't tied to a
/// glance; `quickSwitch` steps through the ring of glances the user picked on
/// the Quick Switch page and `settings` fronts the Settings window. Every
/// registered glance also gets an action — `glance(pluginID:)` — that toggles
/// that glance's tool window (see `ToolWindowManager`). The glance set is
/// data-driven from the `PluginRegistry`, so a new plugin becomes assignable
/// automatically with no case to add here.
enum ShortcutAction: Hashable, Identifiable {
    case quickSwitch
    case settings
    /// Opens the glance with this `GlancePlugin.id` in its tool window.
    case glance(pluginID: String)

    var id: String { persistenceKey }

    /// Stable identity and `UserDefaults` key. Never change once shipped — for
    /// a glance it's the plugin id, which is what Colors/Notes shipped with, so
    /// existing bindings survive the move to this data-driven form.
    var persistenceKey: String {
        switch self {
        case .quickSwitch: "quickswitch"
        case .settings: "settings"
        case .glance(let pluginID): pluginID
        }
    }

    /// The `GlancePlugin.id` this action opens, or `nil` if it isn't tied to a
    /// single glance.
    var pluginID: String? {
        switch self {
        case .quickSwitch, .settings: nil
        case .glance(let pluginID): pluginID
        }
    }

    /// The shortcut this action ships with, or `nil` if it has none — which is
    /// the case for every glance except the two that shipped with a default.
    /// New glances start unbound; the user assigns their own.
    var defaultShortcut: GlobalShortcut? {
        switch self {
        case .quickSwitch:
            GlobalShortcut(keyCode: UInt16(kVK_Tab), modifiers: [.option])
        case .settings:
            GlobalShortcut(keyCode: UInt16(kVK_ANSI_Grave), modifiers: [.option])
        case .glance(let pluginID):
            Self.defaultGlanceShortcuts[pluginID]
        }
    }

    /// The glance defaults that predate the data-driven form. Everything not
    /// listed here defaults to unbound.
    private static let defaultGlanceShortcuts: [String: GlobalShortcut] = [
        "colors": GlobalShortcut(keyCode: UInt16(kVK_ANSI_1), modifiers: [.option]),
        "notes": GlobalShortcut(keyCode: UInt16(kVK_ANSI_2), modifiers: [.option]),
    ]

    /// Display metadata for the two app-level actions. `nil` for `.glance`,
    /// whose title and icon come from its `GlancePlugin`.
    var appDisplay: (title: String, subtitle: String?, iconSystemName: String)? {
        switch self {
        case .quickSwitch:
            ("Quick Switch", "Steps through the glances chosen on the Quick Switch page.", "rectangle.stack")
        case .settings:
            ("Open Settings", "Opens this window from any app. Press again, or ⎋, to close it.", "gearshape")
        case .glance:
            nil
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

    /// Every action that exists: the two app actions plus one per registered
    /// glance. Drives persistence and default-seeding (which need the full set,
    /// unlike `bindings`, which only holds actions that are actually bound).
    let allActions: [ShortcutAction]

    private let defaults: UserDefaults
    private static let bindingsKey = "glancekit.shortcuts.bindings"
    /// Marks an action as deliberately unbound (so it doesn't re-take its default).
    private static let clearedSentinel = "cleared"

    /// - Parameter glancePluginIDs: the id of every registered glance, in the
    ///   order the Shortcuts page should list them (normally `registry.plugins`).
    init(glancePluginIDs: [String], defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.allActions = [.quickSwitch, .settings] + glancePluginIDs.map { .glance(pluginID: $0) }
        bindings = Self.loadBindings(actions: allActions, from: defaults)
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
        for action in allActions {
            if let shortcut = bindings[action],
               let data = try? JSONEncoder().encode(shortcut) {
                stored[action.persistenceKey] = String(decoding: data, as: UTF8.self)
            } else {
                stored[action.persistenceKey] = Self.clearedSentinel
            }
        }
        defaults.set(stored, forKey: Self.bindingsKey)
    }

    private static func loadBindings(
        actions: [ShortcutAction],
        from defaults: UserDefaults
    ) -> [ShortcutAction: GlobalShortcut] {
        let stored = defaults.dictionary(forKey: bindingsKey) as? [String: String] ?? [:]
        var result: [ShortcutAction: GlobalShortcut] = [:]

        for action in actions {
            let raw = stored[action.persistenceKey]

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
