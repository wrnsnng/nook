import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

/// Every keyboard shortcut Nook owns that a user can rebind.
///
/// The raw cases are stable identifiers stored in preferences, never shown.
/// Each carries its shipped default, so a missing entry in storage means
/// "use the default" rather than "gone".
enum NookShortcutID: String, CaseIterable, Identifiable {
    /// System-wide, active while a recording runs.
    case flagMoment
    case startRecording
    case pauseResumeRecording
    case finishMeeting
    /// Library window.
    case commandPalette
    case newNote
    /// Note editor.
    case saveNote
    /// Quick note pad.
    case quickNoteChecklist
    case quickNoteDiscard

    var id: String { rawValue }

    var title: String {
        switch self {
        case .flagMoment: "Flag This Moment"
        case .startRecording: "Start Recording"
        case .pauseResumeRecording: "Pause or Resume Recording"
        case .finishMeeting: "Finish Meeting"
        case .commandPalette: "Search Commands"
        case .newNote: "New Note"
        case .saveNote: "Save Notes"
        case .quickNoteChecklist: "Start Checklist Line"
        case .quickNoteDiscard: "Discard Quick Note"
        }
    }

    /// Whether this shortcut must work while another application is
    /// frontmost. Global shortcuts register with the system rather than
    /// waiting inside Nook's menus.
    var isGlobal: Bool { self == .flagMoment }

    var defaultShortcut: DictationShortcut {
        switch self {
        case .flagMoment:
            DictationShortcut(
                keyCode: UInt32(kVK_ANSI_F),
                modifierFlags: NSEvent.ModifierFlags([.command, .option]).rawValue,
                displayCharacter: "F"
            )
        case .startRecording:
            DictationShortcut(
                keyCode: UInt32(kVK_ANSI_R),
                modifierFlags: NSEvent.ModifierFlags([.command, .shift]).rawValue,
                displayCharacter: "R"
            )
        case .pauseResumeRecording:
            DictationShortcut(
                keyCode: UInt32(kVK_ANSI_P),
                modifierFlags: NSEvent.ModifierFlags([.command, .shift]).rawValue,
                displayCharacter: "P"
            )
        case .finishMeeting:
            DictationShortcut(
                keyCode: UInt32(kVK_ANSI_Period),
                modifierFlags: NSEvent.ModifierFlags([.command, .shift]).rawValue,
                displayCharacter: "."
            )
        case .commandPalette:
            DictationShortcut(
                keyCode: UInt32(kVK_ANSI_K),
                modifierFlags: NSEvent.ModifierFlags([.command]).rawValue,
                displayCharacter: "K"
            )
        case .newNote:
            DictationShortcut(
                keyCode: UInt32(kVK_ANSI_N),
                modifierFlags: NSEvent.ModifierFlags([.command]).rawValue,
                displayCharacter: "N"
            )
        case .saveNote:
            DictationShortcut(
                keyCode: UInt32(kVK_ANSI_S),
                modifierFlags: NSEvent.ModifierFlags([.command]).rawValue,
                displayCharacter: "S"
            )
        case .quickNoteChecklist:
            DictationShortcut(
                keyCode: UInt32(kVK_ANSI_L),
                modifierFlags: NSEvent.ModifierFlags([.command, .shift]).rawValue,
                displayCharacter: "L"
            )
        case .quickNoteDiscard:
            DictationShortcut(
                keyCode: UInt32(kVK_Delete),
                modifierFlags: NSEvent.ModifierFlags([.command]).rawValue,
                displayCharacter: "⌫"
            )
        }
    }
}

/// A recorded combination bound to nothing in particular.
typealias RecordedShortcut = DictationShortcut

