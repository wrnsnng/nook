import Foundation
import Testing
@testable import Nook

/// Regenerating a summary asks the model again over a transcript the note
/// already holds, and risks nothing else: the five generated fields are
/// replaced, every other part of the note passes through untouched, and a
/// second failure leaves the note exactly as it was while naming why.
struct SummaryRegeneratorTests {
    /// Counts summarize attempts and remembers what was asked for, so tests
    /// can assert regeneration never reached the model at all.
    private final class StubRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var calls = 0
        private(set) var fallbackTitle: String?
        private(set) var attention: SummaryAttention?

        func record(fallbackTitle: String, attention: SummaryAttention?) {
            lock.lock()
            defer { lock.unlock() }
            calls += 1
            self.fallbackTitle = fallbackTitle
            self.attention = attention
        }
    }

    private struct StubSummarizer: FailureReportingSummarizing {
        let result: SummaryResult
        let recorder: StubRecorder

        func summarizeReportingFailure(
            transcript: [TranscriptSegment],
            fallbackTitle: String,
            attention: SummaryAttention?,
            onStage: SummaryStageHandler?
        ) async -> SummaryResult {
            recorder.record(fallbackTitle: fallbackTitle, attention: attention)
            await onStage?(.condensing(pass: 1, part: 2, total: 5))
            await onStage?(.writingUp)
            return result
        }
    }

    private func successfulSummarizer(
        recorder: StubRecorder,
        title: String = "Q3 planning"
    ) -> StubSummarizer {
        StubSummarizer(
            result: SummaryResult(
                insights: MeetingInsights(
                    title: title,
                    summary: "The team planned the third quarter.",
                    keyPoints: ["Launch moves to October"],
                    decisions: ["October launch"],
                    actionItems: ["Draft the rollout plan"]
                ),
                failure: nil
            ),
            recorder: recorder
        )
    }

    private func failingSummarizer(
        recorder: StubRecorder,
        reason: SummaryService.FailureReason
    ) -> StubSummarizer {
        StubSummarizer(
            result: SummaryResult(
                insights: SummaryService.fallbackInsights(
                    transcript: [],
                    fallbackTitle: "irrelevant",
                    reason: reason
                ),
                failure: reason
            ),
            recorder: recorder
        )
    }

    private func meetingNote() -> MeetingNote {
        MeetingNote(
            kind: .meeting,
            title: "Planning sync",
            startedAt: Date(timeIntervalSince1970: 1_770_000_000),
            endedAt: Date(timeIntervalSince1970: 1_770_001_800),
            sourceApp: "Manual",
            summary:
                "Nook couldn’t generate a structured summary. Transcript highlights: hello",
            personalNotes: "Ask Ana about the budget",
            transcript: [
                TranscriptSegment(
                    startTime: 0,
                    duration: 6,
                    text: "We agreed the launch moves to October.",
                    source: .mixed
                )
            ],
            moments: [MeetingMoment(offset: 12)],
            sessions: [
                MeetingSession(
                    startedAt: Date(timeIntervalSince1970: 1_770_000_000),
                    endedAt: Date(timeIntervalSince1970: 1_770_001_800)
                )
            ],
            fileURL: URL(fileURLWithPath: "/tmp/note.md"),
            fileModified: Date(timeIntervalSince1970: 1_770_001_900)
        )
    }

    // MARK: Availability

    @Test
    func meetingNoteWithTranscriptOffersRegeneration() {
        #expect(SummaryRegenerator.isAvailable(for: meetingNote()))
    }

    @Test
    func spokenNotesOfferNoRegeneration() {
        var note = meetingNote()
        note.kind = .spoken
        #expect(!SummaryRegenerator.isAvailable(for: note))
    }

    @Test
    func digestsOfferNoRegeneration() {
        var note = meetingNote()
        note.kind = .digest
        #expect(!SummaryRegenerator.isAvailable(for: note))
    }

    @Test
    func meetingsWithoutTranscriptOfferNoRegeneration() {
        var note = meetingNote()
        note.transcript = []
        #expect(!SummaryRegenerator.isAvailable(for: note))
    }

    // MARK: A successful pass

    @Test
    func regeneratedNoteCarriesTheNewWriteUp() async {
        let recorder = StubRecorder()
        let note = meetingNote()
        let outcome = await SummaryRegenerator.regenerate(
            note,
            using: successfulSummarizer(recorder: recorder)
        )

        guard case .regenerated(let updated) = outcome else {
            Issue.record("Expected regeneration, got \(outcome)")
            return
        }
        #expect(updated.title == "Q3 planning")
        #expect(updated.summary == "The team planned the third quarter.")
        #expect(updated.keyPoints == ["Launch moves to October"])
        #expect(updated.decisions == ["October launch"])
        #expect(updated.actionItems == ["Draft the rollout plan"])
        #expect(recorder.fallbackTitle == "Planning sync")
    }

    @Test
    func regenerationPassesCurrentNotesAndFlaggedContextToSummarizer() async {
        let recorder = StubRecorder()
        let note = meetingNote()

        _ = await SummaryRegenerator.regenerate(
            note,
            using: successfulSummarizer(recorder: recorder)
        )

        #expect(recorder.attention?.myNotes == note.personalNotes)
        #expect(recorder.attention?.flaggedMoments.count == 1)
        #expect(
            recorder.attention?.flaggedMoments.first?.segments.map(\.text)
                == note.transcript.map(\.text)
        )
    }

    @Test
    func regenerationChangesNothingTheModelDoesNotOwn() async {
        let recorder = StubRecorder()
        let note = meetingNote()
        guard case .regenerated(let updated) = await SummaryRegenerator.regenerate(
            note,
            using: successfulSummarizer(recorder: recorder)
        ) else {
            Issue.record("Expected regeneration")
            return
        }

        #expect(updated.id == note.id)
        #expect(updated.personalNotes == note.personalNotes)
        #expect(updated.transcript == note.transcript)
        #expect(updated.moments == note.moments)
        #expect(updated.sessions == note.sessions)
        #expect(updated.fileURL == note.fileURL)
        #expect(updated.fileModified == note.fileModified)
    }

    /// The current title is handed over as the fallback so a model that
    /// cannot find a subject leaves the note named the way the user knows it.
    @Test
    func regenerationFallsBackToTheExistingTitle() async {
        let recorder = StubRecorder()
        var note = meetingNote()
        note.title = "Renamed by hand"
        _ = await SummaryRegenerator.regenerate(
            note,
            using: successfulSummarizer(recorder: recorder, title: "Meeting")
        )
        #expect(recorder.fallbackTitle == "Renamed by hand")
    }

    /// A tick whose item survives the rewrite stays ticked, the same promise
    /// a rename makes; ticks for items the model dropped go with them.
    @Test
    func completedItemsKeepTheirTicksOnlyWhenTheySurvive() async {
        let recorder = StubRecorder()
        var note = meetingNote()
        note.completedActionItems = ["Draft the rollout plan", "Book a room"]
        guard case .regenerated(let updated) = await SummaryRegenerator.regenerate(
            note,
            using: successfulSummarizer(recorder: recorder)
        ) else {
            Issue.record("Expected regeneration")
            return
        }
        #expect(updated.completedActionItems == ["Draft the rollout plan"])
    }

    /// A long regeneration starts from one snapshot of the note. Only the
    /// generated fields may come from that snapshot; edits made while the
    /// model was working must come from the latest stored value.
    @Test
    func completedRegenerationMergesIntoTheFreshestNote() {
        let original = meetingNote()
        var regenerated = original
        regenerated.title = "New model title"
        regenerated.summary = "New model summary"
        regenerated.keyPoints = ["New fact"]
        regenerated.decisions = ["New decision"]
        regenerated.actionItems = ["Still active", "New action"]

        var latest = original
        latest.personalNotes = "Written while regeneration ran"
        latest.moments.append(MeetingMoment(offset: 42))
        latest.completedActionItems = ["Still active", "Removed action"]
        latest.fileModified = Date(timeIntervalSince1970: 1_770_002_500)

        let merged = SummaryRegenerator.mergingGeneratedFields(
            from: regenerated,
            startingFrom: original,
            into: latest
        )

        #expect(merged.title == "New model title")
        #expect(merged.summary == "New model summary")
        #expect(merged.keyPoints == ["New fact"])
        #expect(merged.decisions == ["New decision"])
        #expect(merged.actionItems == ["Still active", "New action"])
        #expect(merged.personalNotes == "Written while regeneration ran")
        #expect(merged.moments == latest.moments)
        #expect(merged.fileModified == latest.fileModified)
        #expect(merged.completedActionItems == ["Still active"])
    }

    @Test
    func explicitTitleRenameWinsOverAStaleRegenerationResult() {
        let starting = meetingNote()
        var regenerated = starting
        regenerated.title = "Model title"
        regenerated.summary = "Fresh model summary"

        var latest = starting
        latest.title = "Renamed while regeneration ran"

        let merged = SummaryRegenerator.mergingGeneratedFields(
            from: regenerated,
            startingFrom: starting,
            into: latest
        )

        #expect(merged.title == latest.title)
        #expect(merged.summary == regenerated.summary)
    }

    @Test(arguments: [false, true])
    func canonicalEquivalentConcurrentEditsRemainExactInEveryGeneratedField(reverse: Bool) {
        let composed = "Caf\u{00e9} review"
        let decomposed = "Cafe\u{0301} review"
        let before = reverse ? decomposed : composed
        let after = reverse ? composed : decomposed
        #expect(before == after)
        #expect(Data(before.utf8) != Data(after.utf8))
        var starting = meetingNote()
        starting.title = before
        starting.summary = before
        starting.keyPoints = ["Unchanged point", before]
        starting.decisions = [before]
        starting.actionItems = [before, "Unchanged action"]
        var latest = starting
        latest.title = after
        latest.summary = after
        latest.keyPoints[1] = after
        latest.decisions[0] = after
        latest.actionItems[0] = after
        var generated = starting
        generated.title = "Generated title"
        generated.summary = "Generated summary"
        generated.keyPoints = ["Generated point"]
        generated.decisions = ["Generated decision"]
        generated.actionItems = ["Generated action"]

        let merged = SummaryRegenerator.mergingGeneratedFields(
            from: generated, startingFrom: starting, into: latest
        )

        #expect(Data(merged.title.utf8) == Data(after.utf8))
        #expect(Data(merged.summary.utf8) == Data(after.utf8))
        #expect(merged.keyPoints.map { Data($0.utf8) } == latest.keyPoints.map { Data($0.utf8) })
        #expect(merged.decisions.map { Data($0.utf8) } == latest.decisions.map { Data($0.utf8) })
        #expect(merged.actionItems.map { Data($0.utf8) } == latest.actionItems.map { Data($0.utf8) })

        // Protecting the edited title must not also block a genuinely unchanged
        // field from receiving its requested regenerated content.
        latest.summary = starting.summary
        let partlyUnchanged = SummaryRegenerator.mergingGeneratedFields(
            from: generated, startingFrom: starting, into: latest
        )
        #expect(Data(partlyUnchanged.title.utf8) == Data(after.utf8))
        #expect(partlyUnchanged.summary == generated.summary)
    }

    // MARK: A failed pass

    @Test(arguments: SummaryService.FailureReason.allCases)
    func aFailedPassNamesTheReasonAndKeepsTheNote(reason: SummaryService.FailureReason) async {
        let recorder = StubRecorder()
        let note = meetingNote()
        let outcome = await SummaryRegenerator.regenerate(
            note,
            using: failingSummarizer(recorder: recorder, reason: reason)
        )

        #expect(outcome == .retained(reason: reason))
        #expect(recorder.calls == 1)
        let message = RegenerationCopy.retainedMessage(for: reason)
        #expect(message.hasPrefix("Your existing note is unchanged."))
        #expect(!message.contains("only the transcript"))
        #expect(!message.contains("no structured summary"))
        #expect(!message.contains("without a structured summary"))
    }

    @Test
    func unavailableNotesNeverReachTheModel() async {
        var note = meetingNote()
        note.kind = .digest
        let recorder = StubRecorder()
        let outcome = await SummaryRegenerator.regenerate(
            note,
            using: successfulSummarizer(recorder: recorder)
        )

        #expect(outcome == .retained(reason: nil))
        #expect(recorder.calls == 0)
    }
}


