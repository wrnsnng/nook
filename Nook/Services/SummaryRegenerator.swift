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

    /// First-capture fallback copy can say only the transcript was saved.
    /// A failed regeneration preserves an existing note, so its notice must
    /// describe that outcome without implying the old summary was removed.
    static func retainedMessage(for reason: SummaryService.FailureReason) -> String {
        let explanation: String
        switch reason {
        case .deviceNotEligible:
            explanation = "This Mac cannot run Apple Intelligence."
        case .appleIntelligenceOff:
            explanation = "Apple Intelligence is turned off. Turn it on in System Settings to try again."
        case .modelNotReady:
            explanation = "Apple Intelligence is still preparing its model. Try again when it is ready."
        case .transcriptTooLong:
            explanation = "This meeting was too long for the on-device model, even after Nook shortened it."
        case .declined:
            explanation = "Apple Intelligence declined to summarize this conversation."
        case .unsupportedLanguage:
            explanation = "Apple Intelligence does not summarize this language yet."
        case .modelBusy:
            explanation = "Apple Intelligence was busy. Try again in a moment."
        case .ungrounded:
            explanation = "The new summary did not match the transcript."
        case .timedOut:
            explanation = "Summarizing took too long. Try again."
        case .sensitiveContent:
            explanation = "Apple Intelligence flagged part of this conversation as sensitive."
        case .malformedAnswer:
            explanation = "Apple Intelligence returned an answer Nook could not read."
        case .schemaUnsupported:
            explanation = "This version of Apple Intelligence cannot produce Nook’s note format."
        case .generationFailed:
            explanation = "Apple Intelligence could not finish the new summary."
        }
        return "Your existing note is unchanged. \(explanation)"
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

    enum Outcome: Equatable, Sendable {
        /// The note as it should be saved.
        case regenerated(MeetingNote)
        /// The note is left exactly as it was, with the reason the model
        /// produced nothing usable. A nil reason means there was never a
        /// transcript to summarize.
        case retained(reason: SummaryService.FailureReason?)
    }

    /// Summarizes a saved note's transcript into a replacement note value.
    ///
    /// The model owns only the six fields it generates. Everything else the
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
        updated.summary = preservingRecoveryNotice(result.insights.summary, from: note)
        updated.summaryPending = nil
        updated.summaryProvenance = nil
        updated.keyPoints = result.insights.keyPoints
        updated.decisions = result.insights.decisions
        updated.actionItems = result.insights.actionItems
        updated.openQuestions = result.insights.openQuestions
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
        // A Unicode normalization edit is still a deliberate source edit.
        // Swift's canonical String equality would give the model ownership
        // of that newer text again, including strings inside an array.
        if latest.title.utf8.elementsEqual(starting.title.utf8) {
            merged.title = regenerated.title
        }
        if latest.summary.utf8.elementsEqual(starting.summary.utf8) {
            merged.summary = regenerated.summary
            merged.summaryProvenance = regenerated.summaryProvenance
        }
        if exactStringsEqual(latest.keyPoints, starting.keyPoints) {
            merged.keyPoints = regenerated.keyPoints
        }
        if exactStringsEqual(latest.decisions, starting.decisions) {
            merged.decisions = regenerated.decisions
        }
        if exactStringsEqual(latest.actionItems, starting.actionItems) {
            merged.actionItems = regenerated.actionItems
        }
        if exactStringsEqual(latest.openQuestions, starting.openQuestions) {
            merged.openQuestions = regenerated.openQuestions
        }
        // Checkbox state is user-owned rather than model-owned. Keep the
        // freshest ticks, dropping only items that the accepted action-item
        // rewrite no longer contains.
        merged.completedActionItems = latest.completedActionItems.filter {
            merged.actionItems.contains($0)
        }
        return merged
    }

    /// Identity-only changes to segment UUIDs do not change what was heard.
    /// Transcript wording/timing/source and the bounded guidance actually sent
    /// to the summarizer do. Never label old-input output as a fresh write-up.
    static func hasSameGenerationInput(_ starting: MeetingNote, _ latest: MeetingNote) -> Bool {
        guard starting.transcript.count == latest.transcript.count,
              zip(starting.transcript, latest.transcript).allSatisfy({ left, right in
                  left.startTime == right.startTime && left.duration == right.duration
                    && left.source == right.source && left.text.utf8.elementsEqual(right.text.utf8)
              }) else { return false }
        return SummaryAttention(note: starting).rendered.utf8.elementsEqual(
            SummaryAttention(note: latest).rendered.utf8
        )
    }

    private static func exactStringsEqual(_ left: [String], _ right: [String]) -> Bool {
        left.count == right.count
            && zip(left, right).allSatisfy { $0.utf8.elementsEqual($1.utf8) }
    }

    /// A better write-up does not turn partial live captions into a complete
    /// recording. Retain this provenance warning across every successful pass.
    static func preservingRecoveryNotice(_ summary: String, from note: MeetingNote) -> String {
        let marker = MeetingCoordinator.liveCaptionNoteMarker
        return note.summary.contains(marker)
            ? marker + "\n\n" + summary
            : summary
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
