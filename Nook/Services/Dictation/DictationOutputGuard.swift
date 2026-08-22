import Foundation

/// Decides whether a model rewrite is safe to type into the user's document.
///
/// Dictation routinely produces text that reads as a request — "summarise the
/// Q3 numbers", "what time is standup" — and a language model handed that text
/// will answer it. The user asked for their sentence to be typed, not replied
/// to. Instructions alone do not reliably prevent this, so the rewrite is
/// checked against the transcript before it is allowed anywhere near a text
/// field.
///
/// Rejection is cheap: the verbatim words get typed instead, which is a worse
/// sentence but always the user's own. Accepting a bad rewrite is expensive:
/// it puts words the user never said into their message.
enum DictationOutputGuard {
    enum Decision: Equatable {
        case accept(String)
        case reject(Rejection)

        var text: String? {
            guard case .accept(let value) = self else { return nil }
            return value
        }
    }

    enum Rejection: String, Equatable {
        case empty
        case tooShort
        case tooLong
        case driftedFromSpeech
    }

    /// A rewrite may compress speech considerably — removing false starts and
    /// repetition genuinely halves some sentences — but it should never expand
    /// much, and an answer to a dictated question is almost always either far
    /// shorter or far longer than the question.
    static let minimumLengthRatio = 0.35
    static let defaultMaximumLengthRatio = 1.6

    /// How much of the spoken vocabulary must survive. An answer to a question
    /// shares the topic words but drops the interrogative framing, which lands
    /// well below this.
    private static let minimumWordOverlap = 0.5

    /// Short utterances are exempt from the overlap test: "yes", "on my way",
    /// and "ok thanks" have too few words for a ratio to mean anything.
    private static let overlapExemptionWordCount = 4

    /// `maximumLengthRatio` lets a caller widen the growth ceiling for
    /// rewrites that legitimately develop the text, without loosening the
    /// overlap test that catches an answer replacing the words.
    static func evaluate(
        refined: String,
        spoken: String,
        maximumLengthRatio: Double = Self.defaultMaximumLengthRatio
    ) -> Decision {
        let candidate = refined.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = spoken.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !candidate.isEmpty else { return .reject(.empty) }
        guard !source.isEmpty else { return .accept(candidate) }

        let ratio = Double(candidate.count) / Double(source.count)
        if ratio < minimumLengthRatio { return .reject(.tooShort) }
        if ratio > maximumLengthRatio { return .reject(.tooLong) }

        let spokenWords = contentWords(in: source)
        guard spokenWords.count > overlapExemptionWordCount else {
            return .accept(candidate)
        }

        let candidateWords = contentWords(in: candidate)
        let overlap = Double(spokenWords.intersection(candidateWords).count)
            / Double(spokenWords.count)
        guard overlap >= minimumWordOverlap else {
            return .reject(.driftedFromSpeech)
        }
        return .accept(candidate)
    }

    /// Words that carry meaning. Function words are excluded because they
    /// overlap heavily between any two English sentences, which would let an
    /// unrelated answer clear the threshold on "the", "and", and "to" alone.
    static func contentWords(in text: String) -> Set<String> {
        Set(
            text.lowercased()
                .split { !$0.isLetter && !$0.isNumber }
                .map(String.init)
                .filter { $0.count > 2 && !functionWords.contains($0) }
        )
    }

    private static let functionWords: Set<String> = [
        "the", "and", "but", "for", "not", "you", "with", "that", "this",
        "have", "has", "had", "was", "were", "are", "its", "our", "their",
        "them", "they", "then", "than", "into", "onto", "from", "about",
        "can", "will", "would", "should", "could", "just", "get", "got",
        "her", "his", "she", "him", "who", "some", "any", "all"
    ]
}
