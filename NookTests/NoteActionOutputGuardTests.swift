import Foundation
import Testing
@testable import Nook

/// The two note actions that append rather than replace used to write whatever
/// came back straight into the user's document, including output from a
/// command-line model. A spoken note routinely reads as a request, so the
/// thing that arrives is regularly an answer to the note rather than work on
/// it, and it then sits under a heading as if the user had written it.
struct NoteActionOutputGuardTests {
    private static let note = """
    Right, so the pricing page redesign. I need to send Priya the revised \
    mockups before Thursday, and someone has to book the usability sessions \
    with the research team. The annual plan toggle is still confusing people.
    """

    @Test
    func aSummaryDrawnFromTheNoteIsAppended() {
        let summary = """
        The pricing page redesign needs revised mockups sent to Priya and \
        usability sessions booked with the research team. The annual plan \
        toggle is still confusing.
        """
        #expect(
            NoteActionOutputGuard.evaluate(
                summary,
                for: .summarize,
                note: Self.note
            ) == .accept(summary)
        )
    }

    @Test
    func anAnswerToTheNoteIsNotAppendedAsASummary() {
        // What a model produces when it reads the note as a request rather
        // than as material: fluent, on topic, and none of it the user's.
        let answer = """
        Here are three ways to make an annual plan toggle clearer: label both \
        options with their billing period, show the yearly saving as a \
        percentage, and default to monthly so nobody is surprised.
        """
        #expect(
            NoteActionOutputGuard.evaluate(
                answer,
                for: .summarize,
                note: Self.note
            ) == .reject
        )
    }

    @Test
    func aSummaryLongerThanTheNoteIsNotAppended() {
        let sprawling = String(
            repeating: "The pricing page redesign mockups research team. ",
            count: 30
        )
        #expect(
            NoteActionOutputGuard.evaluate(
                sprawling,
                for: .summarize,
                note: Self.note
            ) == .reject
        )
    }

    @Test
    func actionItemsTheNoteAccountsForAreKept() {
        let result = """
        - Send Priya the revised mockups before Thursday
        - Book the usability sessions with the research team
        """
        #expect(
            NoteActionOutputGuard.evaluate(
                result,
                for: .actionItems,
                note: Self.note
            ) == .accept(result)
        )
    }

    @Test
    func anInventedActionItemIsDroppedAndTheRealOnesSurvive() {
        let result = """
        - Send Priya the revised mockups before Thursday
        - Migrate the billing service to Stripe and cancel the Braintree contract
        """
        let decision = NoteActionOutputGuard.evaluate(
            result,
            for: .actionItems,
            note: Self.note
        )
        #expect(
            decision == .accept(
                "- Send Priya the revised mockups before Thursday"
            )
        )
    }

    @Test
    func anActionListWithNothingFromTheNoteIsRefusedEntirely() {
        let result = """
        - Rewrite the onboarding emails
        - Interview candidates for the platform role
        """
        #expect(
            NoteActionOutputGuard.evaluate(
                result,
                for: .actionItems,
                note: Self.note
            ) == .reject
        )
    }

    @Test
    func proseWithNoListLinesIsNotAppendedAsActions() {
        // The instruction asks for "- " lines, so anything else is the model
        // talking to the user rather than answering with a list.
        #expect(
            NoteActionOutputGuard.evaluate(
                "I could not find any concrete commitments in this note.",
                for: .actionItems,
                note: Self.note
            ) == .reject
        )
    }

    @Test
    func anEmptyResultIsNeverAppended() {
        #expect(
            NoteActionOutputGuard.evaluate(
                "   \n  ",
                for: .summarize,
                note: Self.note
            ) == .reject
        )
        #expect(
            NoteActionOutputGuard.evaluate(
                "",
                for: .actionItems,
                note: Self.note
            ) == .reject
        )
    }
}
