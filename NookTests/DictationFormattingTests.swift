import Foundation
import Testing
@testable import Nook

/// Formatting commands are exact substitutions, so the table itself is the
/// contract: what a user says, what lands in their document.
struct DictationFormattingTests {
    @Test
    func paragraphAndLineCommandsBecomeBreaks() {
        #expect(DictationFormatting.apply(to: "new paragraph") == "\n\n")
        #expect(DictationFormatting.apply(to: "New Paragraph.") == "\n\n")
        #expect(DictationFormatting.apply(to: "  new line ") == "\n")
        #expect(DictationFormatting.apply(to: "NEW LINE.") == "\n")
    }

    /// Ordinary sentences pass through untouched, including ones that merely
    /// contain the words.
    @Test
    func ordinarySpeechIsNeverTouched() {
        let sentence = "We should open a new paragraph here about pricing"
        #expect(DictationFormatting.apply(to: sentence) == sentence)
        #expect(
            DictationFormatting.apply(to: "The new line item costs five dollars")
                == "The new line item costs five dollars"
        )
        #expect(DictationFormatting.apply(to: "") == "")
    }
}
