import AppKit
import AVFoundation
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

@MainActor
struct DictationLifecycleTests {
    @Test
    func aRecognizerFailureAlwaysTearsDownAudioAndRecognition() {
        let audio = TestDictationAudioSource()
        let recognizer = TestDictationRecognizer()
        let coordinator = DictationCoordinator(
            localeIdentifier: "en_AU",
            audio: audio,
            recognizer: recognizer,
            registersShortcut: false
        )

        recognizer.onError?("Synthetic recognition failure")

        #expect(audio.stopCount == 1)
        #expect(recognizer.cancelCount == 1)
        guard case .failed = coordinator.phase else {
            Issue.record("Expected the coordinator to expose the recognition failure")
            return
        }
    }

    @Test
    func cancellingPreparationCannotFailANewerDictation() async {
        let audio = TestDictationAudioSource()
        let recognizer = BlockingDictationRecognizer()
        let insertion = TestDictationInsertion(
            capabilities: [.noTextField, .noTextField]
        )
        let coordinator = DictationCoordinator(
            localeIdentifier: "en_AU",
            audio: audio,
            recognizer: recognizer,
            insertion: insertion,
            registersShortcut: false
        )
        coordinator.style = .verbatim
        coordinator.isEnabled = true
        defer { coordinator.cancel() }

        coordinator.startContinuousSession()
        for _ in 0..<100 where recognizer.startCount < 1 {
            await Task.yield()
        }
        #expect(recognizer.startCount == 1)

        // Finish begins waiting for the first recognizer start. Cancelling
        // while that wait is pending must invalidate the old session rather
        // than turn cancellation into a startup failure.
        coordinator.stopContinuousSession()
        coordinator.cancel()
        let endRunsAfterCancellation = insertion.endRunCount

        // Start again before the cancelled finisher has a chance to resume.
        // Releasing the old start now exercises its stale-session cleanup,
        // while the second start remains the one the coordinator owns.
        coordinator.startContinuousSession()
        for _ in 0..<100 where recognizer.startCount < 2 {
            await Task.yield()
        }
        #expect(recognizer.startCount == 2)

        // Keep the newer session in its own finishing window while the stale
        // finisher unwinds. It must not clear the newer session's flag.
        recognizer.emitFinalized("words for the next dictation")
        coordinator.stopContinuousSession()
        recognizer.releaseNextStart()
        for _ in 0..<100 {
            await Task.yield()
        }
        #expect(coordinator.isFinishingForTesting)
        #expect(insertion.endRunCount == endRunsAfterCancellation)
        recognizer.releaseNextStart()

        for _ in 0..<100 where coordinator.isFinishingForTesting {
            await Task.yield()
        }
        #expect(coordinator.phase == .idle)
    }

    @Test
    func secondLookPasteKeepsItsInsertionTargetUntilPasteCompletes() async {
        let audio = TestDictationAudioSource()
        let recognizer = TestDictationRecognizer()
        let insertion = TestDictationInsertion(
            capabilities: [.noTextField, .pasteOnly]
        )
        let coordinator = DictationCoordinator(
            localeIdentifier: "en_AU",
            audio: audio,
            recognizer: recognizer,
            insertion: insertion,
            registersShortcut: false
        )
        coordinator.style = .verbatim
        coordinator.isEnabled = true
        defer { coordinator.cancel() }

        coordinator.startContinuousSession()
        for _ in 0..<100 where recognizer.startCount < 1 {
            await Task.yield()
        }
        recognizer.emitFinalized("words for the focused field")
        coordinator.stopContinuousSession()

        for _ in 0..<100 where !insertion.pasteStarted {
            await Task.yield()
        }
        #expect(insertion.pasteStarted)
        #expect(insertion.endRunCount == 0)

        insertion.completePaste(.pasted)
        for _ in 0..<100 where insertion.endRunCount == 0 {
            await Task.yield()
        }
        #expect(insertion.endRunCount == 1)
        #expect(coordinator.phase == .idle)
    }

    @Test
    func audioCaptureWaitsForTheInputCheckTeardownBarrier() async {
        let audio = TestDictationAudioSource()
        let recognizer = TestDictationRecognizer()
        let insertion = TestDictationInsertion(capabilities: [.noTextField])
        let barrier = TestAudioCaptureBarrier()
        let coordinator = DictationCoordinator(
            localeIdentifier: "en_AU",
            audio: audio,
            recognizer: recognizer,
            insertion: insertion,
            registersShortcut: false,
            prepareForAudioCapture: {
                await barrier.wait()
            }
        )
        coordinator.style = .verbatim
        coordinator.isEnabled = true
        defer { coordinator.cancel() }

        coordinator.startContinuousSession()
        for _ in 0..<100 where !barrier.didEnter {
            await Task.yield()
        }

        #expect(barrier.didEnter)
        #expect(audio.startCount == 0)
        #expect(coordinator.phase == .preparing)

        barrier.release()
        for _ in 0..<100 where audio.startCount == 0 {
            await Task.yield()
        }

        #expect(audio.startCount == 1)
        #expect(coordinator.phase == .listening)
    }
}

