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
            #expect(!id.detail.isEmpty, "\(id.rawValue) has no detail")
            #expect(id.defaultShortcut.isValid, "\(id.rawValue) default invalid")
            #expect(
                !id.defaultShortcut.isModifierOnly,
                "\(id.rawValue) default is modifiers alone"
            )
        }
    }

    @Test
    func shortcutSectionsCoverTheCatalogExactlyOnce() {
        let grouped = NookShortcutSection.allCases.flatMap(\.shortcutIDs)

        #expect(grouped.count == NookShortcutID.allCases.count)
        #expect(Set(grouped) == Set(NookShortcutID.allCases))
        #expect(NookShortcutID.flagMoment.section == .recording)
        #expect(NookShortcutID.commandPalette.section == .libraryAndNotes)
        #expect(NookShortcutID.quickNoteDiscard.section == .quickNote)
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

    @Test
    func actionBindingsRejectModifiersWithoutAKey() throws {
        let store = ShortcutStore(defaults: freshDefaults())
        let modifierOnly = try #require(
            RecordedShortcut(modifiers: [.control, .option])
        )

        store.set(modifierOnly, for: .flagMoment)

        #expect(!store.isOverridden(.flagMoment))
        #expect(
            store.binding(for: .flagMoment)
                == NookShortcutID.flagMoment.defaultShortcut
        )
    }

    @Test
    func aPersistedModifierOnlyActionBindingIsDiscardedOnLoad() throws {
        let defaults = freshDefaults()
        let modifierOnly = try #require(
            RecordedShortcut(modifiers: [.command, .shift])
        )
        let encoded = try JSONEncoder().encode([
            NookShortcutID.newNote.rawValue: modifierOnly
        ])
        defaults.set(encoded, forKey: "nook.customShortcuts")

        let store = ShortcutStore(defaults: defaults)

        #expect(!store.isOverridden(.newNote))
        #expect(!store.hasOverrides)
        #expect(
            store.binding(for: .newNote)
                == NookShortcutID.newNote.defaultShortcut
        )
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
        #expect(!store.hasOverrides)
        store.set(
            shortcut(UInt32(kVK_ANSI_Y), [.command], display: "Y"),
            for: .startRecording
        )
        #expect(store.hasOverrides)
        store.resetAll()

        #expect(!store.hasOverrides)
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

    @Test
    func conflictsUsePhysicalKeyAndNormalizedModifiersNotDisplayCharacters() {
        let store = ShortcutStore(defaults: freshDefaults())
        let first = shortcut(
            UInt32(kVK_ANSI_B),
            [.command, .capsLock],
            display: "B"
        )
        let second = shortcut(
            UInt32(kVK_ANSI_B),
            [.command],
            display: "Different layout character"
        )

        store.set(first, for: .newNote)
        store.set(second, for: .saveNote)

        let conflicts = store.conflicts()
        #expect(conflicts.count == 1)
        #expect(Set(conflicts[0]) == [.newNote, .saveNote])
        #expect(ShortcutBindingKey(first) == ShortcutBindingKey(second))
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

/// These windows never become visible or key. Only the reported key state is
/// controlled, so tests exercise event ownership and native notifications
/// without taking focus from another app or changing any saved shortcut.
@MainActor
struct ShortcutRecorderSessionTests {
    private func hiddenWindow(isKey: Bool = true) -> ShortcutRecorderTestWindow {
        let window = ShortcutRecorderTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.reportsKey = isKey
        window.contentView = NSView(frame: window.contentLayoutRect)
        return window
    }

    private func event(
        in window: NSWindow?,
        type: NSEvent.EventType = .keyDown,
        keyCode: Int = kVK_ANSI_K,
        flags: NSEvent.ModifierFlags = [.command],
        characters: String = "k"
    ) throws -> ShortcutRecorderEvent {
        let event = try #require(NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: flags,
            timestamp: 0, windowNumber: window?.windowNumber ?? 0,
            context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false,
            keyCode: UInt16(keyCode)
        ))
        // A failed synthetic window association must not look like a passing
        // ownership guard that merely rejected a malformed test event.
        #expect(event.window === window)
        return ShortcutRecorderEvent(event: event)
    }

    @Test
    func recordingRequiresItsAttachedWindowToOwnTheKeyboard() {
        let window = hiddenWindow(isKey: false)
        let recorder = ShortcutRecorderSession()
        let anchor = ShortcutRecorderWindowTrackingView()
        anchor.recorder = recorder
        defer {
            anchor.removeFromSuperview()
            recorder.stopRecording()
            window.close()
        }
        var changes = 0

        recorder.startRecording(allowsModifierOnly: true) { _ in changes += 1 }
        #expect(!recorder.isRecording)
        window.contentView?.addSubview(anchor)
        recorder.startRecording(allowsModifierOnly: true) { _ in changes += 1 }
        #expect(!recorder.isRecording)

        window.reportsKey = true
        recorder.startRecording(allowsModifierOnly: true) { _ in changes += 1 }
        #expect(recorder.isRecording)
        #expect(changes == 0)
        #expect(!window.isVisible)
    }

    @Test(arguments: [false, true])
    func anotherWindowsTypingAndCommandsPassThroughWithoutChangingTheShortcut(
        hasModifier: Bool
    ) throws {
        let settings = hiddenWindow()
        let other = hiddenWindow()
        let recorder = ShortcutRecorderSession()
        defer {
            recorder.stopRecording()
            settings.close()
            other.close()
        }
        recorder.attach(to: settings)
        var changes: [DictationShortcut] = []
        recorder.startRecording(allowsModifierOnly: true) { changes.append($0) }

        #expect(!recorder.consume(try event(
            in: other, flags: hasModifier ? [.command] : []
        )))
        #expect(!recorder.consume(try event(in: nil)))
        #expect(recorder.isRecording)
        #expect(recorder.rejection == nil)
        #expect(changes.isEmpty)

        #expect(recorder.consume(try event(
            in: settings, keyCode: kVK_ANSI_W, flags: [.command], characters: "w"
        )))
        #expect(changes.count == 1)
        #expect(changes.first?.keyCode == UInt32(kVK_ANSI_W))
        #expect(changes.first?.flags == [.command])
        #expect(changes.first?.displayString == "⌘W")
        #expect(!recorder.isRecording)
        #expect(!recorder.consume(try event(in: settings)))
        #expect(changes.count == 1)
        #expect(!settings.isVisible && !other.isVisible)
    }

    @Test
    func escapeCancelsWithoutReplacingTheShortcutOrRecordingItsModifiers() throws {
        let window = hiddenWindow()
        let recorder = ShortcutRecorderSession()
        defer { recorder.stopRecording(); window.close() }
        recorder.attach(to: window)
        var changes: [DictationShortcut] = []
        recorder.startRecording(allowsModifierOnly: true) { changes.append($0) }

        #expect(recorder.consume(try event(in: window, flags: [])))
        #expect(recorder.rejection != nil)
        #expect(!recorder.consume(try event(in: window, type: .flagsChanged, flags: [.control])))
        #expect(recorder.consume(try event(in: window, keyCode: kVK_Escape, flags: [])))
        #expect(!recorder.isRecording)
        #expect(recorder.rejection == nil)
        #expect(changes.isEmpty)

        recorder.startRecording(allowsModifierOnly: true) { changes.append($0) }
        #expect(!recorder.consume(try event(in: window, type: .flagsChanged, flags: [])))
        #expect(recorder.isRecording)
        #expect(changes.isEmpty)
    }

    @Test
    func anUnmodifiedKeyKeepsTheRecorderOpenUntilAValidCombinationArrives() throws {
        let window = hiddenWindow()
        let recorder = ShortcutRecorderSession()
        defer { recorder.stopRecording(); window.close() }
        recorder.attach(to: window)
        var changes: [DictationShortcut] = []
        recorder.startRecording(allowsModifierOnly: false) { changes.append($0) }

        #expect(recorder.consume(try event(in: window, flags: [])))
        #expect(recorder.isRecording)
        #expect(recorder.rejection == "Add a modifier, such as ⌃ or ⌥.")
        #expect(changes.isEmpty)
        #expect(recorder.consume(try event(in: window, flags: [.control, .option])))
        #expect(!recorder.isRecording)
        #expect(recorder.rejection == nil)
        #expect(changes.first?.flags == [.control, .option])
    }

    @Test(arguments: [false, true])
    func modifierReleaseKeepsTheFullCombinationAndRespectsTheActionPolicy(
        allowsModifierOnly: Bool
    ) throws {
        let window = hiddenWindow()
        let recorder = ShortcutRecorderSession()
        defer { recorder.stopRecording(); window.close() }
        recorder.attach(to: window)
        var changes: [DictationShortcut] = []
        recorder.startRecording(allowsModifierOnly: allowsModifierOnly) { changes.append($0) }

        let combinations: [NSEvent.ModifierFlags] = [
            [.control], [.control, .option], [.option], []
        ]
        for flags in combinations {
            #expect(!recorder.consume(try event(in: window, type: .flagsChanged, flags: flags)))
        }
        if allowsModifierOnly {
            #expect(!recorder.isRecording)
            #expect(changes.count == 1)
            #expect(changes.first?.isModifierOnly == true)
            #expect(changes.first?.flags == [.control, .option])
        } else {
            #expect(recorder.isRecording)
            #expect(recorder.rejection == "Add a key to those modifiers.")
            #expect(changes.isEmpty)
            #expect(recorder.consume(try event(in: window)))
            #expect(changes.count == 1)
            #expect(changes.first?.isModifierOnly == false)
        }
    }

    @Test
    func anotherWindowsModifierChangesCannotContaminateTheRecordedCombination() throws {
        let window = hiddenWindow()
        let other = hiddenWindow()
        let recorder = ShortcutRecorderSession()
        defer { recorder.stopRecording(); window.close(); other.close() }
        recorder.attach(to: window)
        var changes: [DictationShortcut] = []
        recorder.startRecording(allowsModifierOnly: true) { changes.append($0) }

        #expect(!recorder.consume(try event(in: other, type: .flagsChanged, flags: [.command])))
        #expect(!recorder.consume(try event(in: window, type: .flagsChanged, flags: [.option])))
        #expect(!recorder.consume(try event(in: other, type: .flagsChanged, flags: [])))
        #expect(recorder.isRecording)
        #expect(changes.isEmpty)
        #expect(!recorder.consume(try event(in: window, type: .flagsChanged, flags: [])))
        #expect(changes.first?.flags == [.option])
        #expect(!recorder.isRecording)
    }

    @Test(arguments: ["resign-key", "deactivate", "close", "detach"])
    func leavingTheOwningWindowCancelsWithoutKeepingAHeldModifier(
        reason: String
    ) throws {
        let window = hiddenWindow()
        let reopened = hiddenWindow()
        let recorder = ShortcutRecorderSession()
        let anchor = ShortcutRecorderWindowTrackingView()
        anchor.recorder = recorder
        window.contentView?.addSubview(anchor)
        defer {
            anchor.removeFromSuperview()
            recorder.stopRecording()
            window.close()
            reopened.close()
        }
        var changes: [DictationShortcut] = []
        recorder.startRecording(allowsModifierOnly: true) { changes.append($0) }
        #expect(!recorder.consume(try event(in: window, type: .flagsChanged, flags: [.control])))
        let pendingEvent = try event(in: window)

        switch reason {
        case "resign-key":
            NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        case "deactivate":
            NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        case "close":
            window.close()
        default:
            anchor.removeFromSuperview()
        }
        #expect(!recorder.isRecording)
        #expect(recorder.rejection == nil)
        #expect(changes.isEmpty)
        #expect(!recorder.consume(pendingEvent))

        // Reattachment is explicit and does not reactivate or show a window.
        reopened.contentView?.addSubview(anchor)
        recorder.startRecording(allowsModifierOnly: true) { changes.append($0) }
        #expect(!recorder.consume(try event(in: reopened, type: .flagsChanged, flags: [])))
        #expect(recorder.isRecording)
        #expect(changes.isEmpty)
        #expect(!window.isVisible && !reopened.isVisible)
    }

    @Test
    func lossOfKeyOwnershipBeforeItsNotificationPassesTheEventThrough() throws {
        let window = hiddenWindow()
        let recorder = ShortcutRecorderSession()
        defer { recorder.stopRecording(); window.close() }
        recorder.attach(to: window)
        var changes = 0
        recorder.startRecording(allowsModifierOnly: false) { _ in changes += 1 }
        window.reportsKey = false

        #expect(!recorder.consume(try event(in: window)))
        #expect(!recorder.isRecording)
        #expect(changes == 0)
    }

    @Test
    func movingTheHostCancelsAndOldWindowNotificationsCannotCancelANewRecording() throws {
        let first = hiddenWindow()
        let second = hiddenWindow()
        let recorder = ShortcutRecorderSession()
        let anchor = ShortcutRecorderWindowTrackingView()
        anchor.recorder = recorder
        first.contentView?.addSubview(anchor)
        defer {
            anchor.removeFromSuperview()
            recorder.stopRecording()
            first.close()
            second.close()
        }
        var changes: [DictationShortcut] = []
        recorder.startRecording(allowsModifierOnly: false) { changes.append($0) }
        second.contentView?.addSubview(anchor)
        #expect(!recorder.isRecording)
        recorder.startRecording(allowsModifierOnly: false) { changes.append($0) }
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: first)
        #expect(recorder.isRecording)
        #expect(!recorder.consume(try event(in: first)))
        #expect(recorder.consume(try event(in: second)))
        #expect(changes.count == 1)
        #expect(changes.first?.displayString == "⌘K")
        #expect(!first.isVisible && !second.isVisible)
    }

    @Test
    func anActiveMonitorDoesNotKeepItsRecorderAliveAfterTheControlIsReleased() {
        let window = hiddenWindow()
        var recorder: ShortcutRecorderSession? = ShortcutRecorderSession()
        let reference = WeakShortcutRecorderReference(recorder)
        defer { window.close() }
        recorder?.attach(to: window)
        recorder?.startRecording(allowsModifierOnly: true) { _ in }
        #expect(recorder?.isRecording == true)

        recorder = nil

        #expect(reference.value == nil)
        #expect(!window.isVisible)
    }

    @Test
    func startingAnotherRecorderInTheSameWindowCancelsTheFirstAndClearsItsState() throws {
        let window = hiddenWindow()
        let first = ShortcutRecorderSession()
        let second = ShortcutRecorderSession()
        defer { first.stopRecording(); second.stopRecording(); window.close() }
        first.attach(to: window)
        second.attach(to: window)
        var firstChanges: [DictationShortcut] = []
        var secondChanges: [DictationShortcut] = []
        first.startRecording(allowsModifierOnly: true) { firstChanges.append($0) }
        #expect(first.consume(try event(in: window, flags: [])))
        #expect(first.rejection != nil)
        #expect(!first.consume(try event(in: window, type: .flagsChanged, flags: [.control])))

        second.startRecording(allowsModifierOnly: false) { secondChanges.append($0) }

        #expect(!first.isRecording)
        #expect(first.rejection == nil)
        #expect(second.isRecording)
        #expect(!first.consume(try event(in: window)))
        #expect(firstChanges.isEmpty)

        // A second cancellation of the old control cannot remove the new
        // control's ownership. Starting the first again must still cancel it.
        first.stopRecording()
        first.startRecording(allowsModifierOnly: true) { firstChanges.append($0) }
        #expect(!second.isRecording)
        #expect(first.isRecording)
        #expect(!first.consume(try event(in: window, type: .flagsChanged, flags: [])))
        #expect(firstChanges.isEmpty)
        #expect(secondChanges.isEmpty)
        #expect(first.consume(try event(in: window)))
        #expect(firstChanges.count == 1)
        #expect(!first.isRecording)
        #expect(!window.isVisible)
    }

    @Test
    func recorderOwnershipIsScopedToTheHostingWindow() throws {
        let firstWindow = hiddenWindow()
        let secondWindow = hiddenWindow()
        let first = ShortcutRecorderSession()
        let second = ShortcutRecorderSession()
        defer {
            first.stopRecording()
            second.stopRecording()
            firstWindow.close()
            secondWindow.close()
        }
        first.attach(to: firstWindow)
        second.attach(to: secondWindow)
        var firstChanges = 0
        var secondChanges = 0
        first.startRecording(allowsModifierOnly: false) { _ in firstChanges += 1 }
        second.startRecording(allowsModifierOnly: false) { _ in secondChanges += 1 }

        #expect(first.isRecording && second.isRecording)
        #expect(!first.consume(try event(in: secondWindow)))
        #expect(second.consume(try event(in: secondWindow)))
        #expect(first.isRecording && !second.isRecording)
        #expect(firstChanges == 0 && secondChanges == 1)
        #expect(first.consume(try event(in: firstWindow)))
        #expect(firstChanges == 1)
        #expect(!firstWindow.isVisible && !secondWindow.isVisible)
    }
}

@MainActor
private final class ShortcutRecorderTestWindow: NSWindow {
    var reportsKey = true
    override var isKeyWindow: Bool { reportsKey }
}

@MainActor
private final class WeakShortcutRecorderReference {
    weak var value: ShortcutRecorderSession?

    init(_ value: ShortcutRecorderSession?) {
        self.value = value
    }
}
