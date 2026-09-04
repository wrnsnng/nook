import Foundation

enum SummaryFallback {
    static let partialExtractionNotice =
        "A complete summary was not available, so these entries were taken directly from the transcript."

    /// Old notes did not persist provenance. Exact known output is evidence;
    /// a casual mention of fallback or quoted diagnostic wording is not.
    static func legacyProvenance(for note: MeetingNote) -> SummaryProvenance? {
        guard note.kind == .meeting else { return nil }
        var summary = note.summary
        let recovery = MeetingCoordinator.liveCaptionNoteMarker + "\n\n"
        if summary.hasPrefix(recovery) { summary.removeFirst(recovery.count) }
        if summary.utf8.elementsEqual(partialExtractionNotice.utf8) { return .partialExtraction }
        let reasons: [SummaryService.FailureReason?] = [nil] + SummaryService.FailureReason.allCases.map(Optional.some)
        // Avoid traversing an ordinary note's full transcript merely to render
        // its summary. Only recognized diagnostic prefixes need a full match.
        for reason in reasons {
            let prefix = "\(reason?.userSentence ?? "Nook couldn’t generate a structured summary.") Transcript highlights: "
            guard summary.hasPrefix(prefix) else { continue }
            let expected = SummaryService.fallbackInsights(
                transcript: note.transcript, fallbackTitle: note.title, reason: reason
            ).summary
            if summary.utf8.elementsEqual(expected.utf8) { return .transcriptHighlights }
        }
        return nil
    }

    static func title(for provenance: SummaryProvenance) -> String {
        switch provenance {
        case .transcriptHighlights: "Transcript highlights, not a model summary"
        case .partialExtraction: "Partial write-up, not a complete summary"
        case .editedFallback: "Edited fallback write-up"
        }
    }

    static func emptyStructuredMessage(provenance: SummaryProvenance?, pending: PendingSummaryKind?) -> String {
        if provenance != nil || pending != nil {
            return "No decisions or action items are included in this unfinished write-up. The transcript may still contain them."
        }
        return "No explicit decisions or action items are included in this write-up."
    }

    static func detail(for provenance: SummaryProvenance) -> String {
        switch provenance {
        case .transcriptHighlights:
            "This write-up started as a deterministic sample of transcript passages. It may omit important context and is not a complete summary."
        case .partialExtraction:
            "The final summary failed. These retained entries came from earlier extraction and may be incomplete."
        case .editedFallback:
            "This fallback write-up includes reviewed changes. A complete whole-transcript summary has not replaced it."
        }
    }

    static func protectsDiagnostic(_ item: SummaryReviewItem, in note: MeetingNote) -> Bool {
        guard item.kind == .summary, let range = item.range, note.summaryProvenance != nil else { return false }
        if let notice = note.summary.range(of: partialExtractionNotice, options: .literal),
           NSIntersectionRange(range, NSRange(notice, in: note.summary)).length > 0 { return true }
        // The explanation is app copy, not a generated claim to correct.
        // Protect its exact known prefix while leaving the sampled words reviewable.
        let reasons: [SummaryService.FailureReason?] = [nil] + SummaryService.FailureReason.allCases.map(Optional.some)
        for reason in reasons {
            let prefix = "\(reason?.userSentence ?? "Nook couldn’t generate a structured summary.") Transcript highlights: "
            if let notice = note.summary.range(of: prefix, options: .literal),
               NSIntersectionRange(range, NSRange(notice, in: note.summary)).length > 0 { return true }
        }
        return false
    }
}
