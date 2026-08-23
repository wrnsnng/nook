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
        #expect(result?.cueLabel == "friday")
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
        #expect(suggestion("Draft notes today")?.cueLabel == "today")
        #expect(suggestion("Review tomorrow")?.cueLabel == "tomorrow")
        #expect(suggestion("Plan next week")?.cueLabel == "next week")
        #expect(day(of: suggestion("Draft notes today")!.dueDate) == 10)
        #expect(day(of: suggestion("Review tomorrow")!.dueDate) == 11)
        #expect(day(of: suggestion("Plan next week")!.dueDate) == 17)
    }

    @Test
    func tonightCountsAsToday() {
        #expect(suggestion("Finish the deck tonight")?.cueLabel == "today")
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
}
