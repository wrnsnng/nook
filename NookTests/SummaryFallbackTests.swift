import Foundation
import Testing
@testable import Nook

@MainActor
struct SummaryFallbackTests {
    private func note() -> MeetingNote {
        let transcript = [TranscriptSegment(startTime: 0, duration: 8,
            text: "The coastal pilot will launch on Friday after the accessibility review.", source: .system)]
        return MeetingNote(title: "Synthetic review", startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 108), sourceApp: "Synthetic",
            summary: SummaryService.fallbackInsights(transcript: transcript, fallbackTitle: "Synthetic review").summary,
            summaryPending: .initial, summaryProvenance: .transcriptHighlights,
            personalNotes: "My Cafe\u{301} notes remain mine.", transcript: transcript)
    }

    @Test(arguments: SummaryProvenance.allCases)
    func fallbackProvenanceSurvivesMarkdownAndIsSeparateFromPending(provenance: SummaryProvenance) throws {
        var original = note()
        original.summaryProvenance = provenance
        original.summaryPending = nil
        let markdown = MarkdownCodec.encode(original)
        #expect(markdown.contains("summary_origin: \(provenance.rawValue)"))
        let reopened = try #require(MarkdownCodec.decode(markdown))
        #expect(reopened.summaryProvenance == provenance)
        #expect(reopened.summaryPending == nil)
        #expect(reopened.summary.utf8.elementsEqual(original.summary.utf8))
        #expect(SummaryFallback.title(for: provenance).contains("summary") || provenance == .editedFallback)
    }

    @Test(arguments: SummaryService.FailureReason.allCases)
    func exactLegacyFallbacksAcquireProvenanceWithoutNeedingAModel(reason: SummaryService.FailureReason) throws {
        var original = note()
        original.summaryPending = nil
        original.summaryProvenance = nil
        original.summary = SummaryService.fallbackInsights(
            transcript: original.transcript, fallbackTitle: original.title, reason: reason
        ).summary
        let markdown = MarkdownCodec.encode(original)
        #expect(!markdown.contains("summary_origin:"))
        let reopened = try #require(MarkdownCodec.decode(markdown))
        #expect(reopened.summaryProvenance == .transcriptHighlights)
        #expect(reopened.summaryPending == nil)
        #expect(SummaryRegenerator.isAvailable(for: reopened))
        #expect(!SummaryRegenerationSession().isRunning)
        #expect(MarkdownCodec.encode(reopened).contains("summary_origin: transcript-highlights"))
    }

    @Test
    func legacyRecoveryWarningAndPartialExtractionRemainDistinct() throws {
        var original = note()
        original.summaryProvenance = nil
        original.summary = MeetingCoordinator.liveCaptionNoteMarker + "\n\n" + original.summary
        #expect(SummaryFallback.legacyProvenance(for: original) == .transcriptHighlights)
        original.summary = SummaryFallback.partialExtractionNotice
        #expect(SummaryFallback.legacyProvenance(for: original) == .partialExtraction)
        original.summary = "User wrote: " + SummaryFallback.partialExtractionNotice
        #expect(SummaryFallback.legacyProvenance(for: original) == nil)
    }

    @Test
    func diagnosticMentionsAndChangedHighlightsAreNotMigrated() {
        var original = note()
        original.summaryProvenance = nil
        original.summary = "We discussed Transcript highlights: as an interface label."
        #expect(SummaryFallback.legacyProvenance(for: original) == nil)
        original = note()
        original.summary += " New user writing."
        #expect(SummaryFallback.legacyProvenance(for: original) == nil)
    }

    @Test(arguments: [NoteKind.spoken, .digest])
    func otherNoteKindsDoNotAcquireMeetingProvenance(kind: NoteKind) throws {
        var original = note()
        original.kind = kind
        let markdown = MarkdownCodec.encode(original)
        #expect(!markdown.contains("summary_origin:"))
        #expect(try #require(MarkdownCodec.decode(markdown)).summaryProvenance == nil)
    }

    @Test(arguments: [false, true])
    func acceptedSummaryClearsOnlyItsOwnFallbackProvenance(appended: Bool) throws {
        let original = note()
        let result = SummaryResult(insights: .init(title: "New title", summary: "The pilot launches Friday.",
            keyPoints: [], decisions: [], actionItems: []))
        let accepted = try #require(appended
            ? MeetingCoordinator.mergingAppendedSessionSummary(result, scaffold: original, current: original)
            : MeetingCoordinator.mergingTranscriptFirstSummary(result, scaffold: original, current: original))
        #expect(accepted.summaryProvenance == nil)
        var edited = original
        edited.summary += " My summary correction."
        edited.summaryProvenance = .editedFallback
        let retained = try #require(appended
            ? MeetingCoordinator.mergingAppendedSessionSummary(result, scaffold: original, current: edited)
            : MeetingCoordinator.mergingTranscriptFirstSummary(result, scaffold: original, current: edited))
        #expect(retained.summary == edited.summary)
        #expect(retained.summaryProvenance == .editedFallback)
    }

    @Test
    func manualRegenerationCannotClearProvenanceOfAConcurrentEdit() {
        let original = note()
        var generated = original
        generated.summary = "The pilot launches Friday."
        generated.summaryProvenance = nil
        var edited = original
        edited.summary += " My summary correction."
        edited.summaryProvenance = .editedFallback
        let accepted = SummaryRegenerator.mergingGeneratedFields(from: generated, startingFrom: original, into: original)
        #expect(accepted.summaryProvenance == nil)
        let retained = SummaryRegenerator.mergingGeneratedFields(from: generated, startingFrom: original, into: edited)
        #expect(retained.summaryProvenance == .editedFallback)
        #expect(retained.summary == edited.summary)
    }

    @Test
    func itemReviewKeepsFallbackIdentityAndUndoRestoresTheOriginalProvenance() throws {
        var original = note()
        original.fileURL = URL(fileURLWithPath: "/synthetic/review.md")
        original.fileRevision = Data([1])
        original.keyPoints = ["A retained partial point."]
        let item = try #require(SummaryReviewItem.list(.keyPoint, index: 0, in: original))
        let session = SummaryItemReviewSession(note: original, item: item, generation: 1)
        session.previewRemoval()
        let commit: (MeetingNote) -> MeetingNote = { note in
            var saved = note
            saved.fileRevision = MeetingNote.contentRevision(Data(MarkdownCodec.encode(note).utf8))
            return saved
        }
        #expect(session.apply(current: original, generation: 1, commit: commit))
        #expect(session.saved?.summaryProvenance == .editedFallback)
        #expect(session.undo(current: session.saved, generation: 1, commit: commit))
        #expect(session.saved?.summaryProvenance == .transcriptHighlights)
    }

    @Test
    func diagnosticCopyCannotBeRemovedAsAnUnsupportedClaim() throws {
        let original = note()
        let first = try #require(SummaryReviewItem.sentences(in: original.summary).first)
        #expect(!first.isCurrent(in: original))
        #expect(throws: SummaryReviewError.self) { try first.replacing(in: original, with: nil) }
    }

    @Test
    func emptyFallbackDoesNotClaimTheConversationContainedNoActions() {
        let message = SummaryFallback.emptyStructuredMessage(provenance: .transcriptHighlights, pending: .initial)
        #expect(message.contains("transcript may still contain them"))
        #expect(!message.contains("conversation didn’t produce"))
        #expect(SummaryFallback.emptyStructuredMessage(provenance: nil, pending: .appended) == message)
        #expect(SummaryFallback.emptyStructuredMessage(provenance: nil, pending: nil).contains("write-up"))
    }

    @Test
    func reopeningFailedRetryKeepsExactBytesAndSuccessfulRetryClearsFallback() async throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("NookFallback-\(UUID().uuidString)")
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: root) }
        let store = MarkdownStore(noteLoader: { _, _ in .success((notes: [], issues: [])) })
        store.storageURL = root
        let original = try store.save(note())
        let file = try #require(original.fileURL)
        let bytes = try Data(contentsOf: file)
        let library: SummaryRegenerationSession.LibraryReader = {
            .init(directoryURL: store.storageURL, generation: store.storageGeneration, notes: store.notes)
        }
        let failed = SummaryRegenerationSession(runner: { _, _ in .retained(reason: .modelBusy) })
        let failedStart = failed.start(note: original, purpose: .forRetry(of: original),
            library: library, commit: { try store.save($0) })
        let failedTask = try #require(failedStart)
        await failedTask.value
        #expect(try Data(contentsOf: file) == bytes)
        let reopened = try #require(MarkdownCodec.decode(String(decoding: bytes, as: UTF8.self), fileURL: file))
        #expect(reopened.summaryProvenance == .transcriptHighlights)
        let success = SummaryRegenerationSession(runner: { note, _ in
            var result = note
            result.summary = "The pilot launches Friday after the accessibility review."
            result.summaryProvenance = nil
            return .regenerated(result)
        })
        let successStart = success.start(note: reopened, purpose: .forRetry(of: reopened),
            library: library, commit: { try store.save($0) })
        let successTask = try #require(successStart)
        await successTask.value
        let savedBytes = try Data(contentsOf: file)
        let saved = try #require(MarkdownCodec.decode(String(decoding: savedBytes, as: UTF8.self)))
        #expect(saved.summaryProvenance == nil)
        #expect(saved.summaryPending == nil)
        #expect(saved.personalNotes.utf8.elementsEqual(original.personalNotes.utf8))
        #expect(saved.transcript.map(\.text) == original.transcript.map(\.text))
        #expect(!String(decoding: savedBytes, as: UTF8.self).contains("summary_origin:"))
    }
}
