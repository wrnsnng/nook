import Foundation
import Testing
@testable import Nook

/// A note can hold several recorded sittings: recording into it again or
/// merging another note in appends to one continuous timeline, keeps personal
/// notes untouched, and stays a plain Markdown file older versions can read.
@MainActor
struct MultiSessionTests {
    // MARK: Building blocks

    private func segment(
        at seconds: TimeInterval,
        text: String,
        source: TranscriptSegment.Source = .mixed
    ) -> TranscriptSegment {
        TranscriptSegment(
            startTime: seconds,
            duration: 3,
            text: text,
            source: source
        )
    }

    /// One sitting: speech in the first half minute, a flag, a personal note.
    private func singleSessionNote() -> MeetingNote {
        MeetingNote(
            title: "Design review",
            startedAt: Date(timeIntervalSince1970: 1_000_000),
            endedAt: Date(timeIntervalSince1970: 1_000_600),
            sourceApp: "Zoom",
            summary: "The first sitting.",
            personalNotes: "Check the budget.",
            transcript: [
                segment(at: 0, text: "Morning."),
                segment(at: 30, text: "Agenda is short.", source: .microphone)
            ],
            moments: [MeetingMoment(offset: 12)]
        )
    }

    private func material(
        startedAt: Date,
        endedAt: Date,
        segments: [TranscriptSegment],
        moments: [MeetingMoment] = [],
        personalNotes: String = ""
    ) -> NoteSessionAppend.Material {
        NoteSessionAppend.Material(
            startedAt: startedAt,
            endedAt: endedAt,
            transcript: segments,
            moments: moments,
            personalNotes: personalNotes
        )
    }

    // MARK: Continuation offsets

    /// With kept audio, its duration decides where appended material begins:
    /// trailing silence makes audio longer than the transcript, and moments
    /// play back against the audio clock.
    @Test
    func keptAudioDurationWinsAsTheContinuationPoint() {
        let offset = NoteSessionAppend.continuationOffset(
            for: singleSessionNote(),
            priorAudioDuration: 655
        )

        #expect(offset == 655)
    }

    @Test
    func withoutKeptAudioTheTranscriptExtentIsTheContinuationPoint() {
        let offset = NoteSessionAppend.continuationOffset(
            for: singleSessionNote(),
            priorAudioDuration: nil
        )

        #expect(offset == 33)
    }

    @Test
    func aNoteWithoutSpeechFallsBackToItsWallClockSpan() {
        let note = MeetingNote(
            title: "Quiet",
            startedAt: Date(timeIntervalSince1970: 1_000_000),
            endedAt: Date(timeIntervalSince1970: 1_000_900),
            sourceApp: "Manual",
            summary: ""
        )

        let offset = NoteSessionAppend.continuationOffset(
            for: note,
            priorAudioDuration: nil
        )

        #expect(offset == 900)
    }

    // MARK: Assembly

