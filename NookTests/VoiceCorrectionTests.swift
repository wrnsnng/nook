import AVFoundation
import Foundation
import Testing
@testable import Nook

struct VoiceCorrectionParserTests {
    @Test(arguments: ["scratch that", " Scratch that!\n", "SCRATCH THAT."])
    func completeScratchUtterancesProposeRemoval(words: String) {
        #expect(VoiceCorrectionIntent.parse(words) == .scratchThat)
    }

    @Test(arguments: [
        "Please scratch that", "We said scratch that yesterday", "\"scratch that\"",
        "scratch that and keep going", ".scratch that", "change the previous item to ",
        "I said change the previous item", "change previous item", ""
    ])
    func ordinaryOrIncompleteSpeechDoesNotBecomeACommand(words: String) {
        #expect(VoiceCorrectionIntent.parse(words) == nil)
    }

    @Test
    func replacementKeepsExactUnicodeAndPunctuation() throws {
        let words = "Cafe\u{0301} 👩🏽‍💻 العربية."
        let intent = try #require(VoiceCorrectionIntent.parse("Change the previous item to " + words))
        guard case .changePreviousItem(let replacement) = intent else {
            Issue.record("Expected a replacement proposal")
            return
        }
        #expect(replacement?.utf8.elementsEqual(words.utf8) == true)
        #expect(VoiceCorrectionIntent.parse("Change the previous item.") == .changePreviousItem(replacement: nil))
    }

    @Test(arguments: ["- ", "* ", "+ ", "12. ", "3) ", "  - [x] ", "- [ ] "])
    func itemCorrectionPreservesMarkerCheckboxAndSurroundingBytes(prefix: String) throws {
        let before = "Header 👩🏽‍💻\r\n" + prefix + "Cafe\u{0301} review  \r\n\r\n"
        let proposal = try #require(VoiceCorrectionProposal.make(
            intent: .changePreviousItem(replacement: nil), utterance: "change the previous item",
            before: before, literalText: before + "change the previous item", previous: nil
        ))
        #expect(proposal.originalWords.utf8.elementsEqual("Cafe\u{0301} review".utf8))
        #expect(proposal.correctedText(replacement: "") == nil)
        let expected = "Header 👩🏽‍💻\r\n" + prefix + "日本語  \r\n\r\n"
        #expect(proposal.correctedText(replacement: "日本語")?.utf8.elementsEqual(expected.utf8) == true)
    }

    @Test(arguments: [
        "Plain words", "- A list\n  continuation", "> - quoted item", "    - code item",
        "```swift\n- code item", "~~~\n- code item", "```\n```not a close\n- code item",
        "````\n```\n- code item", "```\n~~~\n- code item", "- ", ""
    ])
    func ambiguousOrCodeLikeTargetsKeepTheirWords(before: String) {
        #expect(VoiceCorrectionProposal.make(
            intent: .changePreviousItem(replacement: "replacement"), utterance: "change the previous item",
            before: before, literalText: before + " change the previous item", previous: nil
        ) == nil)
    }

    @Test
    func aRealClosingFenceAllowsTheFollowingListItem() throws {
        let before = "```swift\nlet value = 1\n```  \n- Review value"
        let proposal = try #require(VoiceCorrectionProposal.make(
            intent: .changePreviousItem(replacement: "Confirm value"), utterance: "change the previous item",
            before: before, literalText: before + " change the previous item", previous: nil
        ))
        #expect(proposal.originalWords == "Review value")
    }
}

@MainActor
struct VoiceCorrectionTests {
    @Test
    func scratchKeepsLiteralWordsUntilApplyAndUndoRestoresThemExactly() throws {
        try withPad { pad, _ in
            pad.text = "Typed baseline."
            pad.receiveDictation("Cafe\u{0301} 👩🏽‍💻", inserting: "Cafe\u{0301} 👩🏽‍💻")
            #expect(pad.receiveDictation("Scratch that.", inserting: "untrusted replacement"))
            let literal = "Typed baseline. Cafe\u{0301} 👩🏽‍💻 Scratch that."
            #expect(pad.text.utf8.elementsEqual(literal.utf8))
            let proposal = try #require(pad.voiceCorrection)
            #expect(pad.applyVoiceCorrection(proposal, replacement: ""))
            #expect(pad.text == "Typed baseline.")
            #expect(pad.canUndoVoiceCorrection)
            pad.undoVoiceCorrection()
            #expect(pad.text.utf8.elementsEqual(literal.utf8))
            #expect(!pad.canUndoVoiceCorrection)
        }
    }

