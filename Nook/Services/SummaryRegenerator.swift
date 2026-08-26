import Foundation

/// Where a summarization stands, in terms a waiting surface can show.
///
/// Condensing reports its parts because that is where minutes go past;
/// writing up is quick but is the moment the answer actually forms, which
/// reads differently to someone watching.
enum SummaryStage: Sendable, Equatable {
    /// A part counter of zero means the first pass has yet to report. The
    /// pass matters because each one re-chunks whatever is left, so totals
    /// shrink between passes: without it, "part 3 of 4" after "part 21 of
    /// 21" reads as broken arithmetic rather than convergence.
    case condensing(pass: Int, part: Int, total: Int)
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
        case .condensing(let pass, let part, let total):
            return Self.condensingDetail(pass: pass, part: part, total: total)
        case .writingUp:
            return "Nearly there"
        }
    }

    static func condensingDetail(pass: Int, part: Int, total: Int) -> String {
        guard part > 0, total > 0 else { return "Reading your transcript" }
        if pass <= 1 {
            return "Part \(part) of \(total)"
        }
        return "Pass \(pass), part \(part) of \(total)"
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
        attention: SummaryAttention?,
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
        attention: SummaryAttention?,
        onStage: SummaryStageHandler?
    ) async -> SummaryResult {
        await self.summarizeReportingFailure(
            transcript: transcript,
            fallbackTitle: fallbackTitle,
            attention: attention,
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
        let attention = SummaryAttention(note: note)
        let result = await summarizer.summarizeReportingFailure(
            transcript: note.transcript,
            // The current title is the fallback, so a model that cannot find
            // a subject leaves the note named the way the user knows it.
            fallbackTitle: note.title,
            attention: attention.isEmpty ? nil : attention,
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

    /// Applies only fields that remained unchanged since generation started.
    ///
    /// Regeneration can take minutes on a long transcript. My notes, moments,
    /// sessions, checkbox state, and file metadata may all change while it is
    /// running, so saving the value captured at the start would silently put
    /// those fields back in time. Comparing each model-owned field with the
    /// starting snapshot makes a concurrent user edit win, while still
    /// allowing an untouched field to receive the fresh model result.
    static func mergingGeneratedFields(
        from regenerated: MeetingNote,
        startingFrom starting: MeetingNote,
        into latest: MeetingNote
    ) -> MeetingNote {
        guard regenerated.id == starting.id,
              latest.id == starting.id
        else { return latest }

        var merged = latest
        if latest.title == starting.title {
            merged.title = regenerated.title
        }
        if latest.summary == starting.summary {
            merged.summary = regenerated.summary
        }
        if latest.keyPoints == starting.keyPoints {
            merged.keyPoints = regenerated.keyPoints
        }
        if latest.decisions == starting.decisions {
            merged.decisions = regenerated.decisions
        }
        if latest.actionItems == starting.actionItems {
            merged.actionItems = regenerated.actionItems
        }
        // Checkbox state is user-owned rather than model-owned. Keep the
        // freshest ticks, dropping only items that the accepted action-item
        // rewrite no longer contains.
        merged.completedActionItems = latest.completedActionItems.filter {
            merged.actionItems.contains($0)
        }
        return merged
    }

    /// Compatibility overload for callers that already have a freshest note
    /// but no separate starting snapshot. New regeneration flows should use
    /// the optimistic three-note form above.
    static func mergingGeneratedFields(
        from regenerated: MeetingNote,
        into latest: MeetingNote
    ) -> MeetingNote {
        mergingGeneratedFields(
            from: regenerated,
            startingFrom: latest,
            into: latest
        )
    }
}
