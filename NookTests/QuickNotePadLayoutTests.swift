import Foundation
import Testing
@testable import Nook

/// The pad has one editor, one bar, and room for two rows in between. These
/// pin which two, because the alternative is what shipped before: three
/// stacked banners over a row of controls, with the privacy warning the first
/// thing to be pushed out of sight.
struct QuickNotePadLayoutTests {
    private func rows(
        outbound: String? = nil,
        notice: String? = nil,
        noticeIsFailure: Bool = true,
        hearing: String? = nil,
        suggestion: Bool = false,
        assistant: Bool = true
    ) -> [QuickNotePadRow] {
        QuickNotePadLayout.rows(
            outboundProvider: outbound,
            notice: notice,
            noticeIsFailure: noticeIsFailure,
            hearing: hearing,
            hasSuggestion: suggestion,
            hasAssistant: assistant
        )
    }

    @Test
    func aQuietPadShowsNothingAboveItsBar() {
        #expect(rows().isEmpty)
    }

    @Test
    func voiceDecisionsPrecedeLiveGuessesWithoutDisplacingPrivacyOrFailures() {
        let normal = QuickNotePadLayout.rows(
            outboundProvider: "OpenAI", notice: nil, noticeIsFailure: false,
            hearing: "another thought", hasSuggestion: true, hasAssistant: true, hasVoiceStatus: true
        )
        #expect(normal == [.outbound(provider: "OpenAI"), .voice])
        let failed = QuickNotePadLayout.rows(
            outboundProvider: "OpenAI", notice: "Save failed", noticeIsFailure: true,
            hearing: "another thought", hasSuggestion: true, hasAssistant: true, hasVoiceStatus: true
        )
        #expect(failed == [.outbound(provider: "OpenAI"), .notice(text: "Save failed", isFailure: true)])
    }

    @Test
    func neverMoreThanTwoRows() {
        let crowded = rows(
            outbound: "Anthropic",
            notice: "Couldn't save this note.",
            hearing: "call priya about the",
            suggestion: true,
            assistant: true
        )
        #expect(crowded.count == 2)
    }

    @Test
    func thePrivacyWarningIsNeverTheRowThatGetsDropped() {
        let crowded = rows(
            outbound: "OpenAI",
            notice: "Couldn't save this note.",
            hearing: "call priya about the",
            suggestion: true
        )
        #expect(crowded.first == .outbound(provider: "OpenAI"))
    }

    @Test
    func aFailureIsShownBeforeALiveGuessOrASuggestion() {
        let shown = rows(
            notice: "Couldn't save this note.",
            hearing: "call priya about the",
            suggestion: true
        )
        #expect(
            shown == [
                .notice(text: "Couldn't save this note.", isFailure: true),
                .hearing(text: "call priya about the"),
            ]
        )
    }

    @Test
    func aDecisionNookMadeIsNotDressedAsAFailure() {
        let shown = rows(
            notice: QuickNoteController.keptYourOwnWordsNotice,
            noticeIsFailure: false
        )
        #expect(
            shown == [
                .notice(
                    text: QuickNoteController.keptYourOwnWordsNotice,
                    isFailure: false
                ),
            ]
        )
    }

    @Test
    func anEmptyMessageIsNotARow() {
        #expect(rows(notice: "").isEmpty)
        #expect(rows(hearing: "").isEmpty)
    }

    @Test
    func aMacWithNoAssistantIsToldWhatToDoAboutIt() {
        #expect(rows(assistant: false) == [.noAssistant])
    }

    @Test
    func theSuggestionYieldsToTheLiveGuessWhileWordsAreStillArriving() {
        // Both are about the sentence being spoken right now, and the one that
        // moves is the one worth the space.
        let shown = rows(
            outbound: "Anthropic",
            hearing: "call priya about the",
            suggestion: true
        )
        #expect(shown.contains(.hearing(text: "call priya about the")))
        #expect(!shown.contains(.suggestion))
    }
}
