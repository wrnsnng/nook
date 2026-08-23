import AVFoundation
import Foundation

/// Assembles an appended recording session into an existing note.
///
/// Both ways of growing a note funnel through here: recording into a note
/// again, and merging another saved note in. The rules are the same either
/// way, which is the point: one continuous transcript timeline, moments that
/// stay valid against kept audio, and personal notes that are never rewritten.
enum NoteSessionAppend {
    /// Everything a finished sitting contributes.
    struct Material: Sendable {
        let startedAt: Date
        let endedAt: Date
        /// Coalesced segments on the session's own clock, starting at zero.
        let transcript: [TranscriptSegment]
        /// Offsets flagged live, on the session's own clock.
        let moments: [MeetingMoment]
        /// Notes typed while this sitting was live.
        let personalNotes: String
    }

    /// Where appended material begins on the target note's timeline.
    ///
    /// The caller passes the duration of the note's kept audio when that file
    /// exists, because audio time is the clock moments play back against and
    /// trailing silence makes the transcript slightly shorter than the audio.
    /// Without kept audio the transcript extent is the best remaining measure,
    /// falling back to wall-clock sittings and finally to the overall span.
    static func continuationOffset(
        for note: MeetingNote,
        priorAudioDuration: TimeInterval?
    ) -> TimeInterval {
        if let priorAudioDuration, priorAudioDuration > 0 {
            return priorAudioDuration
        }
        let extent = note.transcriptExtent
        if extent > 0 {
            return extent
        }
        if !note.sessions.isEmpty {
            return note.sessions.reduce(0) { $0 + $1.duration }
        }
        return note.duration
    }

    /// Builds the combined note.
    ///
    /// - Parameters:
    ///   - note: the note being grown. Spoken notes are promoted by the
    ///     caller before calling; this type only assembles meeting-shaped
    ///     content.
    ///   - material: the finished sitting being appended.
    ///   - offset: where `material` begins on the timeline, from
    ///     `continuationOffset`.
    ///   - audioStart: where kept audio begins on the combined timeline.
    ///     Zero whenever earlier audio exists or was adopted; positive only
    ///     when the appended session's own audio starts partway along.
    ///   - newSessions: recorded sittings the material consists of. Defaults
    ///     to the material's whole span as one sitting; a merge passes every
    ///     sitting of the note being folded in.
    static func appending(
        material: Material,
        to note: MeetingNote,
        offset: TimeInterval,
        audioStart: TimeInterval,
        newSessions: [MeetingSession]? = nil
    ) -> MeetingNote {
        var combined = note

        combined.transcript = TranscriptAssembler.coalesce(
            note.transcript
                + material.transcript.map { segment in
                    TranscriptSegment(
                        startTime: segment.startTime + offset,
                        duration: segment.duration,
                        text: segment.text,
                        source: segment.source
                    )
                }
        )
        combined.moments = note.moments
            + material.moments.map { moment in
                MeetingMoment(offset: moment.offset + offset)
            }

        var sessions = normalizedSessions(of: note)
        sessions.append(
            contentsOf: newSessions ?? [
                MeetingSession(
                    startedAt: material.startedAt,
                    endedAt: material.endedAt
                )
            ]
        )
        combined.sessions = sessions
        combined.audioStart = max(0, audioStart)
        combined.endedAt = max(note.endedAt, material.endedAt)

        let freshNotes = material.personalNotes
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !freshNotes.isEmpty {
            let existing = note.personalNotes
                .trimmingCharacters(in: .whitespacesAndNewlines)
            combined.personalNotes = existing.isEmpty
                ? freshNotes
                : existing + "\n\n" + freshNotes
        }
        return combined
    }

    /// A note without stored sessions is treated as one sitting spanning its
    /// whole envelope, so divider placement and durations work identically
    /// for legacy files.
    static func normalizedSessions(of note: MeetingNote) -> [MeetingSession] {
        if note.sessions.isEmpty {
            return [
                MeetingSession(
                    startedAt: note.startedAt,
                    endedAt: note.endedAt
                )
            ]
        }
        return note.sessions
    }

    /// Joins two notes' free text chronologically without losing a word.
    static func joinedPersonalNotes(_ parts: String...) -> String {
        parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    /// Duration of a kept audio file, or nil when it cannot be read. A file
    /// whose duration cannot be measured also cannot be trusted as the join
    /// point of a timeline, so callers treat nil as "no usable audio".
    static func audioDuration(of url: URL) async -> TimeInterval? {
        let asset = AVURLAsset(url: url)
        guard
            let duration = try? await asset.load(.duration),
            duration.isValid,
            duration.seconds.isFinite,
            duration.seconds > 0
        else {
            return nil
        }
        return duration.seconds
    }

    /// Promotes a spoken note in place to meeting shape, moving its prose
    /// into personal notes where free text belongs.
    static func promoteSpokenToMeeting(_ note: inout MeetingNote) {
        guard note.kind == .spoken else { return }
        note.kind = .meeting
        note.personalNotes = joinedPersonalNotes(
            note.summary,
            note.personalNotes
        )
        note.summary = ""
    }
}