/// Where a finished dictation is allowed to land.
///
/// ⌘V is a system-wide keystroke: it goes wherever focus is at the instant it
/// is posted, not where the run began. The rule below is the only thing
/// standing between a dictation and the wrong window.
struct DictationPasteTargetTests {
    /// The words were aimed at the field the run started in. Once focus has
    /// moved, they go to the note pad instead, where the user can read them
    /// and put them where they meant to.
    @Test
    func aPasteIsRefusedOnceFocusHasLeftTheFieldTheRunStartedIn() {
        #expect(
            TextInsertionService.pasteRefusal(
                hasRecordedTarget: true,
                focusMatchesRecordedTarget: false,
                focusIsSecure: false
            ) == .focusMoved
        )
    }

    /// No recorded target means nothing to compare against, so there is no
    /// evidence the paste would land where it was meant to.
    @Test
    func aRunThatRecordedNoFieldNeverPastes() {
        #expect(
            TextInsertionService.pasteRefusal(
                hasRecordedTarget: false,
                focusMatchesRecordedTarget: false,
                focusIsSecure: false
            ) == .focusMoved
        )
    }

    /// Words spoken into a password field are a secret. They are not typed
    /// there, and they are not written to a note either: a note is a file.
    @Test
    func aRunThatStartedInAPasswordFieldIsRefusedOutright() {
        #expect(
            TextInsertionService.pasteRefusal(
                hasRecordedTarget: true,
                focusMatchesRecordedTarget: true,
                focusIsSecure: true
            ) == .secureField
        )
    }

    /// Focus landing in a password field afterwards says nothing about the
    /// words themselves, which still belong to the field the user left.
    @Test
    func focusMovingIntoAPasswordFieldStillLeavesTheWordsWithTheUser() {
        #expect(
            TextInsertionService.pasteRefusal(
                hasRecordedTarget: true,
                focusMatchesRecordedTarget: false,
                focusIsSecure: true
            ) == .focusMoved
        )
    }

    @Test
    func anOrdinaryFieldThatStillHasFocusIsPastedInto() {
        #expect(
            TextInsertionService.pasteRefusal(
                hasRecordedTarget: true,
                focusMatchesRecordedTarget: true,
                focusIsSecure: false
            ) == nil
        )
    }
}

/// Whether a run may start at all, and by which mechanism.
///
/// The paste path has refused a password field since it existed. The
/// direct-write path never asked, so a dictation that began in one streamed
/// the user's spoken password straight into it, one chunk at a time.
struct DictationRunTargetTests {
    @Test
    func aRunThatStartsInAPasswordFieldTypesNowhere() {
        // Settable and text-accepting: everything a password field also is.
        #expect(
            TextInsertionService.runCapability(
                focusIsSecure: true,
                supportsDirectWriting: true,
                acceptsText: true
            ) == .secureField
        )
        #expect(
            TextInsertionService.runCapability(
                focusIsSecure: true,
                supportsDirectWriting: false,
                acceptsText: true
            ) == .secureField
        )
    }

    @Test
    func anOrdinaryWritableFieldStreams() {
        #expect(
            TextInsertionService.runCapability(
                focusIsSecure: false,
                supportsDirectWriting: true,
                acceptsText: true
            ) == .streaming
        )
    }

    @Test
    func aFieldThatOnlyTakesAPasteIsPastedInto() {
        #expect(
            TextInsertionService.runCapability(
                focusIsSecure: false,
                supportsDirectWriting: false,
                acceptsText: true
            ) == .pasteOnly
        )
    }

    @Test
    func somewhereThatCannotTakeTextSendsTheWordsToTheNotePad() {
        #expect(
            TextInsertionService.runCapability(
                focusIsSecure: false,
                supportsDirectWriting: false,
                acceptsText: false
            ) == .noTextField
        )
    }
}

/// How long one dictation may hold the microphone.
///
/// Hold-to-talk ends on key-up, and macOS Secure Input can swallow that key-up
/// entirely, leaving nothing to end the run.
struct DictationSessionCeilingTests {
    @Test
    func aHandsFreePadSessionGetsMoreRoomThanAHeldShortcut() {
        let ceilings = DictationSessionCeilings.standard

        #expect(ceilings.ceiling(isContinuous: false) == .seconds(300))
        #expect(
            ceilings.ceiling(isContinuous: true)
                > ceilings.ceiling(isContinuous: false)
        )
    }

    /// The sentence is derived from the ceiling in force so the two cannot
    /// drift apart and tell the user a number that is not true.
    @Test
    func theExpirySentenceNamesTheCeilingActuallyInForce() {
        #expect(
            DictationSessionCeilings.expiryMessage(for: .seconds(300))
                .contains("5 minutes")
        )
        #expect(
            DictationSessionCeilings.expiryMessage(for: .seconds(60))
                .contains("1 minute.")
        )
    }

    /// A ceiling that ended a dictation has to say what to do next, or it
    /// reads as the feature having broken.
    @Test
    func theExpirySentenceSaysHowToStartAgain() {
        #expect(
            DictationSessionCeilings.expiryMessage(for: .seconds(300))
                .contains("Press the shortcut")
        )
    }
}

