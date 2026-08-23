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

    // MARK: - Poll scheduling

    @Test
    func pollingWaitsForTheNextEventRatherThanAFixedInterval() {
        let now = Date(timeIntervalSince1970: 1_000_000)

        // An event 5 minutes out: wake up 90 seconds before it would drop
        // below the prompt horizon's lower bound.
        let delay = CalendarContextService.nextPollDelay(
            now: now,
            nextEventStart: now.addingTimeInterval(5 * 60)
        )
        #expect(delay == .seconds(5 * 60 - 90))
    }

    @Test
    func pollingNeverWaitsLessThanAMinuteOrMoreThanTenMinutes() {
        let now = Date(timeIntervalSince1970: 1_000_000)

        // An event almost upon us clamps to the minimum, not a negative or
        // near-zero delay that would spin the poll loop.
        let imminent = CalendarContextService.nextPollDelay(
            now: now,
            nextEventStart: now.addingTimeInterval(30)
        )
        #expect(imminent == .seconds(CalendarContextService.minimumPollInterval))

        // Nothing known about the future: bounded rather than polling
        // forever at the old fixed 60 second cadence.
        let nothingKnown = CalendarContextService.nextPollDelay(
            now: now,
            nextEventStart: nil
        )
        #expect(nothingKnown == .seconds(CalendarContextService.maximumPollInterval))

        // An event hours away also clamps to the maximum.
        let farOut = CalendarContextService.nextPollDelay(
            now: now,
            nextEventStart: now.addingTimeInterval(3 * 60 * 60)
        )
        #expect(farOut == .seconds(CalendarContextService.maximumPollInterval))
    }

    // MARK: - Persisting today's prompts across a relaunch

    @Test
    func aPromptedEventStaysPromptedForTheRestOfTheDay() {
        let defaults = UserDefaults.standard
        let dayKey = "CalendarContextService.promptedEventKeysDay"
        let valuesKey = "CalendarContextService.promptedEventKeysValues"
        let previousDay = defaults.object(forKey: dayKey)
        let previousValues = defaults.object(forKey: valuesKey)
        defer {
            if let previousDay {
                defaults.set(previousDay, forKey: dayKey)
            } else {
                defaults.removeObject(forKey: dayKey)
            }
            if let previousValues {
                defaults.set(previousValues, forKey: valuesKey)
            } else {
                defaults.removeObject(forKey: valuesKey)
            }
        }

        CalendarContextService.clearPersistedPromptedEventKeys()
        #expect(CalendarContextService.loadPromptedEventKeys().isEmpty)

        // Simulates a relaunch inside the same prompt window: the keys
        // persisted before the process ended are still there afterwards.
        CalendarContextService.persist(["standup|123"])
        #expect(
            CalendarContextService.loadPromptedEventKeys() == ["standup|123"]
        )

        CalendarContextService.clearPersistedPromptedEventKeys()
        #expect(CalendarContextService.loadPromptedEventKeys().isEmpty)
    }

    @Test
    func aPromptFromAnEarlierDayDoesNotSurvive() {
        let defaults = UserDefaults.standard
        let dayKey = "CalendarContextService.promptedEventKeysDay"
        let valuesKey = "CalendarContextService.promptedEventKeysValues"
        let previousDay = defaults.object(forKey: dayKey)
        let previousValues = defaults.object(forKey: valuesKey)
        defer {
            if let previousDay {
                defaults.set(previousDay, forKey: dayKey)
            } else {
                defaults.removeObject(forKey: dayKey)
            }
            if let previousValues {
                defaults.set(previousValues, forKey: valuesKey)
            } else {
                defaults.removeObject(forKey: valuesKey)
            }
        }

        // A key recorded "yesterday" (any day that is not today) must not
        // leak into today's prompted set, or a new event that happens to
        // share a start time and title could be silently skipped.
        defaults.set("2000-01-01", forKey: dayKey)
        defaults.set(["stale|1"], forKey: valuesKey)

        #expect(CalendarContextService.loadPromptedEventKeys().isEmpty)
    }
}