    @Test
    func typedTextCannotBeGuessedAsThePreviousDictatedPhrase() throws {
        try withPad { pad, _ in
            pad.text = "Typed baseline."
            pad.receiveDictation("scratch that", inserting: "scratch that")
            #expect(pad.voiceCorrection == nil)
            #expect(pad.text == "Typed baseline. scratch that")
            #expect(pad.voiceStatus?.contains("Words kept") == true)
        }
    }

    @Test
    func cancelAndAStaleCancelNeverChangeWordsOrDismissANewerProposal() throws {
        try withPad { pad, _ in
            pad.receiveDictation("First thought", inserting: "First thought")
            pad.receiveDictation("scratch that", inserting: "scratch that")
            let first = try #require(pad.voiceCorrection)
            let literal = pad.text
            pad.keepVoiceWords(first)
            #expect(pad.text == literal)
            #expect(pad.voiceCorrection == nil)
            pad.receiveDictation("Next thought", inserting: "Next thought")
            pad.receiveDictation("scratch that", inserting: "scratch that")
            let next = try #require(pad.voiceCorrection)
            pad.keepVoiceWords(first)
            #expect(pad.voiceCorrection?.id == next.id)
        }
    }

    @Test(arguments: ["text", "library", "filing"])
    func changesAwayAndBackInvalidateTheOriginalProposal(change: String) throws {
        try withPad { pad, store in
            pad.receiveDictation("Original", inserting: "Original")
            pad.receiveDictation("scratch that", inserting: "scratch that")
            let proposal = try #require(pad.voiceCorrection)
            let literal = pad.text
            switch change {
            case "text":
                pad.text += " edit"
                pad.text = literal
            case "library":
                let original = store.storageURL
                store.storageURL = original.appendingPathComponent("Other")
                store.storageURL = original
            default:
                pad.requestFiling()
                pad.filingRequest = nil
            }
            #expect(!pad.isCurrentVoiceCorrection(proposal))
            #expect(!pad.applyVoiceCorrection(proposal, replacement: ""))
            #expect(pad.text == literal)
        }
    }

    @Test
    func missingReplacementRequiresWordsAndPreservesCheckedItemIdentity() throws {
        try withPad { pad, _ in
            pad.text = "Heading\n- [x] Original action"
            pad.receiveDictation("change the previous item", inserting: "change the previous item")
            let proposal = try #require(pad.voiceCorrection)
            let literal = pad.text
            #expect(!pad.applyVoiceCorrection(proposal, replacement: " \n"))
            #expect(pad.text == literal)
            #expect(pad.applyVoiceCorrection(proposal, replacement: "Reviewed action"))
            #expect(pad.text == "Heading\n- [x] Reviewed action")
        }
    }

    @Test
    func reviewingPausesCaptureAndPreventsFilingFromOpeningOverIt() throws {
        try withPad { pad, _ in
            var pauses = 0
            pad.onDismissRequested = { pauses += 1 }
            pad.isContinuous = true
            pad.receiveDictation("Original", inserting: "Original")
            pad.receiveDictation("scratch that", inserting: "scratch that")
            let proposal = try #require(pad.voiceCorrection)
            #expect(pad.beginVoiceCorrectionReview(proposal))
            #expect(!pad.beginVoiceCorrectionReview(proposal))
            #expect(!pad.isContinuous)
            #expect(pauses == 1)
            pad.requestFiling()
            #expect(pad.filingRequest == nil)
            pad.endVoiceCorrectionReview()
            pad.requestFiling()
            #expect(pad.filingRequest != nil)
            #expect(!pad.beginVoiceCorrectionReview(proposal))
        }
    }

    @Test(arguments: ["\n", "\n\n"])
    func formattingInsertsRealLineBreaksAndCanBeUndone(lineBreak: String) throws {
        try withPad { pad, _ in
            pad.text = "Original"
            #expect(!pad.receiveDictation("new paragraph", inserting: lineBreak))
            #expect(pad.text == "Original" + lineBreak)
            #expect(pad.canUndoVoiceCorrection)
            pad.undoVoiceCorrection()
            #expect(pad.text == "Original")
        }
    }