@MainActor
private final class TestDictationAudioSource: DictationAudioCapturing {
    var onLevel: (@MainActor (Float) -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start(
        onBuffer: @escaping @MainActor (AVAudioPCMBuffer) -> Void
    ) throws {
        startCount += 1
    }

    func finishCapturing() async {}

    func stop() {
        stopCount += 1
    }
}

@MainActor
private final class TestAudioCaptureBarrier {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var didEnter = false

    func wait() async {
        didEnter = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class TestDictationRecognizer: DictationRecognizing {
    var onVolatile: (@MainActor (String) -> Void)?
    var onFinalized: (@MainActor (String) -> Void)?
    var onError: (@MainActor (String) -> Void)?
    var onEnded: (@MainActor () -> Void)?
    private(set) var cancelCount = 0
    private(set) var startCount = 0
    private(set) var finishCount = 0

    func start(localeIdentifier: String) async throws {
        startCount += 1
    }

    func ingest(_ buffer: AVAudioPCMBuffer) {}

    func finish() async {
        finishCount += 1
    }

    func cancel() {
        cancelCount += 1
    }

    func emitFinalized(_ text: String) {
        onFinalized?(text)
    }
}

@MainActor
private final class BlockingDictationRecognizer: DictationRecognizing {
    var onVolatile: (@MainActor (String) -> Void)?
    var onFinalized: (@MainActor (String) -> Void)?
    var onError: (@MainActor (String) -> Void)?
    var onEnded: (@MainActor () -> Void)?
    private(set) var startCount = 0
    private var startContinuations: [CheckedContinuation<Void, Never>] = []

    func start(localeIdentifier: String) async throws {
        startCount += 1
        await withCheckedContinuation { continuation in
            startContinuations.append(continuation)
        }
    }

    func ingest(_ buffer: AVAudioPCMBuffer) {}

    func finish() async {}

    func cancel() {}

    func releaseNextStart() {
        guard !startContinuations.isEmpty else {
            Issue.record("Expected a blocked recognizer start")
            return
        }
        startContinuations.removeFirst().resume()
    }

    func emitFinalized(_ text: String) {
        onFinalized?(text)
    }
}

@MainActor
private final class TestDictationInsertion: DictationTextInserting {
    private var capabilities: [TextInsertionService.Capability]
    private var pasteContinuation:
        CheckedContinuation<TextInsertionService.PasteOutcome, Never>?
    private(set) var pasteStarted = false
    private(set) var endRunCount = 0
    var lastInspection = "test"

    init(capabilities: [TextInsertionService.Capability]) {
        self.capabilities = capabilities
    }

    func beginRun() -> TextInsertionService.Capability {
        capabilities.isEmpty ? .noTextField : capabilities.removeFirst()
    }

    func append(_ text: String) -> Bool { true }

    func replaceRun(with text: String) -> Bool { true }

    func pasteOnce(_ text: String) async -> TextInsertionService.PasteOutcome {
        pasteStarted = true
        return await withCheckedContinuation { continuation in
            pasteContinuation = continuation
        }
    }

    func endRun() {
        endRunCount += 1
    }

    func completePaste(_ outcome: TextInsertionService.PasteOutcome) {
        guard let pasteContinuation else {
            Issue.record("Expected a paste to be waiting before completing it")
            return
        }
        self.pasteContinuation = nil
        pasteContinuation.resume(returning: outcome)
    }
}

/// Per-app overrides are stored under the app's bundle identifier and win
/// only there; removing one returns that app to the global habit.
@MainActor
struct DictationStyleOverrideTests {
    @Test
    func anOverrideAppliesToItsAppAlone() {
        // A namespaced bundle id keeps this from colliding with anything
        // real, and the defer restores whatever was there before.
        let bundleID = "com.nook.tests.mail-\(UUID().uuidString)"
        DictationStyle.setOverride(.polish, forBundleID: bundleID)
        defer { DictationStyle.setOverride(nil, forBundleID: bundleID) }

        #expect(DictationStyle.override(forBundleID: bundleID) == .polish)
        #expect(DictationStyle.override(forBundleID: "com.nook.tests.other") == nil)
        #expect(DictationStyle.override(forBundleID: nil) == nil)

        DictationStyle.setOverride(nil, forBundleID: bundleID)
        #expect(DictationStyle.override(forBundleID: bundleID) == nil)
        #expect(!DictationStyle.overriddenBundleIDs.contains(bundleID))
    }
}
