import AppKit
import Carbon.HIToolbox
import Testing
@testable import Nook

struct DictationShortcutTests {
    @Test
    func rendersModifiersInTheOrderMacOSUses() {
        let shortcut = DictationShortcut(
            keyCode: UInt32(kVK_ANSI_D),
            modifierFlags: NSEvent.ModifierFlags(
                [.command, .control, .option, .shift]
            ).rawValue,
            displayCharacter: "D"
        )

        #expect(shortcut.displayString == "⌃⌥⇧⌘D")
    }

    @Test
    func theDefaultIsControlOptionD() {
        #expect(DictationShortcut.default.displayString == "⌃⌥D")
        #expect(DictationShortcut.default.isValid)
    }

    @Test
    func mapsModifiersOntoCarbonsMask() {
        #expect(
            DictationShortcut.default.carbonModifiers
                == UInt32(controlKey) | UInt32(optionKey)
        )
    }

    /// A shortcut with no modifier would swallow an ordinary keypress
    /// everywhere on the system.
    @Test
    func aBareKeyIsNotAValidShortcut() {
        let bare = DictationShortcut(
            keyCode: UInt32(kVK_ANSI_D),
            modifierFlags: 0,
            displayCharacter: "D"
        )

        #expect(!bare.isValid)
    }

    /// Caps Lock and the function-key marker arrive set on ordinary presses for
    /// some keyboards, and would make a stored shortcut impossible to match.
    @Test
    func ignoresModifiersItDoesNotStore() {
        let shortcut = DictationShortcut(
            keyCode: UInt32(kVK_ANSI_D),
            modifierFlags: NSEvent.ModifierFlags(
                [.control, .capsLock, .function, .numericPad]
            ).rawValue,
            displayCharacter: "D"
        )

        #expect(shortcut.flags == [.control])
        #expect(shortcut.displayString == "⌃D")
    }

    @Test
    func survivesTheRoundTripThroughDefaults() throws {
        let original = DictationShortcut(
            keyCode: UInt32(kVK_Space),
            modifierFlags: NSEvent.ModifierFlags([.option]).rawValue,
            displayCharacter: "Space"
        )

        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(
            DictationShortcut.self,
            from: data
        )

        #expect(restored == original)
        #expect(restored.displayString == "⌥Space")
    }

    @Test
    func recordsAModifiedKeyPress() throws {
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.control, .option],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "∂",
                charactersIgnoringModifiers: "d",
                isARepeat: false,
                keyCode: UInt16(kVK_ANSI_D)
            )
        )

        let shortcut = try #require(DictationShortcut(event: event))

        // "d" rather than the "∂" that ⌥D actually types.
        #expect(shortcut.displayCharacter == "D")
        #expect(shortcut.displayString == "⌃⌥D")
    }

    @Test
    func refusesToRecordAKeyWithNoModifier() throws {
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "d",
                charactersIgnoringModifiers: "d",
                isARepeat: false,
                keyCode: UInt16(kVK_ANSI_D)
            )
        )

        #expect(DictationShortcut(event: event) == nil)
    }
}

struct DictationStyleTests {
    /// Only the styles that need the whole utterance are barred from
    /// streaming; the instant ones must reach the text field as they are said.
    @Test
    func onlyRewritingStylesWaitForTheEndOfTheSentence() {
        #expect(DictationStyle.verbatim.streamsLive)
        #expect(DictationStyle.cleanUp.streamsLive)
        #expect(!DictationStyle.polish.streamsLive)
        #expect(!DictationStyle.custom.streamsLive)
    }

    @Test
    func onlyRewritingStylesNeedTheModel() {
        #expect(!DictationStyle.verbatim.usesLanguageModel)
        #expect(!DictationStyle.cleanUp.usesLanguageModel)
        #expect(DictationStyle.polish.usesLanguageModel)
        #expect(DictationStyle.custom.usesLanguageModel)
    }

    /// The refusal clauses are the first line of defence against the model
    /// answering dictated speech instead of writing it down.
    @Test
    func everyStyleCarriesTheDoNotRespondContract() {
        for style in DictationStyle.allCases {
            let instructions = style.instructions(
                customPrompt: DictationStyle.defaultCustomPrompt
            )
            #expect(instructions.contains("Never answer a question"))
            #expect(instructions.contains("transcription filter"))
        }
    }

    @Test
    func aCustomStyleCarriesTheUsersInstruction() {
        let instructions = DictationStyle.custom.instructions(
            customPrompt: "Write it as formal British English."
        )

        #expect(instructions.contains("Write it as formal British English."))
    }

    /// An empty custom prompt would otherwise ask the model to apply nothing,
    /// which produces unpredictable rewrites.
    @Test
    func anEmptyCustomPromptFallsBackToPolish() {
        #expect(
            DictationStyle.custom.instructions(customPrompt: "   ")
                == DictationStyle.polish.instructions(customPrompt: "")
        )
    }
}
