import Foundation

/// Decides whether an appended note action's result is safe to write into the
/// user's note.
///
/// `DictationOutputGuard` covers the actions that replace the note. The two
/// that append, Summarise and Find actions, had no check at all: whatever came
/// back was pasted under a heading verbatim, including output from the Claude
/// or Codex CLI. A spoken note routinely reads as a request, so "find the
/// actions in this note" is regularly answered as if it were addressed to the
/// model, and the answer then lives in the user's document as if they had
/// written it.
///
/// The replacing guard does not fit here. It refuses anything much shorter
/// than its input, and a summary is meant to be much shorter, so it would
/// reject every honest result. The direction of the test is different too: a
/// summary need not contain most of the note, but the note must contain most
/// of the summary.
///
/// Rejection costs the user one unhelpful button press. Acceptance of a bad
/// result puts sentences nobody said into a note they will later trust.
enum NoteActionOutputGuard {
    enum Decision: Equatable {
        /// Safe to append, in the possibly trimmed form given here.
        case accept(String)
        /// Nothing recognisable came back; the note stays exactly as it is.
        case reject
    }

    /// A summary cannot be longer than the note it summarises.
    static let maximumSummaryLengthRatio = 1.0

    /// Below this, length alone says nothing: two sentences about a one-line
    /// note is a summary, not the model taking the note over. The overlap
    /// test still applies, and it is the one that catches an answer.
    static let shortNoteAllowance = 240

    /// How much of the appended text has to come from the note. An answer to
    /// a question shares its topic words and brings its own everything else,
    /// which lands well below this.
    static let minimumSourcedWordShare = 0.5

    static func evaluate(
        _ result: String,
        for action: NoteAction,
        note: String
    ) -> Decision {
        switch action {
        case .summarize:
            return evaluateSummary(result, note: note)
        case .actionItems:
            return evaluateActionItems(result, note: note)
        case .tidy, .expand:
            // These replace the note and go through DictationOutputGuard,
            // which weighs growth against the words already there.
            let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? .reject : .accept(trimmed)
        }
    }

    private static func evaluateSummary(
        _ result: String,
        note: String
    ) -> Decision {
        let candidate = result.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty, !source.isEmpty else { return .reject }

        let ceiling = max(
            Int(Double(source.count) * maximumSummaryLengthRatio),
            shortNoteAllowance
        )
        guard candidate.count <= ceiling else { return .reject }

        guard isSourced(candidate, in: source) else { return .reject }
        return .accept(candidate)
    }

    /// Keeps the list lines the note can account for and drops the rest.
    ///
    /// Filtering rather than refusing the whole result: a model that finds
    /// three real follow-ups and invents a fourth should still hand over the
    /// three. When nothing survives there is no list to append, so the note is
    /// left alone and the user is told their own words were kept.
    private static func evaluateActionItems(
        _ result: String,
        note: String
    ) -> Decision {
        let source = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return .reject }
        let noteWords = DictationOutputGuard.contentWords(in: source)

        let kept = result
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("- ") }
            .filter { line in
                let body = String(line.dropFirst(2))
                let words = DictationOutputGuard.contentWords(in: body)
                // Every word that carries meaning has to be one the speaker
                // used. A dated or assigned item still passes: the guard is
                // asking where the words came from, not how they are phrased.
                return !words.isEmpty && words.isSubset(of: noteWords)
            }

        guard !kept.isEmpty else { return .reject }
        return .accept(kept.joined(separator: "\n"))
    }

    /// Whether most of what the candidate says was already in the note.
    ///
    /// Deliberately asked of the candidate rather than the note: a summary
    /// leaves most of the note out by design, so measuring the other way round
    /// would refuse every good summary and accept a long answer that happens
    /// to repeat the topic.
    static func isSourced(_ candidate: String, in note: String) -> Bool {
        let candidateWords = DictationOutputGuard.contentWords(in: candidate)
        guard !candidateWords.isEmpty else { return false }
        let noteWords = DictationOutputGuard.contentWords(in: note)
        let shared = Double(candidateWords.intersection(noteWords).count)
        return shared / Double(candidateWords.count) >= minimumSourcedWordShare
    }
}
