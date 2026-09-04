import Foundation
import Darwin

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
    func summarize(
        transcript: [TranscriptSegment], fallbackTitle: String, attention: SummaryAttention?
    ) async -> MeetingInsights
    func summarizeForMerge(
        transcript: [TranscriptSegment], fallbackTitle: String, attention: SummaryAttention?
    ) async -> SummaryResult
}

extension NoteSummarizing {
    func summarizeForMerge(
        transcript: [TranscriptSegment], fallbackTitle: String, attention: SummaryAttention?
    ) async -> SummaryResult {
        SummaryResult(insights: await summarize(transcript: transcript, fallbackTitle: fallbackTitle, attention: attention))
    }
    func summarize(
        transcript: [TranscriptSegment], fallbackTitle: String, attention: SummaryAttention?
    ) async -> MeetingInsights {
        await summarize(transcript: transcript, fallbackTitle: fallbackTitle)
    }
}

extension SummaryService: NoteSummarizing {
    func summarizeForMerge(
        transcript: [TranscriptSegment], fallbackTitle: String, attention: SummaryAttention?
    ) async -> SummaryResult {
        await summarizeReportingFailure(transcript: transcript, fallbackTitle: fallbackTitle, attention: attention)
    }
}

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
        /// only its own material. The other note had none to contribute, or
        /// what it had could not be read.
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

    /// Where a recording that has to be kept, but cannot stay where it is,
    /// gets moved to.
    ///
    /// A parameter rather than a fixed policy because the fallback is the
    /// branch that has to carry the bytes itself, and on any volume with a
    /// Trash a test can never reach it. A preservation guarantee that only
    /// runs on volumes nobody tests on is not a guarantee.
    enum UnusableAudioDestination: Sendable {
        /// The Trash, which is where it goes on any ordinary volume, and what
        /// keeps the deletion reversible from the Finder.
        case trash
        /// A rename beside the original. What happens on a volume with no
        /// Trash at all.
        case renameBeside
    }

    enum CombineError: LocalizedError, Equatable {
        case unsupportedKind
        case audioChanged

        var errorDescription: String? {
            switch self {
            case .unsupportedKind:
                "Digests are compiled overviews and cannot be merged."
            case .audioChanged:
                "A recording changed while merging. Review the recordings and retained notes before continuing."
            }
        }
    }

    static func merge(
        _ absorbed: MeetingNote,
        into target: MeetingNote,
        recordingsDirectory: URL,
        summarizer: some NoteSummarizing,
        unusableAudioDestination: UnusableAudioDestination = .trash,
        fileManagerProvider: @escaping @MainActor @Sendable () -> FileManager = { .default },
        validatingBeforeAudioCommit: @escaping @MainActor @Sendable () throws -> Void = {}
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
        // Durations establish the merged timeline, so both paths belong to
        // their pre-read snapshots, including a path that did not exist yet.
        let baseAudio = try AudioFileSnapshot(url: baseAudioURL)
        let incomingAudio = try AudioFileSnapshot(url: incomingAudioURL)
        let baseAudioDuration = baseAudio.exists
            ? await NoteSessionAppend.audioDuration(of: baseAudioURL)
            : nil
        try Task.checkCancellation()
        try baseAudio.validate()
        try incomingAudio.validate()
        let hadUsableBaseAudio = baseAudio.exists && baseAudioDuration != nil
        // The incoming side is checked the same way the base side is. Adopting
        // a file whose duration cannot be read handed the merged note a
        // recording nothing can play, and did it by overwriting or trashing
        // the audio the note already had.
        let incomingAudioDuration = incomingAudio.exists
            ? await NoteSessionAppend.audioDuration(of: incomingAudioURL)
            : nil
        try Task.checkCancellation()
        try baseAudio.validate()
        try incomingAudio.validate()
        let hadUsableIncomingAudio = incomingAudio.exists
            && incomingAudioDuration != nil

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
            audioOutcome = hadUsableIncomingAudio ? .concatenated : .targetOnly
        } else if hadUsableIncomingAudio {
            audioOutcome = .adoptedFromAbsorbed
        } else {
            audioOutcome = .none
        }
        // An incoming recording nobody can read still belongs to somebody. Its
        // note is about to be trashed, so without this it would sit in the
        // recordings folder forever under an identifier no note claims.
        let unreadableIncomingAudio = incomingAudio.exists
            && !hadUsableIncomingAudio

        let commitAudio: @Sendable () async throws -> Void = {
            try Task.checkCancellation()
            try baseAudio.validate()
            try incomingAudio.validate()
            switch audioOutcome {
            case .concatenated:
                // Both sides kept audio. One continuous file preserves moment
                // playback across the whole merged timeline.
                let combinedTemporaryURL = recordingsDirectory
                    .appendingPathComponent("merged-\(UUID().uuidString).m4a")
                defer { try? FileManager.default.removeItem(at: combinedTemporaryURL) }
                try await AudioExtractor.extractAudio(
                    from: [baseAudioURL, incomingAudioURL],
                    to: combinedTemporaryURL
                )
                // Extraction can take long enough for the folder, a source,
                // or an editor to change. The final guard and file moves share
                // the main actor so Nook cannot change scope between them.
                try await MainActor.run {
                    try Task.checkCancellation()
                    try validatingBeforeAudioCommit()
                    try baseAudio.validate()
                    try incomingAudio.validate()
                    let manager = fileManagerProvider()
                    _ = try manager.replaceItemAt(
                        baseAudioURL,
                        withItemAt: combinedTemporaryURL
                    )
                    let committedBase = try AudioFileSnapshot(url: baseAudioURL)
                    guard committedBase.exists else { throw CombineError.audioChanged }
                    // The joined file now holds every second of this audio,
                    // and the note it belonged to is about to be trashed.
                    try discardMergedSourceAudio(incomingAudio, fileManager: manager) {
                        try validatingBeforeAudioCommit()
                        try committedBase.validate()
                    }
                }
            case .adoptedFromAbsorbed:
                try await MainActor.run {
                    try Task.checkCancellation()
                    try validatingBeforeAudioCommit()
                    try baseAudio.validate()
                    try incomingAudio.validate()
                    let manager = fileManagerProvider()
                    try setAsideUnusableAudio(
                        baseAudio,
                        destination: unusableAudioDestination,
                        fileManager: manager
                    ) {
                        try validatingBeforeAudioCommit()
                        try incomingAudio.validate()
                    }
                    try validatingBeforeAudioCommit()
                    try incomingAudio.validate()
                    try AudioFileSnapshot.requireAbsence(at: baseAudioURL)
                    try manager.moveItem(
                        at: incomingAudioURL,
                        to: baseAudioURL
                    )
                }
            case .targetOnly, .none:
                try await MainActor.run {
                    try Task.checkCancellation()
                    try validatingBeforeAudioCommit()
                    try baseAudio.validate()
                    try incomingAudio.validate()
                    if unreadableIncomingAudio {
                        try setAsideUnusableAudio(
                            incomingAudio,
                            destination: unusableAudioDestination,
                            fileManager: fileManagerProvider()
                        ) {
                            try validatingBeforeAudioCommit()
                            try baseAudio.validate()
                        }
                    }
                }
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
        let summaryResult = await summarizer.summarizeForMerge(
            transcript: appended.transcript,
            fallbackTitle: fallbackTitle,
            attention: SummaryAttention(note: appended)
        )
        let insights = summaryResult.insights
        try Task.checkCancellation()
        try baseAudio.validate()
        try incomingAudio.validate()

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
        let summarizingFailed = summaryResult.usedFallback || isFallbackSummary(
            insights.summary,
            transcript: appended.transcript,
            fallbackTitle: fallbackTitle
        )
        // Failed enrichment is not evidence that an existing question was
        // resolved. Only a successful whole-transcript pass replaces them.
        merged.openQuestions = summarizingFailed
            ? unionedActionItems(base.openQuestions, incoming.openQuestions, insights.openQuestions)
            : insights.openQuestions
        merged.summary = summarizingFailed && !existingSummary.isEmpty
            ? appended.summary
            : insights.summary
        if summarizingFailed {
            // A failed merged write-up must remain visibly retryable after
            // reopening, without dropping the earlier session's action items.
            merged.summaryPending = merged.transcript.isEmpty ? nil : .appended
            merged.keyPoints = unionedActionItems(base.keyPoints, incoming.keyPoints, insights.keyPoints)
            merged.decisions = unionedActionItems(base.decisions, incoming.decisions, insights.decisions)
            if existingSummary.isEmpty {
                merged.summaryProvenance = merged.transcript.isEmpty
                    ? nil : SummaryFallback.legacyProvenance(for: merged)
            }
        } else {
            merged.summaryPending = nil
            merged.summaryProvenance = nil
        }
        merged.extraSections = unionedExtraSections(
            appended.extraSections,
            incoming.extraSections
        )
        try baseAudio.validate()
        try incomingAudio.validate()
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
    @MainActor
    private static func setAsideUnusableAudio(
        _ source: AudioFileSnapshot,
        destination: UnusableAudioDestination,
        fileManager manager: FileManager,
        validatingBeforeMove: () throws -> Void
    ) throws {
        try validatingBeforeMove()
        try source.validate()
        guard source.exists else { return }
        let url = source.url
        if destination == .trash {
            do {
                try manager.trashItem(at: url, resultingItemURL: nil)
                return
            } catch {
                // A volume without a Trash still must not lose somebody's
                // recording, so the rename below is the fallback rather than
                // the failure.
            }
        }
        // A failed Trash call can take time. Its failure does not authorize
        // moving a replacement that arrived at the same path meanwhile.
        try validatingBeforeMove()
        try source.validate()
        let stamp = String(UUID().uuidString.prefix(8)).lowercased()
        try manager.moveItem(
            at: url,
            to: url
                .deletingPathExtension()
                .appendingPathExtension("unreadable-\(stamp)")
                .appendingPathExtension("m4a")
        )
    }

    /// Removes a recording whose every second now lives in another file.
    ///
    /// Trashed rather than unlinked, so a merge that turns out to be wrong is
    /// still undoable from the Finder. A volume without a Trash still must not
    /// be left holding a duplicate of the merged note's own audio, so the
    /// unlink is the fallback rather than the first move. Failing to remove it
    /// is not a failure of the merge when both snapshots are unchanged: the
    /// audio is already safe in the file the note points at. A replacement is
    /// different and must escape as a partial failure, keeping its new bytes.
    @MainActor
    private static func discardMergedSourceAudio(
        _ source: AudioFileSnapshot,
        fileManager manager: FileManager,
        validatingBeforeMove: () throws -> Void
    ) throws {
        try validatingBeforeMove()
        try source.validate()
        guard source.exists else { return }
        do {
            try manager.trashItem(at: source.url, resultingItemURL: nil)
        } catch {
            try validatingBeforeMove()
            try source.validate()
            try? manager.removeItem(at: source.url)
        }
    }

    /// Metadata catches replaced files and in-place writes without loading a
    /// recording into memory on the main actor. Access time is deliberately
    /// excluded because reading audio may change it. These last checks narrow
    /// races; an uncooperative writer can still race a check and a file move.
    struct AudioFileSnapshot: Sendable {
        private struct Identity: Equatable, Sendable {
            let device: dev_t
            let inode: ino_t
            let size: off_t
            let modifiedSeconds: Int
            let modifiedNanoseconds: Int
            let changedSeconds: Int
            let changedNanoseconds: Int
        }

        let url: URL
        private let identity: Identity?
        var exists: Bool { identity != nil }

        init(url: URL) throws {
            self.url = url
            identity = try Self.readIdentity(at: url)
        }

        func validate() throws {
            guard try Self.readIdentity(at: url) == identity else {
                throw CombineError.audioChanged
            }
        }

        static func requireAbsence(at url: URL) throws {
            guard try readIdentity(at: url) == nil else { throw CombineError.audioChanged }
        }

        private static func readIdentity(at url: URL) throws -> Identity? {
            var info = stat()
            guard lstat(url.path, &info) == 0 else {
                if errno == ENOENT { return nil }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard info.st_mode & S_IFMT == S_IFREG else { throw CombineError.audioChanged }
            return Identity(
                device: info.st_dev, inode: info.st_ino, size: info.st_size,
                modifiedSeconds: info.st_mtimespec.tv_sec,
                modifiedNanoseconds: info.st_mtimespec.tv_nsec,
                changedSeconds: info.st_ctimespec.tv_sec,
                changedNanoseconds: info.st_ctimespec.tv_nsec
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
