import Foundation

/// Decides which separated voice said each transcript passage, from time
/// overlap alone. Deterministic and pure: it never reads audio or text, so it
/// cannot invent a speaker the diarization did not find.
///
/// Diarization and transcription are independent passes over the same audio,
/// so their boundaries rarely agree. A passage is assigned to the speaker whose
/// turns cover most of it; a passage no turn touches stays unassigned rather
/// than being given to the nearest voice.
enum SpeakerAttribution {
    /// Which audio the turns were computed from. It decides which passages
    /// share their timeline and can therefore be attributed.
    enum DiarizedAudio: Sendable {
        /// The remote-only system-audio track preserved by the source package.
        /// Only `.system` passages were heard on it. A `.mixed` passage may be
        /// the user speaking into the microphone, and a system-track turn that
        /// happens to overlap it in time is no evidence of who that was.
        case systemTrack
        /// A single mixed recording, for notes captured without separate
        /// sources. `.mixed` passages come from this very audio, so an overlap
        /// is evidence. The user's voice is one of the separated speakers
        /// there, which is the caller's to present; this type only reports
        /// overlap.
        case mixedRecording
    }

    /// Maps each attributable passage to the 0-based speaker whose turns
    /// overlap it for the longest total time.
    ///
    /// - Microphone passages are always the user and never appear in the
    ///   result, whatever `audio` says.
    /// - A passage with no overlapping turn is left out, not guessed.
    /// - A zero-length passage belongs to the turn it falls inside.
    /// - Equal overlap goes to the speaker already talking when the passage
    ///   began (the earliest overlapping turn), then to the lower number, so
    ///   the same input always yields the same labels.
    /// - Turns with non-finite, negative or empty spans are ignored. They come
    ///   from a model and are not trusted.
    static func assign(
        segments: [TranscriptSegment],
        turns: [SpeakerTurn],
        audio: DiarizedAudio
    ) -> [UUID: Int] {
        let usable = turns.filter(\.isUsable)
        guard !usable.isEmpty else { return [:] }

        var result: [UUID: Int] = [:]
        for segment in segments where isAttributable(segment.source, audio: audio) {
            if let speaker = speaker(for: segment, among: usable) {
                result[segment.id] = speaker
            }
        }
        return result
    }

    /// Renumbers speakers so the first voice heard in the transcript is 0, the
    /// next new voice 1, and so on. Diarization numbers speakers by the audio,
    /// which can differ from the order they appear among attributed passages
    /// (a speaker whose only early turn overlapped no passage, for example).
    /// Labels a reader sees should count up as they read.
    ///
    /// Passages are read in time order; equal start times keep transcript
    /// order. Speakers with no passage are dropped, so the numbers stay dense.
    static func renumberedByFirstAppearance(
        _ assignments: [UUID: Int],
        in segments: [TranscriptSegment]
    ) -> [UUID: Int] {
        let ordered = segments.enumerated().sorted { lhs, rhs in
            lhs.element.startTime == rhs.element.startTime
                ? lhs.offset < rhs.offset
                : lhs.element.startTime < rhs.element.startTime
        }
        var renumbering: [Int: Int] = [:]
        var result: [UUID: Int] = [:]
        for (_, segment) in ordered {
            guard let speaker = assignments[segment.id] else { continue }
            let number: Int
            if let existing = renumbering[speaker] {
                number = existing
            } else {
                number = renumbering.count
                renumbering[speaker] = number
            }
            result[segment.id] = number
        }
        return result
    }

    private static func isAttributable(
        _ source: TranscriptSegment.Source,
        audio: DiarizedAudio
    ) -> Bool {
        switch (source, audio) {
        case (.microphone, _): false
        case (.system, _): true
        case (.mixed, .mixedRecording): true
        case (.mixed, .systemTrack): false
        }
    }

    private static func speaker(
        for segment: TranscriptSegment,
        among turns: [SpeakerTurn]
    ) -> Int? {
        let start = segment.startTime
        let end = segment.startTime + segment.duration
        guard start.isFinite, end.isFinite, end >= start else { return nil }

        if end == start {
            return turns
                .filter { $0.start <= start && start < $0.end }
                .min { ($0.start, $0.speaker) < ($1.start, $1.speaker) }?
                .speaker
        }

        // Total overlap per speaker, and where each speaker's overlap began.
        var overlap: [Int: (total: TimeInterval, firstStart: TimeInterval)] = [:]
        for turn in turns {
            let shared = min(end, turn.end) - max(start, turn.start)
            guard shared > 0 else { continue }
            let from = max(start, turn.start)
            if let existing = overlap[turn.speaker] {
                overlap[turn.speaker] = (existing.total + shared, min(existing.firstStart, from))
            } else {
                overlap[turn.speaker] = (shared, from)
            }
        }
        return overlap.min { lhs, rhs in
            if lhs.value.total != rhs.value.total { return lhs.value.total > rhs.value.total }
            if lhs.value.firstStart != rhs.value.firstStart {
                return lhs.value.firstStart < rhs.value.firstStart
            }
            return lhs.key < rhs.key
        }?.key
    }
}

private extension SpeakerTurn {
    var isUsable: Bool {
        start.isFinite && end.isFinite && start >= 0 && end > start && speaker >= 0
    }
}
