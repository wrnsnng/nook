import Testing
@testable import Nook

/// The guard is the only thing standing between a language model's opinion and
/// the user's document, so it is tested against the ways a rewrite actually
/// goes wrong rather than against its own thresholds.
struct DictationOutputGuardTests {
    @Test
    func acceptsAFaithfulRewrite() {
        let decision = DictationOutputGuard.evaluate(
            refined: "Could you send the deployment notes before Friday?",
            spoken: "so could you uh send me the deployment notes before friday"
        )

        #expect(
            decision.text == "Could you send the deployment notes before Friday?"
        )
    }

    /// The failure this exists to prevent: the user dictates a question meaning
    /// to type it, and the model answers it instead.
    @Test
    func rejectsAnAnswerToADictatedQuestion() {
        let decision = DictationOutputGuard.evaluate(
            refined: "The capital of Australia is Canberra.",
            spoken: "hey what do you reckon the capital of australia is again"
        )

        #expect(decision.text == nil)
    }

    @Test
    func rejectsAnInstructionThatWasFollowedInsteadOfWritten() {
        let decision = DictationOutputGuard.evaluate(
            refined: """
            Here are three options: a phased rollout, a full launch, \
            or a limited beta with selected customers first.
            """,
            spoken: "give me a few options for how we could roll this out"
        )

        #expect(decision.text == nil)
    }

    @Test
    func rejectsEmptyOutput() {
        #expect(
            DictationOutputGuard.evaluate(refined: "   ", spoken: "ship it")
                == .reject(.empty)
        )
    }

    @Test
    func rejectsOutputThatBalloons() {
        let decision = DictationOutputGuard.evaluate(
            refined: """
            I would be delighted to confirm that we will indeed be shipping \
            the release on Friday afternoon, subject of course to the usual \
            checks and the availability of the wider team.
            """,
            spoken: "we ship Friday"
        )

        #expect(decision == .reject(.tooLong))
    }

    @Test
    func rejectsOutputThatCollapses() {
        let decision = DictationOutputGuard.evaluate(
            refined: "Yes.",
            spoken: "I think we should go ahead with the migration next week"
        )

        #expect(decision == .reject(.tooShort))
    }

    /// "On my way" has too few content words for an overlap ratio to mean
    /// anything, so short utterances are judged on length alone.
    @Test
    func allowsShortUtterancesThroughTheOverlapTest() {
        let decision = DictationOutputGuard.evaluate(
            refined: "On my way.",
            spoken: "on my way"
        )

        #expect(decision.text == "On my way.")
    }

    @Test
    func acceptsWhenThereIsNoSpokenTextToCompare() {
        #expect(
            DictationOutputGuard.evaluate(refined: "Hello", spoken: "")
                == .accept("Hello")
        )
    }

    @Test
    func contentWordsIgnoreFunctionWordsAndShortTokens() {
        let words = DictationOutputGuard.contentWords(
            in: "The team will ship the migration to production"
        )

        #expect(words.contains("team"))
        #expect(words.contains("migration"))
        #expect(words.contains("production"))
        #expect(!words.contains("the"))
        #expect(!words.contains("will"))
        #expect(!words.contains("to"))
    }
}