    @Test
    func lateRefinementAndExternalFallbackCannotApplyCorrections() throws {
        try withPad { pad, _ in
            pad.receiveDictation("Original", inserting: "Original")
            let revision = pad.textRevision
            #expect(!pad.receiveDictation("scratch that", inserting: "scratch that", allowsCorrections: false))
            #expect(pad.voiceCorrection == nil)
            pad.replaceLastDictation(with: "Rewritten", spoken: "Original", expectedRevision: revision)
            #expect(pad.text == "Original scratch that")
        }
    }

    @Test
    func pendingCommandWordsCanBeSavedAndReadBackWithoutApplyingTheProposal() throws {
        try withPad { pad, _ in
            pad.receiveDictation("Original", inserting: "Original")
            pad.receiveDictation("scratch that", inserting: "scratch that")
            let saved = try #require(pad.saveIfNeeded())
            let file = try #require(saved.fileURL)
            let source = try String(contentsOf: file, encoding: .utf8)
            let reloaded = try #require(MarkdownCodec.decode(source, fileURL: file))
            #expect(reloaded.summary == "Original scratch that")
            #expect(pad.voiceCorrection != nil)
        }
    }

    @Test
    func aReviewedCorrectionCannotOverwriteAConcurrentFileEdit() throws {
        try withPad { pad, _ in
            pad.text = "Baseline."
            pad.receiveDictation("Another thought", inserting: "Another thought")
            pad.receiveDictation("scratch that", inserting: "scratch that")
            let proposal = try #require(pad.voiceCorrection)
            let saved = try #require(pad.saveIfNeeded())
            let file = try #require(saved.fileURL)
            let external = try String(contentsOf: file, encoding: .utf8) + "\nExternal words.\n"
            try external.write(to: file, atomically: true, encoding: .utf8)
            #expect(pad.applyVoiceCorrection(proposal, replacement: ""))
            #expect(pad.text == "Baseline.")
            #expect(pad.saveIfNeeded() == nil)
            #expect(pad.hasUnsavedFailure)
            #expect(try String(contentsOf: file, encoding: .utf8).utf8.elementsEqual(external.utf8))
            pad.undoVoiceCorrection()
            #expect(pad.text == "Baseline. Another thought scratch that")
        }
    }

    @Test
    func accessibleStatusDistinguishesInsertionProposalApplyAndUndo() throws {
        var messages: [String] = []
        try withPad(announce: { messages.append($0) }) { pad, _ in
            pad.receiveDictation("Original", inserting: "Original")
            pad.receiveDictation("scratch that", inserting: "scratch that")
            let proposal = try #require(pad.voiceCorrection)
            #expect(pad.applyVoiceCorrection(proposal, replacement: ""))
            pad.undoVoiceCorrection()
        }
        #expect(messages.count == 4)
        #expect(messages[0] == "Dictated words inserted.")
        #expect(messages[1].contains("proposed"))
        #expect(messages[2].contains("applied"))
        #expect(messages[3].contains("undone"))
    }

    private func withPad(
        announce: (@MainActor (String) -> Void)? = nil,
        _ body: (QuickNoteController, MarkdownStore) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NookVoiceTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "NookVoiceTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MarkdownStore(fileManager: VoiceFixtureFileManager(root: root), noteLoader: { _, _ in
            .success((notes: [], issues: []))
        })
        store.storageURL = root.appendingPathComponent("Library")
        let pad = QuickNoteController(
            store: store, assistantRun: { _, _, _ in
                Issue.record("Voice corrections must not call an assistant")
                return ""
            }, availableEngines: { [] }, defaults: defaults, openFilingLibrary: {}, announceVoiceStatus: announce
        )
        try body(pad, store)
    }
}

