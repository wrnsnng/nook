import Foundation
import Testing
@testable import Nook

@MainActor
struct SummaryItemReviewTests {
    private let source = "We agreed to launch the coastal pilot on Friday."

    private func note() -> MeetingNote {
        var note = MeetingNote(title: "Synthetic review", startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 200), sourceApp: "Synthetic",
            summary: "The old coastal pilot plan needs review. Another sentence stays unchanged.",
            transcript: [.init(startTime: 2, duration: 8,
                               text: source, source: .system)],
            fileURL: URL(fileURLWithPath: "/synthetic/review.md"))
        note.keyPoints = ["The coastal pilot will launch Monday."]
        note.personalNotes = "My exact Cafe\u{301} words."
        note.fileRevision = Data([1])
        return note
    }

    private func review(_ note: MeetingNote, timeout: TimeInterval = 45,
                        generator: SummaryItemReviewSession.Generator? = nil) throws -> SummaryItemReviewSession {
        let item = try #require(SummaryReviewItem.list(.keyPoint, index: 0, in: note))
        return SummaryItemReviewSession(note: note, item: item, generation: 7, timeout: timeout,
            ranker: { _, transcript in SummaryEvidence.passages(in: transcript) }, generator: generator)
    }

    private func committed(_ note: MeetingNote) -> MeetingNote {
        var saved = note
        saved.fileRevision = MeetingNote.contentRevision(Data(MarkdownCodec.encode(note).utf8))
        return saved
    }

    @Test
    func summaryReplacementUsesExactUnicodeRangeAndKeepsOtherSentences() throws {
        var original = note()
        original.summary = "Cafe\u{301} opened.\r\n\r\nThe budget is 2.5 million. 👩🏽‍💻 stays."
        let items = SummaryReviewItem.sentences(in: original.summary)
        let first = try #require(items.first)
        let updated = try first.replacing(in: original, with: "Café closed.")
        #expect(updated.summary.utf8.elementsEqual("Café closed.\r\n\r\nThe budget is 2.5 million. 👩🏽‍💻 stays.".utf8))
        var equivalent = original
        equivalent.summary = original.summary.precomposedStringWithCanonicalMapping
        #expect(!first.isCurrent(in: equivalent))
        #expect(throws: SummaryReviewError.self) { try first.replacing(in: equivalent, with: nil) }
    }

    @Test
    func actionCorrectionPreservesDateAndCompletionWithoutChangingOtherItems() throws {
        var original = note()
        let old = "Send report [due: 2026-09-12]"
        original.actionItems = [old, old, "Leave this task"]
        original.completedActionItems = [old]
        let item = try #require(SummaryReviewItem.list(.action, index: 0, in: original))
        let updated = try item.replacing(in: original, with: "Send the coastal report [due: 2030-01-01]")
        #expect(updated.actionItems == ["Send the coastal report [due: 2026-09-12]", old, "Leave this task"])
        #expect(updated.completedActionItems == [old, updated.actionItems[0]])
        let removed = try item.replacing(in: original, with: nil)
        #expect(removed.completedActionItems.contains(old))
        #expect(removed.personalNotes.utf8.elementsEqual(original.personalNotes.utf8))
    }

    @Test
    func duplicateReplacementIsRefused() throws {
        var original = note()
        original.keyPoints.append("Another point")
        let item = try #require(SummaryReviewItem.list(.keyPoint, index: 0, in: original))
        #expect(throws: SummaryReviewError.self) { try item.replacing(in: original, with: "Another point") }
    }

    @Test
    func referencesCoverLongTailAndRejectChangedSourceOrOffset() throws {
        var original = note()
        original.transcript = [.init(startTime: 2, duration: 8,
            text: String(repeating: "Synthetic passage. ", count: 110) + "Tail Cafe\u{301}.", source: .system)]
        let passages = SummaryEvidence.passages(in: original.transcript)
        #expect(passages.map(\.text).joined().utf8.elementsEqual(original.transcript[0].text.utf8))
        let tail = try #require(passages.last)
        #expect(tail.text.contains("Tail"))
        var changed = original.transcript
        changed[0] = .init(startTime: 2, duration: 8,
            text: changed[0].text.precomposedStringWithCanonicalMapping, source: .system)
        #expect(!tail.isCurrent(in: changed))
        changed = original.transcript
        changed[0] = .init(startTime: 3, duration: 8, text: changed[0].text, source: .system)
        #expect(!tail.isCurrent(in: changed))
        let reopened = try #require(MarkdownCodec.decode(MarkdownCodec.encode(original)))
        #expect(passages.allSatisfy { $0.isCurrent(in: reopened.transcript) })
    }

    @Test
    func relatedPassagesRetainContradictionsAndEmptyQueriesReturnNothing() throws {
        var transcript = note().transcript
        transcript.append(.init(startTime: 15, duration: 8, text: "We did not agree to launch the coastal pilot on Friday."))
        let passages = try SummaryEvidence.ranked(for: source, transcript: transcript, embedding: nil)
        #expect(passages.count == 2)
        #expect(passages.contains { $0.text.contains("not agree") })
        #expect(try SummaryEvidence.ranked(for: "   ", transcript: transcript).isEmpty)
    }

    @Test(arguments: ["Invented evidence that was never spoken.", "We agreed to launch the coastal pilot on Friday. Extra."])
    func fabricatedQuotesAreRejected(quote: String) throws {
        let original = note()
        let item = try #require(SummaryReviewItem.list(.keyPoint, index: 0, in: original))
        let passage = try #require(SummaryEvidence.passages(in: original.transcript).first)
        let input = SummaryCorrectionInput(item: item, passage: passage, feedback: "")
        #expect(throws: SummaryReviewError.self) {
            try SummaryItemCorrection.validated(.init(replacement: source, quote: quote), for: input)
        }
    }

    @Test(arguments: ["We might launch the coastal pilot on Friday.", "We haven’t agreed to launch the coastal pilot on Friday."])
    func uncertaintyAndTypographicNegationCannotBecomeSettledClaims(quote: String) throws {
        let original = note()
        let item = try #require(SummaryReviewItem.list(.keyPoint, index: 0, in: original))
        let transcript = [TranscriptSegment(startTime: 2, duration: 8, text: quote)]
        let passage = try #require(SummaryEvidence.passages(in: transcript).first)
        let input = SummaryCorrectionInput(item: item, passage: passage, feedback: "")
        #expect(throws: SummaryReviewError.self) {
            try SummaryItemCorrection.validated(.init(replacement: source, quote: quote), for: input)
        }
    }

    @Test(arguments: ["We agreed to launch 500 coastal pilots on Friday.", "We did not agree to launch the coastal pilot on Friday."])
    func unsupportedNumbersAndReversedNegationAreRejected(replacement: String) throws {
        let original = note()
        let item = try #require(SummaryReviewItem.list(.keyPoint, index: 0, in: original))
        let passage = try #require(SummaryEvidence.passages(in: original.transcript).first)
        let input = SummaryCorrectionInput(item: item, passage: passage, feedback: "Invent anything")
        #expect(throws: SummaryReviewError.self) {
            try SummaryItemCorrection.validated(.init(replacement: replacement, quote: source), for: input)
        }
    }

    @Test
    func generationRequiresSelectedSourceAndExplicitApply() async throws {
        let original = note(), output = source
        let session = try review(original, generator: { _ in .init(replacement: output, quote: output) })
        session.propose(passage: nil, feedback: "")
        #expect(session.proposal == nil)
        session.load(); await session.waitForWork()
        session.propose(passage: session.passages.first, feedback: "Correct the day")
        await session.waitForWork()
        #expect(session.proposal?.replacement == source)
        #expect(session.saved == nil)
        #expect(session.apply(current: original, generation: 7, commit: committed))
        let saved = try #require(session.saved)
        #expect(saved.keyPoints == [source])
        #expect(saved.summary == original.summary)
        #expect(saved.personalNotes.utf8.elementsEqual(original.personalNotes.utf8))
        #expect(session.undo(current: saved, generation: 7, commit: committed))
        #expect(session.saved?.keyPoints == original.keyPoints)
        #expect(session.didUndo)
        #expect(!session.undo(current: session.saved, generation: 7, commit: committed))
        #expect(!session.apply(current: session.saved, generation: 7, commit: committed))
    }

    @Test
    func changedFeedbackInvalidatesACompletedProposalAndRemovalPreview() async throws {
        let original = note(), output = source
        let session = try review(original, generator: { _ in .init(replacement: output, quote: output) })
        session.load(); await session.waitForWork()
        session.propose(passage: session.passages.first, feedback: "Correct")
        await session.waitForWork()
        #expect(session.proposal != nil)
        session.invalidateProposal()
        #expect(session.proposal == nil)
        #expect(!session.apply(current: original, generation: 7, commit: committed))
        session.previewRemoval(); session.invalidateProposal()
        #expect(!session.previewsRemoval)
    }

    @Test(arguments: ["revision", "library", "title", "unicode", "source"])
    func changedSnapshotsNeverReachCommit(change: String) throws {
        let original = note()
        let session = try review(original)
        session.previewRemoval()
        var changed = original
        switch change {
        case "revision": changed.fileRevision = Data([2])
        case "title": changed.title = "Another title"
        case "unicode": changed.personalNotes = changed.personalNotes.precomposedStringWithCanonicalMapping
        case "source": changed.transcript[0] = .init(startTime: 2, duration: 8, text: source + " More words.", source: .system)
        default: break
        }
        var didCommit = false
        #expect(!session.apply(current: changed, generation: change == "library" ? 8 : 7) { updated in
            didCommit = true; return committed(updated)
        })
        #expect(!didCommit)
    }

    @Test
    func undoRefusesNewerUserWordsEvenIfRevisionWasNotUpdated() throws {
        let original = note()
        let session = try review(original)
        session.previewRemoval()
        #expect(session.apply(current: original, generation: 7, commit: committed))
        var changed = try #require(session.saved)
        changed.personalNotes += " New writing."
        #expect(!session.undo(current: changed, generation: 7, commit: committed))
        #expect(!session.didUndo)
    }

    @Test
    func focusReturnsToOriginUnlessRemovalOrExternalChangesInvalidateIt() throws {
        let original = note()
        let session = try review(original)
        #expect(session.returnFocusID(in: original) == session.item.id)
        session.previewRemoval()
        #expect(session.apply(current: original, generation: 7, commit: committed))
        #expect(session.returnFocusID(in: try #require(session.saved)) == "summary-section")
        #expect(session.undo(current: session.saved, generation: 7, commit: committed))
        #expect(session.returnFocusID(in: try #require(session.saved)) == session.item.id)
        var newer = original
        newer.personalNotes += " New writing."
        #expect(session.returnFocusID(in: newer) == "summary-section")
    }

    @Test
    func saveFailureKeepsOriginalAndReviewedProposal() throws {
        let original = note()
        let session = try review(original)
        session.previewRemoval()
        var attempted = false
        #expect(!session.apply(current: original, generation: 7) { _ in
            attempted = true
            throw CancellationError()
        })
        #expect(attempted)
        #expect(session.saved == nil)
        #expect(session.previewsRemoval)
    }

    @Test
    func incompleteRecordingNoticeCannotBeRemovedAsAGeneratedClaim() throws {
        var original = note()
        original.summary = MeetingCoordinator.liveCaptionNoteMarker + "\n\n" + source
        let items = SummaryReviewItem.sentences(in: original.summary)
        let notice = try #require(items.first)
        #expect(!notice.isCurrent(in: original))
        #expect(throws: SummaryReviewError.self) { try notice.replacing(in: original, with: nil) }
        #expect(items.last?.isCurrent(in: original) == true)
    }

    @Test(arguments: [false, true])
    func canceledOrTimedOutUncooperativeGenerationCannotPublish(timeout: Bool) async throws {
        let original = note()
        let runner = ReviewGeneratorGate()
        let session = try review(original, timeout: timeout ? 0.02 : 45, generator: { _ in await runner.run() })
        session.load(); await session.waitForWork()
        session.propose(passage: session.passages.first, feedback: "Correct")
        await runner.waitUntilStarted()
        if !timeout { session.invalidateProposal() }
        await session.waitForWork()
        #expect(!session.isGenerating)
        #expect(session.proposal == nil)
        if timeout { #expect(session.message == SummaryReviewError.timedOut.localizedDescription) }
        await runner.finish(.init(replacement: source, quote: source))
        for _ in 0..<20 { await Task.yield() }
        #expect(session.proposal == nil)
        #expect(session.saved == nil)
    }
}

private actor ReviewGeneratorGate {
    private var continuation: CheckedContinuation<SummaryCorrectionOutput, Never>?
    func run() async -> SummaryCorrectionOutput {
        await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilStarted() async {
        while continuation == nil { await Task.yield() }
    }
    func finish(_ output: SummaryCorrectionOutput) {
        continuation?.resume(returning: output)
        continuation = nil
    }
}
