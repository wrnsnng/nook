import Foundation

/// A deterministic suggestion that one paragraph of a quick note is really a
/// dated task.
///
/// Deliberately fixed patterns rather than a model call: a date cue either is
/// literally in the user's words or it is not, so there is nothing to invent
/// and nothing to distrust. This is the deterministic-first tier of the
/// capture-assist ladder; anything looser would need the propose-and-diff
/// treatment before it could ship.
enum QuickCaptureTaskParser {
    struct Suggestion: Equatable {
        /// The paragraph verbatim, checkbox prefix included when present.
        let paragraph: String
        let dueDate: Date
        /// Short human phrase for the row, e.g. "Friday" or "Tomorrow".
        ///
        /// Capitalised because the suggestion row shows it as a date token of
        /// its own rather than inside a sentence, and a lowercase weekday
        /// there reads as a transcription slip.
        let cueLabel: String
    }

    /// The last paragraph that reads as a dated task but is not a checklist
    /// line yet.
    ///
    /// Last wins because capture appends: the thought just spoken is the one
    /// being acted on. Paragraphs that are already checkboxes are skipped, so
    /// an accepted suggestion never offers itself twice.
    static func suggestion(
        in text: String,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Suggestion? {
        for paragraph in text.split(separator: "\n").reversed() {
            let line = String(paragraph)
            if isChecklistLine(line) { continue }
            guard let cue = firstCue(in: line, now: now, calendar: calendar)
            else { continue }
            return Suggestion(
                paragraph: line,
                dueDate: cue.date,
                cueLabel: cue.label
            )
        }
        return nil
    }

    /// Turns the suggested paragraph into a checklist line carrying the due
    /// suffix the library already parses. The words themselves stay exactly
    /// as spoken or typed.
    static func checklistLine(
        from suggestion: Suggestion,
        calendar: Calendar = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        let trimmed = suggestion.paragraph
            .trimmingCharacters(in: .whitespaces)
        return "- [ ] \(trimmed) [due: \(formatter.string(from: suggestion.dueDate))]"
    }

    /// Replaces the suggested paragraph in the buffer with its checklist
    /// form, leaving every other byte alone.
    static func applying(
        _ suggestion: Suggestion,
        to text: String,
        calendar: Calendar = .current
    ) -> String {
        guard let range = lastLineRange(
            matching: suggestion.paragraph,
            in: text
        ) else {
            return text
        }
        return text.replacingCharacters(
            in: range,
            with: checklistLine(from: suggestion, calendar: calendar)
        )
    }

    /// The range of the last whole line equal to `paragraph`.
    ///
    /// Whole lines searched from the end, because `suggestion(in:)` reads from
    /// the end too. A plain substring search found the first match instead,
    /// which rewrote the wrong paragraph whenever the same words had been said
    /// twice, and could aim inside a checklist line that already carried this
    /// text with a due suffix appended.
    private static func lastLineRange(
        matching paragraph: String,
        in text: String
    ) -> Range<String.Index>? {
        var match: Range<String.Index>?
        text.enumerateSubstrings(
            in: text.startIndex..<text.endIndex,
            options: [.byLines]
        ) { line, range, _, _ in
            if line == paragraph { match = range }
        }
        return match
    }

    private static func isChecklistLine(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces)
            .hasPrefix("- [")
    }

    private typealias Cue = (label: String, date: Date)

    private static func firstCue(
        in line: String,
        now: Date,
        calendar: Calendar
    ) -> Cue? {
        let lowercased = line.lowercased()

        for word in ["today", "tonight"] where mentions(lowercased, word) {
            return ("Today", calendar.startOfDay(for: now))
        }
        if mentions(lowercased, "tomorrow") {
            return (
                "Tomorrow",
                calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
            )
        }
        if mentions(lowercased, "next week") {
            return (
                "Next week",
                calendar.date(byAdding: .day, value: 7, to: calendar.startOfDay(for: now))!
            )
        }
        let weekdays: [(String, Int)] = [
            ("sunday", 1), ("monday", 2), ("tuesday", 3),
            ("wednesday", 4), ("thursday", 5), ("friday", 6), ("saturday", 7),
        ]
        for (name, weekday) in weekdays where mentions(lowercased, name) {
            var day = calendar.startOfDay(for: now)
            // Strictly future: naming today's weekday means next occurrence.
            repeat {
                day = calendar.date(byAdding: .day, value: 1, to: day)!
            } while calendar.component(.weekday, from: day) != weekday
            return (name.capitalized, day)
        }
        return nil
    }

    /// Whether the line names this cue as something still to come.
    ///
    /// Speech recalls as often as it plans: "we shipped it last Friday" and
    /// "on Monday we agreed the scope" both name a weekday and neither is a
    /// task. Suppression is deliberately anchored to the cue itself rather
    /// than to any past-tense word anywhere in the line, because "send the
    /// deck we discussed on Friday" is a real task and must survive.
    private static func mentions(_ lowercased: String, _ cue: String) -> Bool {
        guard containsWord(lowercased, cue) else { return false }
        return !readsAsPast(lowercased, cue: cue)
    }

    private static func readsAsPast(_ lowercased: String, cue: String) -> Bool {
        let cuePattern = NSRegularExpression.escapedPattern(for: cue)
        let pronouns = "(?:we|i|he|she|they|you|it)"
        let pastVerbs = "(?:was|were|had|did|went|met|spoke|talked|discussed"
            + "|agreed|decided|said|told|reviewed|covered|finished|shipped"
            + "|sent|asked|kicked)"
        let patterns = [
            // "last friday"
            #"(?<!\p{L})last\s+"# + cuePattern + #"(?!\p{L})"#,
            // "on monday we agreed"
            #"(?<!\p{L})"# + cuePattern + #"\s+"# + pronouns + #"\s+"#
                + pastVerbs + #"(?!\p{L})"#,
            // "we agreed on monday"
            #"(?<!\p{L})"# + pronouns + #"\s+"# + pastVerbs
                + #"\s+(?:on\s+)?"# + cuePattern + #"(?!\p{L})"#,
        ]
        return patterns.contains {
            lowercased.range(of: $0, options: .regularExpression) != nil
        }
    }

    /// Whole-word containment, so "moday" inside "mondayish" nonsense and
    /// "sun" inside "sunscreen" do not schedule anything.
    private static func containsWord(_ text: String, _ word: String) -> Bool {
        text.range(
            of: #"(?<!\p{L})"# + NSRegularExpression.escapedPattern(for: word) + #"(?!\p{L})"#,
            options: .regularExpression
        ) != nil
    }
}