/// Regeneration reports where it is, and the wording a waiting surface
/// shows is decided once rather than improvised per surface.
struct RegenerationStageTests {

    @Test
    func stagesReachTheHandlerInOrder() async {
        var note = MeetingNote(
            title: "Planning sync",
            startedAt: Date(timeIntervalSince1970: 0),
            endedAt: Date(timeIntervalSince1970: 300),
            sourceApp: "Manual",
            summary: "",
            transcript: [
                TranscriptSegment(startTime: 0, duration: 4, text: "We agreed.")
            ]
        )
        note.kind = .meeting

        let collected = StageCollector()
        let outcome = await SummaryRegenerator.regenerate(
            note,
            using: FailingStubWithStages()
        ) { stage in
            await collected.append(stage)
        }
        let stages = await collected.stages

        if case .retained = outcome {
            // A failure still reports the stages it reached; either outcome
            // satisfies this test, which only watches the handler.
        }
        #expect(stages == [.condensing(pass: 1, part: 2, total: 5), .writingUp])
    }

    private struct FailingStubWithStages: FailureReportingSummarizing {
        func summarizeReportingFailure(
            transcript: [TranscriptSegment],
            fallbackTitle: String,
            attention: SummaryAttention?,
            onStage: SummaryStageHandler?
        ) async -> SummaryResult {
            await onStage?(.condensing(pass: 1, part: 2, total: 5))
            await onStage?(.writingUp)
            return SummaryResult(
                insights: MeetingInsights(
                    title: "", summary: "", keyPoints: [], decisions: [], actionItems: []
                ),
                failure: .modelBusy
            )
        }
    }