    @Test
    func appendingShiftsTranscriptMomentsAndExtendsTheNote() throws {
        let note = singleSessionNote()
        let material = material(
            startedAt: Date(timeIntervalSince1970: 1_003_600),
            endedAt: Date(timeIntervalSince1970: 1_004_000),
            segments: [
                segment(at: 5, text: "Back again."),
                segment(at: 45, text: "Where were we?", source: .microphone)
            ],
            moments: [MeetingMoment(offset: 4)],
            personalNotes: "Follow up tomorrow."
        )

        let combined = NoteSessionAppend.appending(
            material: material,
            to: note,
            offset: 33,
            audioStart: 0
        )

        // The sitting's words continue exactly where the timeline ended.
        #expect(combined.transcript.count == 4)
        #expect(combined.transcript.last?.text == "Where were we?")
        #expect(combined.transcript.last?.startTime == 78)
        #expect(combined.transcript[2].startTime == 38)
        // Flagged moments play back against the joined audio.
        #expect(combined.moments.map(\.offset) == [12, 37])
        // Personal notes are appended to, never replaced.
        #expect(
            combined.personalNotes == "Check the budget.\n\nFollow up tomorrow."
        )
        #expect(combined.endedAt == material.endedAt)
        #expect(combined.startedAt == note.startedAt)
        #expect(combined.sessions.count == 2)
        #expect(combined.sessions[1].duration == 400)
    }

    @Test
    func aMultiSittingNoteSumsItsDurationsInsteadOfItsSpan() {
        var note = singleSessionNote()
        note.sessions = [
            MeetingSession(
                startedAt: Date(timeIntervalSince1970: 1_000_000),
                endedAt: Date(timeIntervalSince1970: 1_000_600)
            ),
            MeetingSession(
                startedAt: Date(timeIntervalSince1970: 1_003_600),
                endedAt: Date(timeIntervalSince1970: 1_003_900)
            )
        ]

        // The wall-clock span includes the break between sittings; the
        // listening time must not.
        #expect(note.duration == 900)
    }

    // MARK: File format

    private func twoSittingNote() -> MeetingNote {
        var note = singleSessionNote()
        note.sessions = [
            MeetingSession(
                startedAt: note.startedAt,
                endedAt: note.startedAt.addingTimeInterval(40)
            ),
            MeetingSession(
                startedAt: Date(timeIntervalSince1970: 1_003_600),
                endedAt: Date(timeIntervalSince1970: 1_003_660)
            )
        ]
        note.transcript.append(segment(at: 50, text: "Back again."))
        return note
    }

    @Test
    func multiSessionFilesCarrySessionsAndDividers() throws {
        let markdown = MarkdownCodec.encode(twoSittingNote())

        #expect(markdown.contains("sessions: "))
        #expect(markdown.contains("- *(resumed "))
        // The divider sits where the second sitting begins, after everything
        // the first sitting said and before its first line.
        let lines = markdown.split(separator: "\n").map(String.init)
        let dividerIndex = try #require(
            lines.firstIndex { $0.hasPrefix("- *(resumed") }
        )
        let appendedIndex = try #require(
            lines.firstIndex { $0.contains("Back again.") }
        )
        let lastFirstSittingIndex = try #require(
            lines.lastIndex { $0.contains("Agenda is short.") }
        )
        #expect(lastFirstSittingIndex < dividerIndex)
        #expect(dividerIndex < appendedIndex)
        #expect(!markdown.contains("audioStart:"))
    }

    @Test
    func aLegacySingleSessionFileStaysUnchanged() {
        let markdown = MarkdownCodec.encode(singleSessionNote())

        #expect(!markdown.contains("sessions:"))
        #expect(!markdown.contains("resumed"))
    }

    @Test
    func anAppendedFileWithoutEarlierAudioRecordsWhereAudioBegins() {
        var note = singleSessionNote()
        note.audioStart = 13

        let markdown = MarkdownCodec.encode(note)

        #expect(markdown.contains("audioStart: 13.0"))
    }

    @Test
    func sessionsAndDividersRoundTrip() throws {
        let decoded = try #require(
            MarkdownCodec.decode(MarkdownCodec.encode(twoSittingNote()))
        )

        #expect(decoded.sessions.count == 2)
        #expect(decoded.sessions[0].duration == 40)
        #expect(decoded.sessions[1].duration == 60)
        // Dividers are presentation between sittings; they never become
        // transcript content on the way back in.
        #expect(decoded.transcript.count == 3)
        #expect(decoded.transcript.allSatisfy { !$0.text.contains("resumed") })
    }

    @Test
    func handMovedDividerLinesStillDecodeAsFurniture() throws {
        var markdown = MarkdownCodec.encode(twoSittingNote())
        // Someone edited the file by hand and changed the divider; decoding
        // still refuses to turn it into a spoken line.
        markdown = markdown.replacingOccurrences(
            of: "- *(resumed ",
            with: "- *resumed "
        )

        let decoded = try #require(MarkdownCodec.decode(markdown))

        #expect(decoded.sessions.count == 2)
        #expect(decoded.transcript.count == 3)
    }

    // MARK: Spoken-note promotion

    @Test
    func recordingIntoASpokenNotePromotesItWithoutLosingProse() {
        var spoken = MeetingNote(
            kind: .spoken,
            title: "Ideas",
            startedAt: Date(timeIntervalSince1970: 1_000_000),
            endedAt: Date(timeIntervalSince1970: 1_000_030),
            sourceApp: "Spoken note",
            summary: "Build the thing slowly."
        )
        NoteSessionAppend.promoteSpokenToMeeting(&spoken)

        let combined = NoteSessionAppend.appending(
            material: material(
                startedAt: Date(timeIntervalSince1970: 1_003_600),
                endedAt: Date(timeIntervalSince1970: 1_003_700),
                segments: [segment(at: 0, text: "About that idea.")],
                personalNotes: "Spoke about it live."
            ),
            to: spoken,
            offset: 0,
            audioStart: 0
        )

        #expect(combined.kind == .meeting)
        #expect(
            combined.personalNotes
                == "Build the thing slowly.\n\nSpoke about it live."
        )
        #expect(combined.summary.isEmpty)
    }

    // MARK: Store deletion

    @Test
    func deletingANoteRemovesItsFileAndLeavesTheRest() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent(
                "NookMultiSession-\(UUID().uuidString)",
                isDirectory: true
            )
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? fileManager.removeItem(at: directory) }

        let store = MarkdownStore()
        store.storageURL = directory
        let keeper = try store.save(singleSessionNote())
        let doomed = try store.save(
            MeetingNote(
                title: "Doomed",
                startedAt: Date(timeIntervalSince1970: 1_001_000),
                endedAt: Date(timeIntervalSince1970: 1_001_100),
                sourceApp: "Manual",
                summary: ""
            )
        )

        #expect(store.delete(doomed))
        #expect(fileManager.fileExists(atPath: keeper.fileURL!.path))
        #expect(!fileManager.fileExists(atPath: doomed.fileURL!.path))
        #expect(!store.notes.contains { $0.id == doomed.id })
        #expect(store.notes.contains { $0.id == keeper.id })
    }
}
