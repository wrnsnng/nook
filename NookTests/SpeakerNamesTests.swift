import Foundation
import Testing
@testable import Nook

struct SpeakerNamesTests {
    private func transcript() -> [TranscriptSegment] {
        [
            TranscriptSegment(startTime: 0, duration: 4, text: "Shall we start?", source: .system),
            TranscriptSegment(startTime: 5, duration: 3, text: "Yes, go ahead.", source: .microphone),
            TranscriptSegment(startTime: 9, duration: 4, text: "Budget first.", source: .system),
            TranscriptSegment(startTime: 14, duration: 4, text: "I disagree.", source: .system),
        ]
    }

    /// Separation labels meeting-side lines in order of first appearance and
    /// never touches the user's own voice or lines it could not place.
    @Test
    func separationLabelsOnlyTheMeetingSide() {
        let lines = transcript()
        let labelled = SpeakerNames.apply(
            [lines[0].id: 0, lines[1].id: 1, lines[2].id: 0],
            to: lines
        )
        #expect(labelled[0].speaker == "Speaker 1")
        #expect(labelled[1].speaker == nil)
        #expect(labelled[2].speaker == "Speaker 1")
        #expect(labelled[3].speaker == nil)
        #expect(labelled[3].speakerLabel == "Meeting")
        #expect(SpeakerNames.speakers(in: labelled) == ["Speaker 1"])
    }

    /// Naming a speaker updates every line they said, and only theirs.
    @Test
    func namingASpeakerUpdatesEveryLineTheySaid() throws {
        let lines = transcript()
        let labelled = SpeakerNames.apply([lines[0].id: 0, lines[2].id: 0, lines[3].id: 1], to: lines)
        guard case .renamed(let renamed) = SpeakerNames.rename("Speaker 1", to: "  Ana  ", in: labelled) else {
            Issue.record("Expected a rename")
            return
        }
        #expect(renamed.map(\.speaker) == ["Ana", nil, "Ana", "Speaker 2"])
    }

    /// A person cannot take a source's label or another speaker's name.
    @Test
    func namesThatWouldReadBackWronglyAreRefused() {
        let lines = transcript()
        let labelled = SpeakerNames.apply([lines[0].id: 0, lines[3].id: 1], to: lines)
        #expect(SpeakerNames.rename("Speaker 1", to: "you", in: labelled) == .invalidName)
        #expect(SpeakerNames.rename("Speaker 1", to: "**", in: labelled) == .invalidName)
        #expect(SpeakerNames.rename("Speaker 1", to: "Speaker 2", in: labelled) == .nameInUse)
        #expect(SpeakerNames.sanitized("Ana: *lead*\nDesigner") == "Ana lead Designer")
    }

    /// Named speakers survive a save and reload, and older notes without a
    /// speaker list read exactly as before.
    @Test
    func speakerNamesRoundTripThroughMarkdown() throws {
        let lines = transcript()
        var labelled = SpeakerNames.apply([lines[0].id: 0, lines[2].id: 0, lines[3].id: 1], to: lines)
        if case .renamed(let named) = SpeakerNames.rename("Speaker 1", to: "Ana Silva", in: labelled) {
            labelled = named
        }
        let note = MeetingNote(
            title: "Budget",
            startedAt: Date(timeIntervalSince1970: 1_790_000_000),
            endedAt: Date(timeIntervalSince1970: 1_790_000_060),
            sourceApp: "Zoom",
            summary: "Budget talk.",
            transcript: labelled
        )
        let markdown = MarkdownCodec.encode(note)
        #expect(markdown.contains("speakers: [\"Ana Silva\",\"Speaker 2\"]"))
        #expect(markdown.contains("**Ana Silva:** Shall we start?"))
        #expect(markdown.contains("**You:** Yes, go ahead."))

        let decoded = try #require(MarkdownCodec.decode(markdown, fileURL: nil))
        #expect(decoded.transcript.map(\.speakerLabel) == ["Ana Silva", "You", "Ana Silva", "Speaker 2"])
        #expect(decoded.transcript.map(\.source) == [.system, .microphone, .system, .system])
    }

    /// Without a speaker list, a line that happens to start in bold keeps
    /// its text; only listed names are read as speakers.
    @Test
    func boldTextIsNotMistakenForASpeaker() throws {
        let markdown = """
        ---
        id: 7C1B3E6A-6E6B-4D63-9E60-2E0F1C1B5A11
        kind: meeting
        title: "Notes"
        started: 2026-09-01T10:00:00Z
        ended: 2026-09-01T10:30:00Z
        source: "Zoom"
        ---

        # Notes

        ## Transcript

        - **[00:05]** **Important:** remember the budget
        """
        let decoded = try #require(MarkdownCodec.decode(markdown, fileURL: nil))
        #expect(decoded.transcript.first?.speaker == nil)
        #expect(decoded.transcript.first?.text == "**Important:** remember the budget")
    }

    /// Two voices are never merged into one paragraph, even when close.
    @Test
    func adjacentLinesFromDifferentSpeakersStaySeparate() {
        let a = TranscriptSegment(startTime: 0, duration: 2, text: "So the plan", source: .system, speaker: "Ana")
        let b = TranscriptSegment(startTime: 2.2, duration: 2, text: "is fine", source: .system, speaker: "Leo")
        #expect(TranscriptAssembler.coalesce([a, b]).count == 2)
    }
}
