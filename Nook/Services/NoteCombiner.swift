import Foundation

/// What a merge needs from a summarizer.
///
/// `SummaryService` is an actor around an on-device model that is never
/// available in a test run, so without a seam the only observable merge is the
/// one where summarizing failed. This lets a test hand `merge` a fixed set of
/// insights and assert what the merge does with them.
protocol NoteSummarizing: Sendable {
    func summarize(
        transcript: [TranscriptSegment],
        fallbackTitle: String
    ) async -> MeetingInsights
}

extension SummaryService: NoteSummarizing {}

/// Folds one saved note into another so a meeting that happened in pieces
/// reads as one note.
///
/// Merging is the same operation as recording into an existing note, except
/// the second sitting arrives already finished. The earlier-starting note
/// keeps its identity; the caller deletes the absorbed file after a
/// successful save.
enum NoteCombiner {
    enum AudioOutcome: Sendable {
        /// Both notes' audio was concatenated onto the surviving note's file.
        case concatenated
        /// Only the surviving note had usable kept audio, and it still covers
        /// only its own material. The other note had none to contribute.
        case targetOnly
        /// The other note's audio was adopted as the surviving note's audio.
        case adoptedFromAbsorbed
        /// Neither note had kept audio.
        case none
    }

    struct Result: Sendable {
        /// The note that survives, carrying the identity and file of whichever
        /// meeting started first.
        let merged: MeetingNote
        /// The note whose identity was not kept. This is the one the caller
        /// moves to the Trash, and it is not always the note the caller passed
        /// in as absorbed: when the user merges an earlier note into a later
        /// one, the later one is the one that goes.
        let absorbed: MeetingNote
        let audioOutcome: AudioOutcome
        /// The file moves this merge still owes, held back until the merged
        /// note is safely on disk.
        ///
        /// Moving audio is the only irreversible half of a merge. Running it
        /// after the save means a failure while writing Markdown leaves both
        /// notes and both recordings exactly as they were, so the merge can
        /// simply be tried again. The window that remains runs the other way:
        /// if the save succeeds and this fails, the merged note stands with
        /// the appended half of its timeline missing its audio, which loses
        /// no text and can be sorted out by hand.
        let commitAudio: @Sendable () async throws -> Void
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
        summarizer: some NoteSummarizing
    ) async throws -> Result {
        guard target.kind != .digest, absorbed.kind != .digest else {
            throw CombineError.unsupportedKind
        }
        // The earlier note wins the identity so started dates and anything
        // referring to that note survive the merge. It also has to win: the
        // combined transcript is the earlier note's timeline with the later
        // one appended to it, and the joined recording is written to the
        // earlier note's audio file, so identity, text and audio stay in step
        // without renaming anything. The note that loses its identity is the
        // one the caller trashes, which is why the result reports `incoming`
        // rather than whichever note the caller happened to call absorbed.
        let (base, incoming) = absorbed.startedAt < target.startedAt
            ? (absorbed, target)
            : (target, absorbed)

        let baseAudioURL = recordingsDirectory
            .appendingPathComponent("\(base.id.uuidString).m4a")
        let incomingAudioURL = recordingsDirectory
            .appendingPathComponent("\(incoming.id.uuidString).m4a")
        let baseAudioExists = FileManager.default.fileExists(atPath: baseAudioURL.path)
        let incomingAudioExists = FileManager.default
            .fileExists(atPath: incomingAudioURL.path)
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

        // Decided here, performed by `commitAudio` once the merged note is
        // saved. Deciding is all reads, so nothing on disk changes if anything
        // below this line fails.
        let audioOutcome: AudioOutcome
        if hadUsableBaseAudio {
            audioOutcome = incomingAudioExists ? .concatenated : .targetOnly
        } else if incomingAudioExists {
            audioOutcome = .adoptedFromAbsorbed
        } else {
            audioOutcome = .none
        }

        let commitAudio: @Sendable () async throws -> Void = {
            switch audioOutcome {
            case .concatenated:
                // Both sides kept audio. One continuous file preserves moment
                // playback across the whole merged timeline.
                let combinedTemporaryURL = recordingsDirectory
                    .appendingPathComponent("merged-\(UUID().uuidString).m4a")
                try await AudioExtractor.extractAudio(
                    from: [baseAudioURL, incomingAudioURL],
                    to: combinedTemporaryURL
                )
                _ = try FileManager.default.replaceItemAt(
                    baseAudioURL,
                    withItemAt: combinedTemporaryURL
                )
            case .adoptedFromAbsorbed:
                try setAsideUnusableAudio(at: baseAudioURL)
                try FileManager.default.moveItem(
                    at: incomingAudioURL,
                    to: baseAudioURL
                )
            case .targetOnly, .none:
                break
            }
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
        let fallbackTitle = base.title.isEmpty ? incoming.title : base.title
        let insights = await summarizer.summarize(
            transcript: appended.transcript,
            fallbackTitle: fallbackTitle
        )

        // A merge must not quietly undo the user's own work. The model is
        // rerun because the combined conversation genuinely has a new shape,
        // but a title somebody typed and the follow-ups they have been keeping
        // are theirs: the fresh pass may add to them, never replace them.
        var merged = appended
        merged.title = keptTitle(base: base, incoming: incoming, proposed: insights.title)
        merged.keyPoints = insights.keyPoints
        merged.decisions = insights.decisions
        merged.actionItems = unionedActionItems(
            base.actionItems,
            incoming.actionItems,
            insights.actionItems
        )
        merged.completedActionItems = unionedCompletedActionItems(
            in: merged.actionItems,
            completed: base.completedActionItems,
            incoming.completedActionItems
        )
        let existingSummary = appended.summary
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let summarizingFailed = isFallbackSummary(
            insights.summary,
            transcript: appended.transcript,
            fallbackTitle: fallbackTitle
        )
        merged.summary = summarizingFailed && !existingSummary.isEmpty
            ? appended.summary
            : insights.summary
        merged.extraSections = unionedExtraSections(
            appended.extraSections,
            incoming.extraSections
        )
        return Result(
            merged: merged,
            absorbed: incoming,
            audioOutcome: audioOutcome,
            commitAudio: commitAudio
        )
    }

    /// Gets an unreadable recording out of the way without destroying it.
    ///
    /// Reaching here means the file exists but its duration could not be read,
    /// which usually means it was truncated. Truncated audio is still audio
    /// somebody may want back, and this is the one place a merge would
    /// otherwise unlink a recording the user asked Nook to keep. The Trash
    /// keeps it recoverable; on a volume without one, moving it aside does.
    private static func setAsideUnusableAudio(at url: URL) throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else { return }
        do {
            try manager.trashItem(at: url, resultingItemURL: nil)
        } catch {
            let stamp = String(UUID().uuidString.prefix(8)).lowercased()
            try manager.moveItem(
                at: url,
                to: url
                    .deletingPathExtension()
                    .appendingPathExtension("unreadable-\(stamp)")
                    .appendingPathExtension("m4a")
            )
        }
    }

