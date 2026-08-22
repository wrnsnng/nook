import Foundation
import Testing
@testable import Nook

/// Calendar context names meetings and prompts before they start, but only
/// from events close enough to matter, and never twice for the same one.
@MainActor
struct CalendarContextTests {
    private func event(
        _ title: String,
        startingIn seconds: TimeInterval,
        from now: Date = Date(timeIntervalSince1970: 1_000_000)
    ) -> CalendarMeetingEvent {
        CalendarMeetingEvent(
            title: title,
            attendeeCount: 0,
            startDate: now.addingTimeInterval(seconds)
        )
    }

    @Test
    func enrichmentPicksTheNearestEventEitherSideOfNow() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let earlier = event("Standup", startingIn: -120)
        let later = event("Design review", startingIn: 60)

        #expect(
            CalendarContextService.nearestEvent(
                to: now,
                among: [earlier, later]
            ) == later
        )
        #expect(
            CalendarContextService.nearestEvent(to: now, among: []) == nil
        )
    }

    @Test
    func thePromptFiresInsideTheHorizonOnlyOnce() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let soon = event("Design review", startingIn: 5 * 60)
        let tooSoon = event("Right now", startingIn: 30)
        let tooFar = event("Later today", startingIn: 45 * 60)

        // Events already underway are not prompt material; nor are ones too
        // far out to act on.
        #expect(
            CalendarContextService.promptCandidate(
                now: now,
                among: [tooSoon, tooFar],
                alreadyPrompted: []
            ) == nil
        )

        let first = CalendarContextService.promptCandidate(
            now: now,
            among: [soon],
            alreadyPrompted: []
        )
        #expect(first == soon)

        // Dismissing must never nag again for the same event.
        let second = CalendarContextService.promptCandidate(
            now: now,
            among: [soon],
            alreadyPrompted: [soon.key]
        )
        #expect(second == nil)
    }

    @Test
    func theEarliestEligibleEventWinsThePrompt() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let first = event("First", startingIn: 3 * 60)
        let second = event("Second", startingIn: 8 * 60)

        #expect(
            CalendarContextService.promptCandidate(
                now: now,
                among: [second, first],
                alreadyPrompted: []
            ) == first
        )
    }
}
