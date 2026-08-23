import Foundation
import Testing
@testable import Nook

/// Decoding used to hand every transcript segment a fresh random UUID, so
/// reloading an unchanged note (another save elsewhere, a relaunch) rebuilt
/// every row's SwiftUI identity for no reason. A segment's id must now be
/// stable across decodes of the same file, and distinct between notes.
struct TranscriptSegmentIdentityTests {
    private func note(
        id: UUID = UUID(),
        segments: [TranscriptSegment]
    ) -> MeetingNote {
        MeetingNote(
            id: id,
            title: "Standup",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_001_800),
            sourceApp: "Zoom",
            summary: "A quick sync.",
            transcript: segments
        )
    }

    @Test
    func decodingTheSameFileTwiceProducesTheSameSegmentIDs() throws {
        let segments = [
            TranscriptSegment(
                startTime: 5,
                duration: 3,
                text: "Let's get started.",
                source: .microphone
            )
        ]
        let markdown = MarkdownCodec.encode(note(segments: segments))

        let first = try #require(MarkdownCodec.decode(markdown))
        let second = try #require(MarkdownCodec.decode(markdown))

        #expect(first.transcript.count == 1)
        #expect(second.transcript.count == 1)
        #expect(first.transcript[0].id == second.transcript[0].id)
    }

    @Test
    func theSameTranscriptLineInADifferentNoteGetsADifferentID() throws {
        let segments = [
            TranscriptSegment(
                startTime: 5,
                duration: 3,
                text: "Let's get started.",
                source: .microphone
            )
        ]
        let first = try #require(
            MarkdownCodec.decode(MarkdownCodec.encode(note(segments: segments)))
        )
        let second = try #require(
            MarkdownCodec.decode(MarkdownCodec.encode(note(segments: segments)))
        )

        #expect(first.id != second.id)
        #expect(first.transcript[0].id != second.transcript[0].id)
    }

    @Test
    func twoDifferentLinesInOneNoteGetDifferentIDs() throws {
        let segments = [
            TranscriptSegment(
                startTime: 5,
                duration: 3,
                text: "First line.",
                source: .microphone
            ),
            TranscriptSegment(
                startTime: 45,
                duration: 3,
                text: "Second line.",
                source: .microphone
            )
        ]
        let markdown = MarkdownCodec.encode(note(segments: segments))

        let decoded = try #require(MarkdownCodec.decode(markdown))

        #expect(decoded.transcript.count == 2)
        #expect(decoded.transcript[0].id != decoded.transcript[1].id)
    }
}
