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
        /// Short human phrase for the chip, e.g. "Friday" or "tomorrow".
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
        guard let range = text.range(of: suggestion.paragraph) else {
            return text
        }
        return text.replacingCharacters(
            in: range,
            with: checklistLine(from: suggestion, calendar: calendar)
        )
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

        if containsWord(lowercased, "today") || containsWord(lowercased, "tonight") {
            return ("today", calendar.startOfDay(for: now))
        }
        if containsWord(lowercased, "tomorrow") {
            return (
                "tomorrow",
                calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
            )
        }
        if containsWord(lowercased, "next week") {
            return (
                "next week",
                calendar.date(byAdding: .day, value: 7, to: calendar.startOfDay(for: now))!
            )
        }
        let weekdays: [(String, Int)] = [
            ("sunday", 1), ("monday", 2), ("tuesday", 3),
            ("wednesday", 4), ("thursday", 5), ("friday", 6), ("saturday", 7),
        ]
        for (name, weekday) in weekdays where containsWord(lowercased, name) {
            var day = calendar.startOfDay(for: now)
            // Strictly future: naming today's weekday means next occurrence.
            repeat {
                day = calendar.date(byAdding: .day, value: 1, to: day)!
            } while calendar.component(.weekday, from: day) != weekday
            return (name, day)
        }
        return nil
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
