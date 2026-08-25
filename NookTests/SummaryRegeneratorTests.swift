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

        func record(fallbackTitle: String) {
            lock.lock()
            defer { lock.unlock() }
            calls += 1
            self.fallbackTitle = fallbackTitle
        }
    }

    private struct StubSummarizer: FailureReportingSummarizing {
        let result: SummaryResult
        let recorder: StubRecorder

        func summarizeReportingFailure(
            transcript: [TranscriptSegment],
            fallbackTitle: String,
            onStage: SummaryStageHandler?
        ) async -> SummaryResult {
            recorder.record(fallbackTitle: fallbackTitle)
            await onStage?(.condensing(part: 2, total: 5))
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

    // MARK: A failed pass

    @Test
    func aFailedPassNamesTheReasonAndKeepsTheNote() async {
        let recorder = StubRecorder()
        let note = meetingNote()
        let outcome = await SummaryRegenerator.regenerate(
            note,
            using: failingSummarizer(recorder: recorder, reason: .modelBusy)
        )

        #expect(outcome == .retained(reason: .modelBusy))
        #expect(recorder.calls == 1)
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
        #expect(stages == [.condensing(part: 2, total: 5), .writingUp])
    }

    private struct FailingStubWithStages: FailureReportingSummarizing {
        func summarizeReportingFailure(
            transcript: [TranscriptSegment],
            fallbackTitle: String,
            onStage: SummaryStageHandler?
        ) async -> SummaryResult {
            await onStage?(.condensing(part: 2, total: 5))
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
            RegenerationCopy.headline(for: .condensing(part: 3, total: 21))
                == "Re-reading this conversation"
        )
        #expect(
            RegenerationCopy.detail(for: .condensing(part: 3, total: 21))
                == "Part 3 of 21"
        )
        #expect(
            RegenerationCopy.detail(for: .condensing(part: 0, total: 0))
                == "Reading your transcript"
        )
        #expect(
            RegenerationCopy.headline(for: .writingUp) == "Writing up what it heard"
        )
        #expect(RegenerationCopy.detail(for: .writingUp) == "Nearly there")
    }
}


private actor StageCollector {
    private(set) var stages: [SummaryStage] = []
    func append(_ stage: SummaryStage) { stages.append(stage) }
}
