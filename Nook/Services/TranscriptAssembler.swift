import Foundation

enum TranscriptAssembler {
    /// How far apart two segments may be and still merge into one paragraph.
    /// `LiveSegmentMerger` folds against these limits, so changing them here
    /// changes live captions and the saved pass together.
    static let maximumMergeGap: TimeInterval = 1.8
    static let maximumMergeWords = 42

    static func coalesce(
        _ segments: [TranscriptSegment],
        maximumGap: TimeInterval = maximumMergeGap,
        maximumWords: Int = maximumMergeWords
    ) -> [TranscriptSegment] {
        let ordered = segments
            .enumerated()
            .filter { !$0.element.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { lhs, rhs in
                if lhs.element.startTime == rhs.element.startTime {
                    return lhs.offset < rhs.offset
                }
                return lhs.element.startTime < rhs.element.startTime
            }
            .map(\.element)

        return ordered.reduce(into: []) { result, next in
            guard let current = result.last else {
                result.append(next.cleaned)
                return
            }

            let currentEnd = current.startTime + current.duration
            let gap = max(0, next.startTime - currentEnd)
            // Saved transcript lines often have different speakers or are
            // already farther apart than a paragraph can merge. Reject those
            // pairs before scanning both passages to count every word.
            guard current.source == next.source, gap <= maximumGap else {
                result.append(next.cleaned)
                return
            }
            let currentWords = current.text.split(whereSeparator: \.isWhitespace).count
            let nextWords = next.text.split(whereSeparator: \.isWhitespace).count
            let hasNaturalEnding = current.text
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .last
                .map { ".!?".contains($0) }
                ?? false
            let shouldMerge = currentWords + nextWords <= maximumWords
                && (!hasNaturalEnding || currentWords < 5)

            guard shouldMerge else {
                result.append(next.cleaned)
                return
            }

            let nextEnd = next.startTime + next.duration
            let joinedText = [current.text, next.text]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .joined(separator: " ")
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            result[result.count - 1] = TranscriptSegment(
                id: current.id,
                startTime: current.startTime,
                duration: max(current.duration, nextEnd - current.startTime),
                text: joinedText,
                source: current.source
            )
        }
    }
}

enum NoteContentSanitizer {
    static func meaningfulItems(_ values: [String]) -> [String] {
        values.compactMap { rawValue in
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = value
                .lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: " ._-"))
            let placeholderPhrases = [
                "none",
                "n/a",
                "na",
                "none captured",
                "nothing captured",
                "no decisions",
                "no action items",
                "no key points",
                "not discussed",
                "not specified",
            ]
            guard !value.isEmpty,
                  !placeholderPhrases.contains(normalized),
                  !normalized.hasPrefix("no decisions were"),
                  !normalized.hasPrefix("no action items were")
            else {
                return nil
            }
            return value
        }
    }
}

extension TranscriptSegment {
    /// Whitespace-normalised text, the form every coalesced segment carries.
    /// Internal so `LiveSegmentMerger` can prepare fresh finals exactly the
    /// way a full `coalesce` pass would.
    var normalized: TranscriptSegment {
        TranscriptSegment(
            id: id,
            startTime: startTime,
            duration: duration,
            text: text
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression),
            source: source
        )
    }
}

private extension TranscriptSegment {
    var cleaned: TranscriptSegment {
        normalized
    }
}