extension DictationShortcut {
    /// The Carbon-free equivalent SwiftUI menu items accept. Spelled out in
    /// full because Carbon's own `EventModifiers` shares the name.
    var eventModifiers: SwiftUI.EventModifiers {
        var result: SwiftUI.EventModifiers = []
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.shift) { result.insert(.shift) }
        return result
    }

    /// The key side of a SwiftUI `.keyboardShortcut`, derived from the virtual
    /// key code so special keys keep their proper glyphs.
    var keyEquivalent: KeyEquivalent {
        switch Int(keyCode) {
        case kVK_Space: return .space
        case kVK_Return: return .return
        case kVK_Tab: return .tab
        case kVK_Escape: return .escape
        case kVK_Delete: return .delete
        case kVK_LeftArrow: return .leftArrow
        case kVK_RightArrow: return .rightArrow
        case kVK_UpArrow: return .upArrow
        case kVK_DownArrow: return .downArrow
        case kVK_Home: return KeyEquivalent(Self.functionCharacter(0xF729))
        case kVK_End: return KeyEquivalent(Self.functionCharacter(0xF72B))
        case kVK_PageUp: return KeyEquivalent(Self.functionCharacter(0xF72C))
        case kVK_PageDown: return KeyEquivalent(Self.functionCharacter(0xF72D))
        case kVK_ForwardDelete: return KeyEquivalent(Self.functionCharacter(0xF728))
        default:
            // The F-key virtual codes are scattered, not consecutive, so the
            // lookup is a table rather than arithmetic.
            if let scalar = Self.functionKeyScalars[Int(keyCode)] {
                return KeyEquivalent(Self.functionCharacter(scalar))
            }
            let character = displayCharacter.first ?? " "
            return KeyEquivalent(Character(character.lowercased()))
        }
    }

    private static let functionKeyScalars: [Int: Int] = [
        kVK_F1: NSF1FunctionKey, kVK_F2: NSF2FunctionKey,
        kVK_F3: NSF3FunctionKey, kVK_F4: NSF4FunctionKey,
        kVK_F5: NSF5FunctionKey, kVK_F6: NSF6FunctionKey,
        kVK_F7: NSF7FunctionKey, kVK_F8: NSF8FunctionKey,
        kVK_F9: NSF9FunctionKey, kVK_F10: NSF10FunctionKey,
        kVK_F11: NSF11FunctionKey, kVK_F12: NSF12FunctionKey,
    ]

    private static func functionCharacter(_ scalar: Int) -> Character {
        Character(UnicodeScalar(scalar) ?? " ")
    }

    /// How the combination reads inside help text: "Shift-Command-L".
    ///
    /// Modifier order matches how macOS spells combinations out loud.
    var spokenDescription: String {
        var parts: [String] = []
        if flags.contains(.control) { parts.append("Control") }
        if flags.contains(.option) { parts.append("Option") }
        if flags.contains(.shift) { parts.append("Shift") }
        if flags.contains(.command) { parts.append("Command") }
        return (parts + [Self.spokenKeyName(displayCharacter)]).joined(
            separator: "-"
        )
    }

    private static func spokenKeyName(_ display: String) -> String {
        switch display {
        case " ": "Space"
        case "↩": "Return"
        case "⇥": "Tab"
        case "⌫": "Delete"
        case "⌦": "Forward Delete"
        case "←": "Left Arrow"
        case "→": "Right Arrow"
        case "↑": "Up Arrow"
        case "↓": "Down Arrow"
        case ".": "Period"
        case ",": "Comma"
        case "/": "Slash"
        default: display
        }
    }
}

/// Reads and writes the user's rebound shortcuts.
///
/// One store owns every rebinding so the same values reach the menu commands,
/// the in-window buttons, the global hotkey registration, and Settings, and so
/// changing one of them re-renders everywhere at once. A shortcut absent from
/// storage resolves to its shipped default; storing fewer entries than exist
/// in the catalog is therefore the steady state, and a catalog entry added in
/// a later release picks up its default automatically.
@MainActor
final class ShortcutStore: ObservableObject {
    static let shared = ShortcutStore()

    /// Overrides keyed by catalog identifier. Absent means default.
    @Published private(set) var overrides: [String: RecordedShortcut] = [:]

    private let defaults: UserDefaults
    private static let storageKey = "nook.customShortcuts"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode(
               [String: RecordedShortcut].self,
               from: data
           ) {
            overrides = decoded
        }
    }

    /// The combination currently bound to this action.
    func binding(for id: NookShortcutID) -> RecordedShortcut {
        overrides[id.rawValue] ?? id.defaultShortcut
    }

    /// Whether the user has moved this action off its shipped default.
    func isOverridden(_ id: NookShortcutID) -> Bool {
        overrides[id.rawValue] != nil
    }

    /// Rebinds an action, or clears its override when passed nil.
    func set(_ shortcut: RecordedShortcut?, for id: NookShortcutID) {
        if let shortcut {
            overrides[id.rawValue] = shortcut
        } else {
            overrides.removeValue(forKey: id.rawValue)
        }
        persist()
    }

    /// Clears every rebind, restoring all shipped defaults.
    func resetAll() {
        overrides = [:]
        persist()
    }

    /// Groups of actions currently sharing one combination.
    ///
    /// A collision between two menu items means whichever AppKit reaches
    /// first wins silently, so Settings shows these instead of pretending
    /// every combination can coexist.
    func conflicts() -> [[NookShortcutID]] {
        var byCombination: [String: [NookShortcutID]] = [:]
        for id in NookShortcutID.allCases {
            let binding = binding(for: id)
            byCombination[
                "\(binding.keyCode)-\(binding.modifierFlags)",
                default: []
            ].append(id)
        }
        return byCombination.values.filter { $0.count > 1 }
    }

    private func persist() {
        if overrides.isEmpty {
            defaults.removeObject(forKey: Self.storageKey)
            return
        }
        if let data = try? JSONEncoder().encode(overrides) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }
}
