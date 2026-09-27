import Foundation
import Testing
@testable import Nook

/// A just-recorded note is held in memory with sub-second times and real
/// durations; the library reloads the file with whole-second stamps and no
/// durations. A reload is not an edit.
@MainActor
struct SummaryReloadStalenessTests {
    private func recorded() -> MeetingNote {
        MeetingNote(
            title: "They were forced to play for an item",
            startedAt: Date(timeIntervalSince1970: 1_790_000_000),
            endedAt: Date(timeIntervalSince1970: 1_790_000_075),
            sourceApp: "Manual",
            summary: "Transcript highlights.",
            personalNotes: "Ask about the item\n",
            transcript: [
                TranscriptSegment(startTime: 0.42, duration: 3.71, text: "They were forced to play for an item.", source: .microphone),
                TranscriptSegment(startTime: 5.87, duration: 4.25, text: "I don't think that's fair at all.", source: .system),
                TranscriptSegment(startTime: 13.9, duration: 2.6, text: "Let's raise it on Friday.", source: .microphone),
            ],
            moments: [MeetingMoment(offset: 6.43)]
        )
    }

    private func reloaded(_ note: MeetingNote) throws -> MeetingNote {
        try #require(MarkdownCodec.decode(MarkdownCodec.encode(note)))
    }

    /// The failure a real recording hit: the library reloaded the note while
    /// its summary was written, and the summary was thrown away.
    @Test
    func aReloadDuringTheSummaryIsNotAnEdit() throws {
        let inMemory = recorded()
        let fromDisk = try reloaded(inMemory)

        #expect(SummaryRegenerator.hasSameGenerationInput(inMemory, fromDisk))
        #expect(SummaryRegenerator.hasSameGenerationInput(fromDisk, inMemory))
        #expect(SummaryRegenerator.hasSameTranscriptInput(inMemory.transcript, fromDisk.transcript))
    }

    /// A real change still stops a summary written from older words.
    @Test
    func editedWordsNotesOrFlagsAreStillChanges() throws {
        let inMemory = recorded()

        var edited = try reloaded(inMemory)
        edited.transcript[1] = TranscriptSegment(
            startTime: edited.transcript[1].startTime, duration: 0,
            text: "I think that's fair.", source: .system
        )
        #expect(!SummaryRegenerator.hasSameGenerationInput(inMemory, edited))

        var notes = try reloaded(inMemory)
        notes.personalNotes = "Ask about the refund"
        #expect(!SummaryRegenerator.hasSameGenerationInput(inMemory, notes))

        var flagged = try reloaded(inMemory)
        flagged.moments.append(MeetingMoment(offset: 14.2))
        #expect(!SummaryRegenerator.hasSameGenerationInput(inMemory, flagged))
    }

    /// The saved summary is merged only when the transcript it came from is
    /// still the note's, and a reload must not make it look different.
    @Test
    func aTranscriptFirstSummaryMergesIntoTheReloadedNote() throws {
        let scaffold = recorded()
        let fromDisk = try reloaded(scaffold)
        let result = SummaryResult(insights: MeetingInsights(
            title: "Fairness of item rewards",
            summary: "The group agreed the item rule is unfair and will raise it on Friday.",
            keyPoints: [], decisions: ["Raise it on Friday"], actionItems: []
        ), failure: nil)

        let merged = try #require(
            MeetingCoordinator.mergingTranscriptFirstSummary(result, scaffold: scaffold, current: fromDisk)
        )
        #expect(merged.summary == result.insights.summary)
        #expect(merged.decisions == ["Raise it on Friday"])
    }
}