@MainActor
struct VoiceDictationRoutingTests {
    @Test(arguments: ["pad", "focusMoved", "review", "external", "focusArrived", "ordinary"])
    func dictationOwnershipAndRefinementRespectCorrectionConsent(scenario: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NookVoiceRouting-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "NookVoiceRouting." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MarkdownStore(fileManager: VoiceFixtureFileManager(root: root), noteLoader: { _, _ in
            .success((notes: [], issues: []))
        })
        store.storageURL = root.appendingPathComponent("Library")
        let pad = QuickNoteController(store: store, availableEngines: { [] }, defaults: defaults)
        let audio = VoiceRoutingAudio()
        let recognizer = VoiceRoutingRecognizer()
        let insertion = VoiceRoutingInsertion()
        let refinement = VoiceRefinementProbe()
        let focus = VoiceRoutingFocus()
        let startsExternally = scenario == "external" || scenario == "focusArrived"
        focus.ownsPad = !startsExternally
        let coordinator = DictationCoordinator(
            localeIdentifier: "en_AU", audio: audio, recognizer: recognizer, insertion: insertion,
            registersShortcut: false, defaults: defaults, quickNoteHasFocus: { focus.ownsPad },
            refine: { _, _, _ in await refinement.run() }
        )
        coordinator.quickNote = pad
        pad.onDismissRequested = { [weak coordinator] in coordinator?.cancel() }
        coordinator.style = startsExternally ? .verbatim : .polish
        coordinator.isEnabled = true
        defer { coordinator.cancel() }
        coordinator.startContinuousSession()
        try await waitUntil { coordinator.phase == .listening }
        recognizer.onFinalized?("Original thought")
        if scenario == "focusMoved" { focus.ownsPad = false }
        if scenario == "focusArrived" { focus.ownsPad = true }
        if scenario != "ordinary" { recognizer.onFinalized?("scratch that") }
        if scenario == "review" {
            let proposal = try #require(pad.voiceCorrection)
            #expect(pad.beginVoiceCorrectionReview(proposal))
            let literal = pad.text
            recognizer.onFinalized?("A late callback must not land")
            #expect(pad.text == literal)
            #expect(coordinator.phase == .idle)
            #expect(audio.stops > 0)
            #expect(recognizer.cancels > 0)
        } else {
            coordinator.stopContinuousSession()
            try await waitUntil { coordinator.phase == .idle && !coordinator.isFinishingForTesting }
        }
        #expect(await refinement.calls == (scenario == "ordinary" ? 1 : 0))
        if startsExternally {
            #expect(pad.text.isEmpty)
            #expect(pad.voiceCorrection == nil)
            #expect(insertion.appended.joined() == "Original thought scratch that")
        } else {
            #expect(insertion.appended.isEmpty)
            #expect(pad.text == (scenario == "ordinary" ? "Original thought" : "Original thought scratch that"))
            #expect((pad.voiceCorrection != nil) == (scenario != "ordinary"))
        }
    }

    private func waitUntil(_ ready: () -> Bool) async throws {
        for _ in 0..<200 {
            if ready() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(ready(), "Synthetic dictation did not reach the expected lifecycle state")
    }
}

private actor VoiceRefinementProbe {
    private(set) var calls = 0
    func run() -> DictationRefiner.Outcome {
        calls += 1
        return .keptVerbatim(.modelUnavailable)
    }
}

@MainActor
private final class VoiceRoutingFocus { var ownsPad = false }

@MainActor
private final class VoiceRoutingAudio: DictationAudioCapturing {
    var onLevel: (@MainActor (Float) -> Void)?
    var stops = 0
    func start(onBuffer: @escaping @MainActor (AVAudioPCMBuffer) -> Void) throws {}
    func finishCapturing() async {}
    func stop() { stops += 1 }
}

@MainActor
private final class VoiceRoutingRecognizer: DictationRecognizing {
    var onVolatile: (@MainActor (String) -> Void)?
    var onFinalized: (@MainActor (String) -> Void)?
    var onError: (@MainActor (String) -> Void)?
    var onEnded: (@MainActor () -> Void)?
    var cancels = 0
    func start(localeIdentifier: String) async throws {}
    func ingest(_ buffer: AVAudioPCMBuffer) {}
    func finish() async {}
    func cancel() { cancels += 1 }
}

@MainActor
private final class VoiceRoutingInsertion: DictationTextInserting {
    var appended: [String] = []
    var lastInspection = "Synthetic focused field"
    func beginRun() -> TextInsertionService.Capability { .streaming }
    func append(_ text: String) -> Bool { appended.append(text); return true }
    func replaceRun(with text: String) -> Bool { Issue.record("Unexpected external replacement"); return false }
    func pasteOnce(_ text: String) async -> TextInsertionService.PasteOutcome {
        Issue.record("Unexpected paste")
        return .pasted
    }
    func endRun() {}
}

private final class VoiceFixtureFileManager: FileManager {
    let root: URL
    init(root: URL) { self.root = root; super.init() }
    override func createDirectory(
        at url: URL, withIntermediateDirectories createIntermediates: Bool,
        attributes: [FileAttributeKey: Any]? = nil
    ) throws {
        guard url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") else {
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
    }
}
