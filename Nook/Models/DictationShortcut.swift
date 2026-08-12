import AppKit
import Carbon.HIToolbox

/// A global keyboard shortcut, stored as the virtual key code plus modifiers.
///
/// The display character is captured when the user records the shortcut rather
/// than derived from the key code. Key codes are positions on the keyboard, not
/// letters: code 2 is "D" on a US layout and "E" on Dvorak. Storing what the
/// user actually pressed keeps Settings honest on non-US layouts without
/// dragging in Text Input Services.
struct DictationShortcut: Codable, Equatable, Sendable {
    var keyCode: UInt32
    /// Raw value of an `NSEvent.ModifierFlags` set, already masked to the
    /// device-independent flags Nook cares about.
    var modifierFlags: UInt
    var displayCharacter: String

    static let `default` = DictationShortcut(
        keyCode: UInt32(kVK_ANSI_D),
        modifierFlags: NSEvent.ModifierFlags([.control, .option]).rawValue,
        displayCharacter: "D"
    )

    /// Modifiers Nook stores. Notably excludes Caps Lock and the numeric-pad
    /// and function markers, which arrive set for ordinary keys on some
    /// keyboards and would otherwise make a recorded shortcut unmatchable.
    static let supportedModifiers: NSEvent.ModifierFlags = [
        .command, .control, .option, .shift
    ]

    var flags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifierFlags)
            .intersection(Self.supportedModifiers)
    }

    /// Modifiers held on their own, with no key — "hold ⌃⌥ and speak".
    ///
    /// These cannot go through `RegisterEventHotKey`, which needs a virtual key
    /// code, so they are watched as flag changes instead. That reads every
    /// modifier press system-wide and therefore needs Accessibility access,
    /// which dictation already requires in order to type anywhere.
    var isModifierOnly: Bool {
        displayCharacter.isEmpty && !flags.isEmpty
    }

    /// A shortcut with no modifier would swallow an ordinary keypress
    /// system-wide, so Nook refuses to register one.
    var isValid: Bool {
        !flags.isEmpty
    }

    /// The Carbon modifier mask `RegisterEventHotKey` expects.
    var carbonModifiers: UInt32 {
        var mask: UInt32 = 0
        if flags.contains(.command) { mask |= UInt32(cmdKey) }
        if flags.contains(.option) { mask |= UInt32(optionKey) }
        if flags.contains(.control) { mask |= UInt32(controlKey) }
        if flags.contains(.shift) { mask |= UInt32(shiftKey) }
        return mask
    }

    /// Menu-style rendering, in the order macOS uses everywhere else.
    var displayString: String {
        var result = ""
        if flags.contains(.control) { result += "⌃" }
        if flags.contains(.option) { result += "⌥" }
        if flags.contains(.shift) { result += "⇧" }
        if flags.contains(.command) { result += "⌘" }
        return result + displayCharacter
    }

    /// Builds a shortcut from a recorded key-down event, or `nil` if the event
    /// cannot serve as a global shortcut.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(Self.supportedModifiers)
        guard !flags.isEmpty else { return nil }

        let character = Self.displayCharacter(for: event)
        guard !character.isEmpty else { return nil }

        self.keyCode = UInt32(event.keyCode)
        self.modifierFlags = flags.rawValue
        self.displayCharacter = character
    }

    /// A shortcut made of modifiers alone.
    init?(modifiers: NSEvent.ModifierFlags) {
        let flags = modifiers.intersection(Self.supportedModifiers)
        guard !flags.isEmpty else { return nil }
        self.keyCode = 0
        self.modifierFlags = flags.rawValue
        self.displayCharacter = ""
    }

    init(keyCode: UInt32, modifierFlags: UInt, displayCharacter: String) {
        self.keyCode = keyCode
        self.modifierFlags = modifierFlags
        self.displayCharacter = displayCharacter
    }

    private static func displayCharacter(for event: NSEvent) -> String {
        if let named = namedKeys[Int(event.keyCode)] {
            return named
        }
        // Ignoring modifiers keeps ⌥D reading as "D" rather than "∂".
        let characters = event.charactersIgnoringModifiers ?? ""
        guard let scalar = characters.unicodeScalars.first,
              !CharacterSet.controlCharacters.contains(scalar)
        else {
            return ""
        }
        return characters.uppercased()
    }

    /// Keys whose `charactersIgnoringModifiers` is a control character or an
    /// unhelpful glyph, so they need a name of their own.
    private static let namedKeys: [Int: String] = [
        kVK_Space: "Space",
        kVK_Return: "↩",
        kVK_Tab: "⇥",
        kVK_Escape: "⎋",
        kVK_Delete: "⌫",
        kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←",
        kVK_RightArrow: "→",
        kVK_UpArrow: "↑",
        kVK_DownArrow: "↓",
        kVK_Home: "↖",
        kVK_End: "↘",
        kVK_PageUp: "⇞",
        kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
        kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
        kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12"
    ]
}
