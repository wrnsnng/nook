import Foundation
import Testing
@testable import Nook

/// The capture-assist suggestion is deterministic by contract: a date cue
/// either is literally in the user's words or there is no suggestion. These
/// tests pin the patterns, the last-paragraph preference, and the guarantee
/// that accepted suggestions never invent or reorder words.
struct QuickCaptureTaskParserTests {
    /// Fixed clock: Thursday, 10 September 2026, Sydney.
    private let now = Date(timeIntervalSince1970: 1_789_000_000)

    private var sydney: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Sydney")!
        return calendar
    }

    private func suggestion(
        _ text: String
    ) -> QuickCaptureTaskParser.Suggestion? {
        QuickCaptureTaskParser.suggestion(
            in: text,
            now: now,
            calendar: sydney
        )
    }

    private func day(of date: Date) -> Int {
        sydney.component(.day, from: date)
    }

    @Test
    func aWeekdayBecomesTheNextOccurrence() {
        // Spoken on a Thursday; "friday" must mean tomorrow, the 11th.
        let result = suggestion("Send Marco the report on friday")
        #expect(result?.cueLabel == "Friday")
        #expect(day(of: result!.dueDate) == 11)
        #expect(sydney.component(.month, from: result!.dueDate) == 9)
    }

    @Test
    func namingTodaysWeekdayMeansNextWeekNotToday() {
        // Spoken on a Thursday about "thursday" should not schedule today.
        let result = suggestion("Call mum thursday")
        #expect(day(of: result!.dueDate) == 17)
    }

    @Test
    func todayTomorrowAndNextWeekMapDirectly() {
        #expect(suggestion("Draft notes today")?.cueLabel == "Today")
        #expect(suggestion("Review tomorrow")?.cueLabel == "Tomorrow")
        #expect(suggestion("Plan next week")?.cueLabel == "Next week")
        #expect(day(of: suggestion("Draft notes today")!.dueDate) == 10)
        #expect(day(of: suggestion("Review tomorrow")!.dueDate) == 11)
        #expect(day(of: suggestion("Plan next week")!.dueDate) == 17)
    }

    @Test
    func tonightCountsAsToday() {
        #expect(suggestion("Finish the deck tonight")?.cueLabel == "Today")
        #expect(day(of: suggestion("Finish the deck tonight")!.dueDate) == 10)
    }

    @Test
    func noCueProducesNoSuggestion() {
        #expect(suggestion("Ideas for the offsite program") == nil)
        #expect(suggestion("") == nil)
    }

    @Test
    func partialWordMatchesDoNotSchedule() {
        #expect(suggestion("Buy sunscreen for the trip") == nil)
        #expect(suggestion("Mondayish feelings about the roadmap") == nil)
    }

    @Test
    func existingChecklistLinesAreNeverSuggestedAgain() {
        let text = "- [ ] Send Marco the report on friday"
        #expect(suggestion(text) == nil)
    }

    @Test
    func theLastParagraphWinsBecauseCaptureAppends() {
        let text = """
        Kickoff went well
        Send Marco the report friday
        """
        let result = suggestion(text)
        #expect(result?.paragraph == "Send Marco the report friday")
    }

    @Test
    func applyingRewritesOnlyTheSuggestedParagraph() {
        let text = """
        Kickoff went well
        Send Marco the report friday
        """
        let target = suggestion(text)!
        let applied = QuickCaptureTaskParser.applying(target, to: text)

        #expect(applied.contains("Kickoff went well"))
        #expect(applied.contains("- [ ] Send Marco the report friday [due: "))
        // The user's own words survive verbatim inside the line.
        #expect(applied.contains("Send Marco the report friday"))
    }

    @Test
    func theCueIsLabelledAsSomethingAPersonWouldWrite() {
        // The label is shown as a date of its own in the pad, where a
        // lowercase weekday reads as a transcription slip.
        #expect(suggestion("Call mum monday")?.cueLabel == "Monday")
        #expect(suggestion("Ship it tonight")?.cueLabel == "Today")
    }

    @Test
    func repeatingTheSameSentenceRewritesTheOneJustSaid() {
        // Capture appends, so the suggestion is about the last thought. A
        // plain substring search rewrote the first copy instead.
        let text = """
        Send Marco the report friday
        Kickoff went well
        Send Marco the report friday
        """
        let target = suggestion(text)!
        let applied = QuickCaptureTaskParser.applying(target, to: text)
        let lines = applied.split(separator: "\n").map(String.init)

        #expect(lines[0] == "Send Marco the report friday")
        #expect(lines[2].hasPrefix("- [ ] Send Marco the report friday [due: "))
    }

    @Test
    func anAcceptedSuggestionIsNeverRewrittenIntoItself() {
        // The accepted line still contains the original words, so a search
        // from the end could otherwise aim inside the checklist line and
        // nest one task in another.
        let text = """
        Send Marco the report friday
        - [ ] Send Marco the report friday [due: 2026-09-11]
        """
        let target = suggestion(text)!
        let applied = QuickCaptureTaskParser.applying(target, to: text)

        #expect(
            applied.hasSuffix("- [ ] Send Marco the report friday [due: 2026-09-11]")
        )
        #expect(!applied.contains("[due: 2026-09-11] [due:"))
    }

    @Test
    func rememberingAMeetingIsNotATask() {
        #expect(suggestion("We shipped the beta last friday") == nil)
        #expect(suggestion("On monday we agreed the scope") == nil)
        #expect(suggestion("We discussed on tuesday whether to wait") == nil)
    }

    @Test
    func aTaskThatMentionsThePastIsStillATask() {
        // Suppression is anchored to the cue itself. A past-tense word
        // anywhere in the line would take real tasks away with it.
        #expect(
            suggestion("Send the deck we discussed by friday")?.cueLabel
                == "Friday"
        )
        #expect(
            suggestion("She asked for the notes, send them tomorrow")?.cueLabel
                == "Tomorrow"
        )
    }

    @Test
    func cueBoundariesKeepTheirUnicodeLetterSemantics() {
        let boundaries: [(String, before: Bool, after: Bool)] = [
            ("", true, true), (" ", true, true), ("\t", true, true),
            ("\u{00A0}", true, true), ("\u{200B}", true, true),
            ("\u{0301}", true, true), ("👩🏽‍💻", true, true),
            ("_", true, true), ("9", true, true),
            ("é", false, false), ("中", false, false),
            // The parser's existing ICU boundary is a letter boundary, not
            // a grapheme boundary. A trailing combining mark is not a letter.
            ("e\u{0301}", true, false)
        ]
        for (boundary, before, after) in boundaries {
            #expect((suggestion(boundary + "tomorrow") != nil) == before)
            #expect((suggestion("tomorrow" + boundary) != nil) == after)
        }
    }

    @Test
    func datePrecedenceAndExactMultiwordCuesStayPredictable() {
        #expect(suggestion("Friday or tomorrow")?.cueLabel == "Tomorrow")
        #expect(suggestion("Tomorrow or tonight")?.cueLabel == "Today")
        #expect(suggestion("Saturday then Monday")?.cueLabel == "Monday")
        #expect(suggestion("Plan next\tweek") == nil)
        #expect(suggestion("Plan next\u{00A0}week") == nil)
        #expect(suggestion("Plan next  week") == nil)
    }

    @Test
    func pastCueRejectionKeepsUnicodeWhitespaceAndAnchoring() {
        for space in [" ", "\t", "\u{00A0}", "\u{2003}"] {
            #expect(suggestion("last\(space)friday") == nil)
            #expect(suggestion("monday\(space)we\(space)agreed") == nil)
            #expect(suggestion("we\(space)agreed\(space)on\(space)tuesday") == nil)
        }
        #expect(suggestion("Send what we discussed by friday")?.cueLabel == "Friday")
        #expect(suggestion("We met last friday, send this tomorrow")?.cueLabel == "Tomorrow")
    }

    @Test
    func applyingRequiresTheExactParagraphBytes() {
        let original = "Caf\u{00E9} tomorrow"
        let changed = "Cafe\u{0301} tomorrow"
        let target = suggestion(original)!
        #expect(original == changed)
        #expect(Data(QuickCaptureTaskParser.applying(target, to: changed).utf8) == Data(changed.utf8))
        let twoLines = original + "\n" + changed
        let applied = QuickCaptureTaskParser.applying(target, to: twoLines)
        #expect(applied.hasPrefix("- [ ] " + original))
        #expect(Data(applied.split(separator: "\n").last!.utf8) == Data(changed.utf8))
    }
}
