import AppKit
import Carbon.HIToolbox

/// A single global (system-wide) keyboard shortcut: one virtual key code plus a
/// set of modifier flags.
///
/// Key codes are hardware virtual key codes (`kVK_ANSI_Z` etc.), which is what
/// both `NSEvent.keyCode` and Carbon's `RegisterEventHotKey` speak, so a
/// recorded `NSEvent` maps straight through to a registration with no
/// translation. Modifiers are stored as an `NSEvent.ModifierFlags` raw value
/// masked to `deviceIndependentFlagsMask` — the device-specific left/right bits
/// would otherwise make two visually identical shortcuts compare unequal.
///
/// The display string is derived, never stored, so it follows the user's active
/// keyboard layout (⌥Z on QWERTY is ⌥W on AZERTY).
struct GlobalShortcut: Codable, Equatable, Hashable {
    /// Hardware virtual key code (`kVK_*`), as reported by `NSEvent.keyCode`.
    var keyCode: UInt16

    /// `NSEvent.ModifierFlags` raw value, masked to the device-independent bits.
    var modifierFlagsRawValue: UInt

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifierFlagsRawValue = modifiers
            .intersection(.deviceIndependentFlagsMask)
            .rawValue
    }

    var modifiers: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifierFlagsRawValue)
            .intersection(.deviceIndependentFlagsMask)
    }

    /// Modifier bit field in Carbon's vocabulary, for `RegisterEventHotKey`.
    var carbonModifiers: UInt32 {
        var result: UInt32 = 0
        if modifiers.contains(.command) { result |= UInt32(cmdKey) }
        if modifiers.contains(.option) { result |= UInt32(optionKey) }
        if modifiers.contains(.control) { result |= UInt32(controlKey) }
        if modifiers.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    /// A shortcut is only usable globally if it carries at least one of
    /// ⌘/⌥/⌃. Shift alone (or no modifier) would swallow ordinary typing in
    /// every other app, so the recorder rejects those.
    var hasRequiredModifier: Bool {
        !modifiers.intersection([.command, .option, .control]).isEmpty
    }

    /// Human-readable form in the conventional macOS order, e.g. "⌥⌘Z".
    var displayString: String {
        var result = ""
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.shift) { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }
        return result + Self.keyName(for: keyCode)
    }

    // MARK: - Key names

    /// Keys whose glyph can't come from the keyboard layout (they produce no
    /// character, or a non-printing one). Everything else is resolved live via
    /// `UCKeyTranslate` so the label matches the user's actual layout.
    private static let specialKeyNames: [UInt16: String] = [
        UInt16(kVK_Return): "↩",
        UInt16(kVK_Tab): "⇥",
        UInt16(kVK_Space): "Space",
        UInt16(kVK_Delete): "⌫",
        UInt16(kVK_ForwardDelete): "⌦",
        UInt16(kVK_Escape): "⎋",
        UInt16(kVK_Home): "↖",
        UInt16(kVK_End): "↘",
        UInt16(kVK_PageUp): "⇞",
        UInt16(kVK_PageDown): "⇟",
        UInt16(kVK_LeftArrow): "←",
        UInt16(kVK_RightArrow): "→",
        UInt16(kVK_UpArrow): "↑",
        UInt16(kVK_DownArrow): "↓",
        UInt16(kVK_ANSI_KeypadEnter): "⌤",
        UInt16(kVK_F1): "F1", UInt16(kVK_F2): "F2", UInt16(kVK_F3): "F3",
        UInt16(kVK_F4): "F4", UInt16(kVK_F5): "F5", UInt16(kVK_F6): "F6",
        UInt16(kVK_F7): "F7", UInt16(kVK_F8): "F8", UInt16(kVK_F9): "F9",
        UInt16(kVK_F10): "F10", UInt16(kVK_F11): "F11", UInt16(kVK_F12): "F12",
    ]

    static func keyName(for keyCode: UInt16) -> String {
        if let special = specialKeyNames[keyCode] { return special }
        if let character = layoutCharacter(for: keyCode) {
            return character.uppercased()
        }
        return "Key \(keyCode)"
    }

    /// Asks the current keyboard layout what unmodified character `keyCode`
    /// produces. Returns nil for dead keys and layouts that can't be resolved
    /// (e.g. an input source with no unicode layout data, such as some IMEs).
    private static func layoutCharacter(for keyCode: UInt16) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }

        let layoutData = Unmanaged<CFData>.fromOpaque(layoutPointer).takeUnretainedValue() as Data

        return layoutData.withUnsafeBytes { buffer -> String? in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress
            else { return nil }

            var deadKeyState: UInt32 = 0
            var characters = [UniChar](repeating: 0, count: 4)
            var length = 0

            let status = UCKeyTranslate(
                layout,
                keyCode,
                UInt16(kUCKeyActionDisplay),
                0, // no modifiers: we want the key's own glyph, not ⌥-composed output
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                characters.count,
                &length,
                &characters
            )

            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: characters, count: length)
        }
    }
}