    /// The title the merged note keeps.
    ///
    /// A title somebody typed is the one part of a note the model cannot
    /// reproduce, so it outranks a fresh one. The surviving note's own title
    /// comes first, then the note being folded in; only when both are
    /// placeholders does the model's title for the combined transcript stand.
    /// Passing an empty fallback asks `isFallbackTitle` the question that
    /// matters here: is this a placeholder Nook generated, in any shape it has
    /// ever generated one.
    static func keptTitle(
        base: MeetingNote,
        incoming: MeetingNote,
        proposed: String
    ) -> String {
        for candidate in [base.title, incoming.title] {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  !MeetingTitleGenerator.isFallbackTitle(trimmed, fallbackTitle: "")
            else { continue }
            return trimmed
        }
        return proposed
    }

    /// Both notes' action items, then anything new the model found.
    ///
    /// Items are compared without their `[due: ...]` suffix so a follow-up the
    /// user dated is not listed twice when the model writes it again, and the
    /// stored text is kept exactly as it was so the date survives.
    static func unionedActionItems(_ groups: [String]...) -> [String] {
        var seen: Set<String> = []
        var combined: [String] = []
        for item in groups.joined() {
            let key = actionItemKey(item)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            combined.append(item)
        }
        return combined
    }

    /// The ticks that survive, mapped onto the text that survived.
    ///
    /// Both notes can carry the same follow-up under slightly different words,
    /// and only one of those spellings is kept. A tick on either copy is the
    /// user saying that work is done, so it moves onto the copy that stayed:
    /// dropping it would quietly reopen a finished task.
    static func unionedCompletedActionItems(
        in items: [String],
        completed groups: Set<String>...
    ) -> Set<String> {
        let ticked = Set(groups.joined().map(actionItemKey))
        return Set(items.filter { ticked.contains(actionItemKey($0)) })
    }

    /// Both notes' unmodelled sections, the surviving note's first.
    ///
    /// A section no field models is something a person typed into the file by
    /// hand, and a merge rebuilds that file from the model. Keeping only the
    /// survivor's sections therefore deleted every heading the absorbed note
    /// carried, which is exactly the writing this field exists to protect.
    /// Identical blocks fold together so merging the same material twice does
    /// not stack duplicates; anchors travel with each block, so each one goes
    /// back after the recognised heading it followed.
    static func unionedExtraSections(
        _ groups: [ExtraSection]...
    ) -> [ExtraSection] {
        var seen: Set<ExtraSection> = []
        var combined: [ExtraSection] = []
        for section in groups.joined() where seen.insert(section).inserted {
            combined.append(section)
        }
        return combined
    }

    /// Two spellings of the same follow-up compare equal: case and spacing do
    /// not distinguish them, and neither does a due date somebody added later.
    private static func actionItemKey(_ item: String) -> String {
        ActionItemLine.strippingDueSuffix(from: item)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    /// True when the summarizer handed back its deterministic stand-in rather
    /// than a summary of the conversation.
    ///
    /// Asking the stand-in itself keeps this honest without copying its
    /// wording into a second file, where the two would drift apart.
    private static func isFallbackSummary(
        _ summary: String,
        transcript: [TranscriptSegment],
        fallbackTitle: String
    ) -> Bool {
        guard !transcript.isEmpty else { return true }
        return summary == SummaryService.fallbackInsights(
            transcript: transcript,
            fallbackTitle: fallbackTitle
        ).summary
    }
}