    @Test
    func copyNamesEachStageForSomeoneWaiting() {
        #expect(
            RegenerationCopy.headline(for: .condensing(pass: 1, part: 3, total: 21))
                == "Re-reading this conversation"
        )
        #expect(
            RegenerationCopy.detail(for: .condensing(pass: 1, part: 3, total: 21))
                == "Part 3 of 21"
        )
        #expect(
            RegenerationCopy.detail(for: .condensing(pass: 2, part: 3, total: 4))
                == "Pass 2, part 3 of 4"
        )
        #expect(
            RegenerationCopy.detail(for: .condensing(pass: 1, part: 0, total: 0))
                == "Reading your transcript"
        )
        #expect(
            RegenerationCopy.headline(for: .writingUp) == "Writing up what it heard"
        )
        #expect(RegenerationCopy.detail(for: .writingUp) == "Nearly there")
    }

    @Test
    func aRejectedWriteUpSaysTheExistingNoteSurvivedAndFailuresKeepTheirUsefulReasons() {
        #expect(RegenerationCopy.retainedMessage(for: .ungrounded)
            == "Your existing note is unchanged. The new summary did not match the transcript.")
        let messages = SummaryService.FailureReason.allCases.map {
            RegenerationCopy.retainedMessage(for: $0)
        }
        #expect(Set(messages).count == messages.count)
        #expect(RegenerationCopy.retainedMessage(for: .appleIntelligenceOff).contains("Turn it on in System Settings"))
        #expect(RegenerationCopy.retainedMessage(for: .modelBusy).contains("Try again in a moment"))
        #expect(RegenerationCopy.retainedMessage(for: .timedOut).contains("Summarizing took too long"))
    }
}


private actor StageCollector {
    private(set) var stages: [SummaryStage] = []
    func append(_ stage: SummaryStage) { stages.append(stage) }
}
