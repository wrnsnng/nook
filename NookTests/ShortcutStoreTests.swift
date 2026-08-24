import AppKit
import Carbon.HIToolbox
import SwiftUI
import Testing
@testable import Nook

/// One store owns every rebind, so a change lands in menus, buttons, and the
/// global hotkey registration at once. That only holds if the catalog is
/// complete, its defaults are distinct, storage round-trips, and shared
/// combinations are reported instead of silently resolved.
@MainActor
struct ShortcutStoreTests {

    private func freshDefaults() -> UserDefaults {
        let name = "NookShortcutTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func shortcut(
        _ keyCode: UInt32,
        _ modifiers: NSEvent.ModifierFlags,
        display: String
    ) -> RecordedShortcut {
        RecordedShortcut(
            keyCode: keyCode,
            modifierFlags: modifiers.rawValue,
            displayCharacter: display
        )
    }

    // MARK: Catalog

    @Test
    func everyActionHasAUsableDefault() {
        for id in NookShortcutID.allCases {
            #expect(!id.title.isEmpty, "\(id.rawValue) has no title")
            #expect(id.defaultShortcut.isValid, "\(id.rawValue) default invalid")
            #expect(
                !id.defaultShortcut.isModifierOnly,
                "\(id.rawValue) default is modifiers alone"
            )
        }
    }

    /// Two actions shipped on one combination would fight out of the box.
    @Test
    func shippedDefaultsAreAllDifferent() {
        let combinations = NookShortcutID.allCases.map { id in
            let binding = id.defaultShortcut
            return "\(binding.keyCode)-\(binding.modifierFlags)"
        }
        #expect(Set(combinations).count == NookShortcutID.allCases.count)
    }

    // MARK: Resolution

    @Test
    func missingOverrideResolvesToTheDefault() {
        let store = ShortcutStore(defaults: freshDefaults())
        #expect(
            store.binding(for: .commandPalette)
                == NookShortcutID.commandPalette.defaultShortcut
        )
        #expect(!store.isOverridden(.commandPalette))
    }

    @Test
    func anExplicitBindingWinsOverTheDefault() {
        let store = ShortcutStore(defaults: freshDefaults())
        let rebound = shortcut(UInt32(kVK_ANSI_Z), [.command], display: "Z")
        store.set(rebound, for: .newNote)

        #expect(store.binding(for: .newNote) == rebound)
        #expect(store.isOverridden(.newNote))
        #expect(store.binding(for: .saveNote) == NookShortcutID.saveNote.defaultShortcut)
    }

    @Test
    func clearingAnOverrideRestoresTheDefault() {
        let store = ShortcutStore(defaults: freshDefaults())
        let original = store.binding(for: .finishMeeting)
        store.set(
            shortcut(UInt32(kVK_ANSI_X), [.command, .shift], display: "X"),
            for: .finishMeeting
        )
        store.set(nil, for: .finishMeeting)

        #expect(store.binding(for: .finishMeeting) == original)
        #expect(!store.isOverridden(.finishMeeting))
    }

    // MARK: Persistence

    /// Settings and the menu system read different instances over an app's
    /// life (a relaunched process most of all), so what was written has to
    /// come back through any later store.
    @Test
    func rebindsSurviveANewStore() {
        let defaults = freshDefaults()
        let writer = ShortcutStore(defaults: defaults)
        let rebound = shortcut(
            UInt32(kVK_ANSI_J),
            [.control, .option],
            display: "J"
        )
        writer.set(rebound, for: .quickNoteChecklist)
        writer.set(
            shortcut(UInt32(kVK_ANSI_M), [.command], display: "M"),
            for: .newNote
        )

        let reader = ShortcutStore(defaults: defaults)
        #expect(reader.binding(for: .quickNoteChecklist) == rebound)
        #expect(reader.isOverridden(.newNote))
    }

    @Test
    func resettingEverythingForgetsEveryRebind() {
        let defaults = freshDefaults()
        let store = ShortcutStore(defaults: defaults)
        store.set(
            shortcut(UInt32(kVK_ANSI_Y), [.command], display: "Y"),
            for: .startRecording
        )
        store.resetAll()

        #expect(!store.isOverridden(.startRecording))
        let reader = ShortcutStore(defaults: defaults)
        #expect(!reader.isOverridden(.startRecording))
    }

    // MARK: Conflicts

    @Test
    func cleanBindingsReportNoConflicts() {
        let store = ShortcutStore(defaults: freshDefaults())
        #expect(shortcutsConflictsAreEmpty(store))
    }

    @Test
    func twoActionsOnOneCombinationAreNamedTogether() {
        let store = ShortcutStore(defaults: freshDefaults())
        let shared = shortcut(UInt32(kVK_ANSI_B), [.command], display: "B")
        store.set(shared, for: .newNote)
        store.set(shared, for: .saveNote)

        let conflicts = store.conflicts()
        #expect(conflicts.count == 1)
        #expect(Set(conflicts[0]) == [.newNote, .saveNote])
    }

    @Test
    func resolvingOneSideClearsTheConflict() {
        let store = ShortcutStore(defaults: freshDefaults())
        let shared = shortcut(UInt32(kVK_ANSI_V), [.command], display: "V")
        store.set(shared, for: .commandPalette)
        store.set(shared, for: .quickNoteDiscard)
        #expect(!shortcutsConflictsAreEmpty(store))

        store.set(nil, for: .quickNoteDiscard)
        #expect(shortcutsConflictsAreEmpty(store))
    }

    private func shortcutsConflictsAreEmpty(_ store: ShortcutStore) -> Bool {
        store.conflicts().isEmpty
    }

    // MARK: SwiftUI conversion

    @Test
    func plainLetterKeysMapThroughLowercased() {
        let binding = NookShortcutID.commandPalette.defaultShortcut
        #expect(binding.keyEquivalent == KeyEquivalent("k"))
        #expect(binding.eventModifiers == .command)
    }

    @Test
    func specialKeysKeepTheirEquivalents() {
        let space = shortcut(UInt32(kVK_Space), [.option], display: "Space")
        #expect(space.keyEquivalent == .space)
        #expect(space.spokenDescription == "Option-Space")

        let up = shortcut(UInt32(kVK_UpArrow), [.command], display: "↑")
        #expect(up.keyEquivalent == .upArrow)
        #expect(up.spokenDescription == "Command-Up Arrow")
    }

    @Test
    func functionKeysMapToTheirGlyphs() {
        let f5 = shortcut(UInt32(kVK_F5), [.command], display: "F5")
        #expect(
            f5.keyEquivalent == KeyEquivalent(
                Character(UnicodeScalar(NSF5FunctionKey)!)
            )
        )
        #expect(f5.spokenDescription == "Command-F5")
    }

    @Test
    func spokenDescriptionsReadInMacOSOrder() {
        let binding = shortcut(
            UInt32(kVK_ANSI_L),
            [.command, .shift],
            display: "L"
        )
        #expect(binding.spokenDescription == "Shift-Command-L")
    }
}
