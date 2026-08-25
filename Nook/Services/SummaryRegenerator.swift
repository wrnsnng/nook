import Foundation

/// Where a summarization stands, in terms a waiting surface can show.
///
/// Condensing reports its parts because that is where minutes go past;
/// writing up is quick but is the moment the answer actually forms, which
/// reads differently to someone watching.
enum SummaryStage: Sendable, Equatable {
    /// A part counter of zero means the first pass has yet to report.
    case condensing(part: Int, total: Int)
    case writingUp
}

typealias SummaryStageHandler = @Sendable (SummaryStage) async -> Void

/// What each stage says to someone waiting.
///
/// Pure so the wording is testable without Apple Intelligence, and shared
/// so every surface describing regeneration says the same thing.
enum RegenerationCopy {
    static func headline(for stage: SummaryStage) -> String {
        switch stage {
        case .condensing: "Re-reading this conversation"
        case .writingUp: "Writing up what it heard"
        }
    }

    static func detail(for stage: SummaryStage) -> String {
        switch stage {
        case .condensing(let part, let total) where part == 0 || total == 0:
            "Reading your transcript"
        case .condensing(let part, let total):
            "Part \(part) of \(total)"
        case .writingUp:
            "Nearly there"
        }
    }
}

/// What regenerating a note's summary needs from a summarizer.
///
/// `NoteSummarizing` hides why a summary failed, which a merge does not need
/// and regeneration does: the whole point of asking again is being told, when
/// it fails once more, what to do about it.
protocol FailureReportingSummarizing: Sendable {
    func summarizeReportingFailure(
        transcript: [TranscriptSegment],
        fallbackTitle: String,
        onStage: SummaryStageHandler?
    ) async -> SummaryResult
}

extension SummaryService: FailureReportingSummarizing {
    /// The coordinator-facing method carries progress callbacks with
    /// defaults, and a defaulted parameter cannot witness a protocol
    /// requirement, so the plain shape is spelled out here.
    func summarizeReportingFailure(
        transcript: [TranscriptSegment],
        fallbackTitle: String,
        onStage: SummaryStageHandler?
    ) async -> SummaryResult {
        await self.summarizeReportingFailure(
            transcript: transcript,
            fallbackTitle: fallbackTitle,
            onProgress: nil,
            onStage: onStage
        )
    }
}

/// Re-runs the structured summary over a note that already exists.
///
/// A meeting whose first write-up failed (Apple Intelligence off, busy, or
/// unwilling) still saved, with only transcript highlights where the summary
/// belongs. Nothing about that failure stops a later attempt from succeeding,
/// so the note carries its own way to ask again.
enum SummaryRegenerator {
    /// Whether this note has something regeneration can work on.
    ///
    /// Spoken notes carry no transcript and digests are compiled rather than
    /// summarized, so neither offers one.
    static func isAvailable(for note: MeetingNote) -> Bool {
        note.kind == .meeting && !note.transcript.isEmpty
    }

    enum Outcome: Equatable {
        /// The note as it should be saved.
        case regenerated(MeetingNote)
        /// The note is left exactly as it was, with the reason the model
        /// produced nothing usable. A nil reason means there was never a
        /// transcript to summarize.
        case retained(reason: SummaryService.FailureReason?)
    }

    /// Summarizes a saved note's transcript into a replacement note value.
    ///
    /// The model owns only the five fields it generates. Everything else the
    /// note carries, its identity, file, kept audio, moments, sessions, extra
    /// hand-written sections, and above all My notes, passes through
    /// untouched, so asking for a second attempt risks nothing else about the
    /// note.
    static func regenerate(
        _ note: MeetingNote,
        using summarizer: some FailureReportingSummarizing,
        onStage: SummaryStageHandler? = nil
    ) async -> Outcome {
        guard isAvailable(for: note) else { return .retained(reason: nil) }
        let result = await summarizer.summarizeReportingFailure(
            transcript: note.transcript,
            // The current title is the fallback, so a model that cannot find
            // a subject leaves the note named the way the user knows it.
            fallbackTitle: note.title,
            onStage: onStage
        )
        guard result.failure == nil else {
            return .retained(reason: result.failure)
        }

        var updated = note
        updated.title = result.insights.title
        updated.summary = result.insights.summary
        updated.keyPoints = result.insights.keyPoints
        updated.decisions = result.insights.decisions
        updated.actionItems = result.insights.actionItems
        // A ticked item whose exact text survives the rewrite keeps its tick,
        // the same promise a rename makes. Items the model dropped no longer
        // exist, so their ticks go with them rather than waiting to ambush a
        // future item worded the same way.
        updated.completedActionItems = updated.completedActionItems.filter {
            updated.actionItems.contains($0)
        }
        return .regenerated(updated)
    }
}
