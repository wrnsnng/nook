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
    func pollingWakesAsTheNextEventEntersThePromptWindow() {
        let now = Date(timeIntervalSince1970: 1_000_000)

        // An event 15 minutes out: wake as it comes within ten minutes, so a
        // late timer still finds it well inside the window.
        let delay = CalendarContextService.nextPollDelay(
            now: now,
            eventStarts: [now.addingTimeInterval(15 * 60)]
        )
        #expect(delay == .seconds(5 * 60))

        // An event already in the window has been announced; wake as it
        // leaves so the notch stops showing it, unless another event enters
        // first.
        let leaving = CalendarContextService.nextPollDelay(
            now: now,
            eventStarts: [now.addingTimeInterval(5 * 60)]
        )
        #expect(leaving == .seconds(5 * 60 - 90))
        let entering = CalendarContextService.nextPollDelay(
            now: now,
            eventStarts: [
                now.addingTimeInterval(5 * 60),
                now.addingTimeInterval(12 * 60),
            ]
        )
        #expect(entering == .seconds(2 * 60))
    }

    @Test
    func pollingNeverWaitsLessThanAMinuteOrMoreThanTenMinutes() {
        let now = Date(timeIntervalSince1970: 1_000_000)

        // An event about to enter the window clamps to the minimum, not a
        // near-zero delay that would spin the poll loop.
        let imminent = CalendarContextService.nextPollDelay(
            now: now,
            eventStarts: [now.addingTimeInterval(10 * 60 + 5)]
        )
        #expect(imminent == .seconds(CalendarContextService.minimumPollInterval))

        // Nothing known about the future, or only events already starting:
        // bounded rather than polling forever at the old fixed 60 second
        // cadence.
        for starts in [[], [now.addingTimeInterval(30)]] {
            #expect(
                CalendarContextService.nextPollDelay(now: now, eventStarts: starts)
                    == .seconds(CalendarContextService.maximumPollInterval)
            )
        }

        // An event hours away also clamps to the maximum.
        let farOut = CalendarContextService.nextPollDelay(
            now: now,
            eventStarts: [now.addingTimeInterval(3 * 60 * 60)]
        )
        #expect(farOut == .seconds(CalendarContextService.maximumPollInterval))
    }

    /// The poll loop, driven through the hour before a meeting with the
    /// timer waking late the way real timers do. Swift's `Task.sleep` with no
    /// tolerance lands on `dispatch_after`, whose default leeway is a tenth of
    /// the interval up to a minute, and App Nap coalesces a menu bar app's
    /// timers further still. The heads-up has to survive that from wherever
    /// the loop happens to start.
    ///
    /// It did not: scheduling aimed the next poll at the very instant the event
    /// left the prompt window, so any lateness at all landed after it and the
    /// event was never announced.
    @Test
    func theHeadsUpStillArrivesWhenThePollWakesLate() async {
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

        let start = Date(timeIntervalSince1970: 2_000_000)
        let meeting = CalendarMeetingEvent(
            title: "Design review",
            attendeeCount: 3,
            startDate: start
        )
        let lateness: [(String, (TimeInterval) -> TimeInterval)] = [
            ("a second late", { _ in 1 }),
            ("default timer leeway", { min($0 / 10, 60) }),
        ]

        for (name, late) in lateness {
            var missed: [Int] = []
            // Wherever the loop is when the hour begins: launch, a calendar
            // edit, or waking from sleep all restart it at an arbitrary time.
            for lead in stride(from: 60 * 60, through: 91, by: -7) {
                CalendarContextService.clearPersistedPromptedEventKeys()
                let clock = TestClock(start.addingTimeInterval(-Double(lead)))
                let service = CalendarContextService(
                    provider: FixedCalendarProvider(events: [meeting]),
                    now: { clock.now },
                    enabled: true
                )
                var prompted: [CalendarMeetingEvent] = []
                service.onUpcomingEvent = { prompted.append($0) }

                while clock.now < start {
                    let delay = await service.pollOnce()
                    let seconds = Double(delay.components.seconds)
                    clock.now.addTimeInterval(seconds + late(seconds))
                }
                if prompted != [meeting] { missed.append(lead) }
            }
            #expect(
                missed.isEmpty,
                "With \(name), no heads-up when polling began \(missed.count) of these many seconds before: \(missed.prefix(12))"
            )
        }
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

@MainActor
private final class TestClock {
    var now: Date
    init(_ now: Date) { self.now = now }
}

/// A calendar that holds the given events. Like EventKit, a range query also
/// returns an event already underway.
private struct FixedCalendarProvider: CalendarEventProviding {
    let events: [CalendarMeetingEvent]

    func requestAccess() async -> Bool { true }

    func events(between start: Date, end: Date) -> [CalendarMeetingEvent] {
        events.filter {
            $0.startDate >= start.addingTimeInterval(-30 * 60)
                && $0.startDate <= end
        }
    }
}
