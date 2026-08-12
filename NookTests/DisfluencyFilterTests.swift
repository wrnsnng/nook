import Testing
@testable import Nook

/// Clean-up edits words that are about to be typed into someone's document, so
/// the tests that matter most are the ones asserting it leaves things alone.
struct DisfluencyFilterTests {
    @Test
    func removesStandaloneHesitations() {
        #expect(
            DisfluencyFilter.clean("Um, so I think we should ship it")
                == "So I think we should ship it"
        )
    }

    /// Dropping a bracketed filler must not leave its punctuation behind.
    @Test
    func removesTheCommaStrandedByAFiller() {
        #expect(
            DisfluencyFilter.clean("We should, uh, ship it")
                == "We should ship it"
        )
    }

    @Test
    func collapsesStutteredWords() {
        #expect(
            DisfluencyFilter.clean("I I I think the the plan works")
                == "I think the plan works"
        )
    }

    @Test
    func keepsGrammaticalDoubles() {
        #expect(
            DisfluencyFilter.clean("He had had enough by then")
                == "He had had enough by then"
        )
    }

    /// Reading a code or a phone number aloud repeats digits deliberately.
    /// Collapsing them deletes information the speaker cannot get back and may
    /// not notice is missing.
    @Test
    func neverCollapsesRepeatedNumbers() {
        #expect(
            DisfluencyFilter.clean("five five five one two three four")
                == "five five five one two three four"
        )
        #expect(
            DisfluencyFilter.clean("The code is 8 8 8 2")
                == "The code is 8 8 8 2"
        )
        #expect(
            DisfluencyFilter.clean("Room two two, level six six")
                == "Room two two, level six six"
        )
    }

    /// A letter read out as part of a code is data, exactly like a digit.
    /// "I I I think" is still a stutter, so the two must stay distinguishable.
    @Test
    func neverCollapsesLettersBeingSpelledOut() {
        #expect(DisfluencyFilter.clean("The code is A A 7 3") == "The code is A A 7 3")
        #expect(DisfluencyFilter.clean("It is B B C") == "It is B B C")
        #expect(
            DisfluencyFilter.clean("I I think we need 3 more")
                == "I think we need 3 more"
        )
    }

    @Test
    func judgesLongRepetitionRunsCorrectly() {
        #expect(DisfluencyFilter.clean("The code is A A A 7") == "The code is A A A 7")
        #expect(DisfluencyFilter.clean("I I I think it works") == "I think it works")
    }

    /// A hesitation between the letters must not cost one of them. Judging a
    /// letter by its neighbours failed exactly here, because the filler sits
    /// between the letter and the evidence.
    ///
    /// The dropped filler also takes the comma that bracketed it, which is the
    /// existing clean-up behaviour and why the commas move.
    @Test
    func spelledOutLettersSurviveAHesitationBetweenThem() {
        #expect(
            DisfluencyFilter.clean("The code is 7, um, A, A")
                == "The code is 7 A, A"
        )
        #expect(DisfluencyFilter.clean("A, A, um, 7") == "A, A 7")
    }

    /// And the mirror image: a number after an ordinary stutter must not make
    /// the stutter look like a code being read out.
    @Test
    func aNumberAfterAStutterDoesNotProtectIt() {
        #expect(
            DisfluencyFilter.clean("I I 3 of us need to go")
                == "I 3 of us need to go"
        )
        #expect(DisfluencyFilter.clean("I I need 5 minutes") == "I need 5 minutes")
    }

    /// These rules are reasoned about English, and Nook transcribes ten
    /// languages. In a script without case, a repeated character is far more
    /// likely to be meaningful than a stumble.
    @Test
    func leavesNonLatinScriptsUntouched() {
        #expect(DisfluencyFilter.clean("時時に見る") == "時時に見る")
        #expect(DisfluencyFilter.clean("そう そう です") == "そう そう です")
    }

    /// The lowercase article stutters like any other short word.
    @Test
    func theArticleIsStillTreatedAsAStutter() {
        #expect(DisfluencyFilter.clean("It was a a good result") == "It was a good result")
    }

    /// Letters other than the two that are English words are spoken data, and
    /// are kept without relying on how the recognizer capitalized them.
    @Test
    func keepsRepeatedLettersWhateverTheirCase() {
        #expect(DisfluencyFilter.clean("The code is b b 7") == "The code is b b 7")
        #expect(DisfluencyFilter.clean("Section d d applies") == "Section d d applies")
    }

    /// Collapsing away the opening word leaves a mid-sentence, lowercase word
    /// at the start of the sentence.
    @Test
    func recapitalizesAfterCollapsingTheOpeningWord() {
        #expect(DisfluencyFilter.clean("The the cat sat") == "The cat sat")
        #expect(DisfluencyFilter.clean("A a good result") == "A good result")
    }

    /// European stutters still collapse; the case test must not exempt them
    /// the way testing for ASCII would have.
    @Test
    func collapsesStuttersInOtherLatinLanguages() {
        #expect(DisfluencyFilter.clean("Je je pense que oui") == "Je pense que oui")
    }

    /// A repeated longer word is emphasis, not a stutter.
    @Test
    func keepsDeliberateRepetitionForEmphasis() {
        #expect(
            DisfluencyFilter.clean("That was really really good")
                == "That was really really good"
        )
        #expect(DisfluencyFilter.clean("No no, the other one") == "No no, the other one")
    }

    @Test
    func removesCommaDelimitedAsides() {
        #expect(
            DisfluencyFilter.clean("It was, you know, quite good")
                == "It was quite good"
        )
        #expect(
            DisfluencyFilter.clean("I mean, that is the whole problem")
                == "That is the whole problem"
        )
    }

    /// The same words carry meaning without the commas, and deleting them
    /// there would silently change what the user said.
    @Test
    func keepsTheSameWordsWhenTheyAreNotAsides() {
        #expect(
            DisfluencyFilter.clean("Do you know the answer")
                == "Do you know the answer"
        )
        #expect(
            DisfluencyFilter.clean("You know the answer already")
                == "You know the answer already"
        )
        #expect(
            DisfluencyFilter.clean("I mean it sincerely")
                == "I mean it sincerely"
        )
    }

    /// Every one of these doubles as a filler in speech, and every one is a
    /// real word often enough that removing it is the worse mistake.
    @Test
    func leavesAmbiguousFillerWordsAlone() {
        let sentence = "So like, well, right, I do so like this"
        #expect(DisfluencyFilter.clean(sentence) == sentence)
    }

    @Test
    func capitalizesTheWordLeftAtTheStart() {
        #expect(DisfluencyFilter.clean("Uh, they shipped it") == "They shipped it")
    }

    @Test
    func preservesTextWithNothingToRemove() {
        let sentence = "Ship the release on Friday and tell the team."
        #expect(DisfluencyFilter.clean(sentence) == sentence)
    }

    @Test
    func handlesSpeechThatIsEntirelyHesitation() {
        #expect(DisfluencyFilter.clean("um uh hmm").isEmpty)
    }

    @Test
    func handlesEmptyInput() {
        #expect(DisfluencyFilter.clean("").isEmpty)
    }
}
