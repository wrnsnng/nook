import Foundation

/// Folds one saved note into another so a meeting that happened in pieces
/// reads as one note.
///
/// Merging is the same operation as recording into an existing note, except
/// the second sitting arrives already finished. The earlier-starting note
/// keeps its identity; the caller deletes the absorbed file after a
/// successful save.
enum NoteCombiner {
    enum AudioOutcome: Sendable {
        /// Both notes' audio was concatenated onto the target's file.
        case concatenated
        /// The target's audio covers its own material; the absorbed note's
        /// kept audio stays in the recordings folder, unreferenced.
        case targetOnly
        /// The absorbed note's audio was adopted as the target's first audio.
        case adoptedFromAbsorbed
        /// Neither note had kept audio.
        case none
    }

    struct Result: Sendable {
        let merged: MeetingNote
        let absorbed: MeetingNote
        let audioOutcome: AudioOutcome
    }

    enum CombineError: LocalizedError {
        case unsupportedKind

        var errorDescription: String? {
            switch self {
            case .unsupportedKind:
                "Digests are compiled overviews and cannot be merged."
            }
        }
    }

    static func merge(
        _ absorbed: MeetingNote,
        into target: MeetingNote,
        recordingsDirectory: URL,
        summarizer: SummaryService
    ) async throws -> Result {
        guard target.kind != .digest, absorbed.kind != .digest else {
            throw CombineError.unsupportedKind
        }
        // The earlier note wins the identity so started dates and anything
        // referring to that note survive the merge.
        let (base, incoming) = absorbed.startedAt < target.startedAt
            ? (absorbed, target)
            : (target, absorbed)

        let baseAudioURL = recordingsDirectory
            .appendingPathComponent("\(base.id.uuidString).m4a")
        let incomingAudioURL = recordingsDirectory
            .appendingPathComponent("\(incoming.id.uuidString).m4a")
        let baseAudioExists = FileManager.default.fileExists(atPath: baseAudioURL.path)
        let baseAudioDuration = baseAudioExists
            ? await NoteSessionAppend.audioDuration(of: baseAudioURL)
            : nil
        let hadUsableBaseAudio = baseAudioExists && baseAudioDuration != nil

        // Where the incoming note's timeline begins. Kept-audio length is the
        // authority when it exists; otherwise the transcript extent stands in.
        let offset = hadUsableBaseAudio
            ? base.audioStart + (baseAudioDuration ?? 0)
            : NoteSessionAppend.continuationOffset(
                for: base,
                priorAudioDuration: nil
            )

        var promotedBase = base
        NoteSessionAppend.promoteSpokenToMeeting(&promotedBase)

        // A spoken note's prose is its content; it belongs with personal
        // notes rather than being overwritten by a generated summary.
        let incomingProse = incoming.kind == .spoken ? incoming.summary : ""
        let material = NoteSessionAppend.Material(
            startedAt: incoming.startedAt,
            endedAt: incoming.endedAt,
            transcript: incoming.transcript,
            moments: incoming.moments,
            personalNotes: NoteSessionAppend.joinedPersonalNotes(
                incomingProse,
                incoming.personalNotes
            )
        )

        var audioOutcome: AudioOutcome = .none
        if hadUsableBaseAudio {
            if FileManager.default.fileExists(atPath: incomingAudioURL.path) {
                // Both sides kept audio. One continuous file preserves moment
                // playback across the whole merged timeline.
                let combinedTemporaryURL = recordingsDirectory
                    .appendingPathComponent("merged-\(UUID().uuidString).m4a")
                try await AudioExtractor.extractAudio(
                    from: [baseAudioURL, incomingAudioURL],
                    to: combinedTemporaryURL
                )
                try FileManager.default.replaceItemAt(
                    baseAudioURL,
                    withItemAt: combinedTemporaryURL
                )
                audioOutcome = .concatenated
            } else {
                audioOutcome = .targetOnly
            }
        } else if FileManager.default.fileExists(atPath: incomingAudioURL.path) {
            try FileManager.default.removeItem(at: baseAudioURL)
            try FileManager.default.moveItem(
                at: incomingAudioURL,
                to: baseAudioURL
            )
            audioOutcome = .adoptedFromAbsorbed
        }
        let combinedAudioStart = hadUsableBaseAudio
            ? base.audioStart
            : (audioOutcome == .adoptedFromAbsorbed ? offset : base.audioStart)

        let appended = NoteSessionAppend.appending(
            material: material,
            to: promotedBase,
            offset: offset,
            audioStart: combinedAudioStart,
            newSessions: NoteSessionAppend.normalizedSessions(of: incoming)
        )
        let insights = await summarizer.summarize(
            transcript: appended.transcript,
            fallbackTitle: base.title.isEmpty ? incoming.title : base.title
        )

        var merged = appended
        merged.title = insights.title
        merged.summary = insights.summary
        merged.keyPoints = insights.keyPoints
        merged.decisions = insights.decisions
        merged.actionItems = insights.actionItems
        return Result(
            merged: merged,
            absorbed: absorbed,
            audioOutcome: audioOutcome
        )
    }
}
