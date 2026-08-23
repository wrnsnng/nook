import Foundation
import Testing
@testable import Nook

/// Prep briefs recognize a recurring event's earlier sittings by normalized
/// title and assemble a read-only brief from those notes. Everything is
/// quoted from the library; nothing is invented before an important meeting.
@MainActor
struct PrepBriefTests {
    private func sitting(
        _ title: String,
        daysAgo: Int = 7,
        decisions: [String] = [],
        keyPoints: [String] = [],
        actionItems: [String] = []
    ) -> MeetingNote {
        MeetingNote(
            title: title,
            startedAt: Calendar.current.date(
                byAdding: .day,
                value: -daysAgo,
                to: Date(timeIntervalSince1970: 1_800_000_000)
            )!,
            endedAt: Calendar.current.date(
                byAdding: .day,
                value: -daysAgo,
                to: Date(timeIntervalSince1970: 1_800_003_600)
            )!,
            sourceApp: "Zoom",
            summary: "Sitting of \(title).",
            keyPoints: keyPoints,
            decisions: decisions,
            actionItems: actionItems
        )
    }

    // MARK: Series identity

    @Test
    func titlesOfTheSameSeriesConvergeOnOneKey() {
        let variants = [
            "Design review",
            "design review",
            "Design Review!",
            "Design review (weekly)",
            "Weekly design review, 23 Aug",
            "Design Review at 10am",
        ]

        let keys = Set(variants.map { SeriesMatcher.seriesKey(for: $0) })

        #expect(keys.count == 1)
    }

    @Test
    func genuinelyDifferentMeetingsStayDifferent() {
        #expect(
            SeriesMatcher.seriesKey(for: "Design review")
                != SeriesMatcher.seriesKey(for: "Retro")
        )
        // Dropping connective grammar must not erase what the meeting is.
        #expect(
            !SeriesMatcher.matches(
                noteTitle: "Budget planning",
                eventTitle: "Roadmap planning"
            )
        )
    }

    @Test
    func aTitleWithOnlyDatesAndCadenceHasNoIdentity() {
        #expect(SeriesMatcher.seriesKey(for: "23/08 10:00").isEmpty)
        #expect(SeriesMatcher.seriesKey(for: "").isEmpty)
        // An empty key must never match everything.
        #expect(
            !SeriesMatcher.matches(noteTitle: "Anything", eventTitle: "12pm")
        )
    }

    // MARK: Assembly

    @Test
    func aBriefAssemblesTheSeriesHistoryInOrder() throws {
        let notes = [
            sitting("Unrelated lunch"),
            sitting(
                "Platform sync",
                daysAgo: 21,
                decisions: ["Ship v2 behind a flag"],
                actionItems: ["Draft the migration note"]
            ),
            sitting("Unrelated retro"),
            sitting(
                "platform sync",
                daysAgo: 7,
                decisions: ["Keep the rollout staged"],
                keyPoints: ["Latency halved"],
                actionItems: [
                    "Draft the migration note",
                    "Book load testing",
                ]
            ),
        ]
        let start = Date(timeIntervalSince1970: 1_900_000_000)

        let brief = try #require(
            PrepBriefBuilder.build(
                eventTitle: "Platform Sync (weekly)",
                startDate: start,
                notes: notes
            )
        )

        #expect(brief.sittings.count == 2)
        #expect(brief.sittings.first?.title == "platform sync")
        // This event continues the series.
        #expect(brief.upcomingSittingNumber == 3)
        #expect(brief.lastDecisions == ["Keep the rollout staged"])
        #expect(brief.lastKeyPoints == ["Latency halved"])
        // Actions are listed oldest sitting first so history reads forward.
        #expect(brief.mentionedActions.map(\.text) == [
            "Draft the migration note",
            "Draft the migration note",
            "Book load testing",
        ])
        // Oldest sitting first, so history reads forward.
        #expect(brief.mentionedActions.map(\.noteTitle) == [
            "Platform sync",
            "platform sync",
            "platform sync",
        ])
        #expect(brief.startDate == start)
    }

    @Test
    func anEventWithoutHistoryProducesNoBrief() {
        let notes = [sitting("Board meeting", daysAgo: 3)]

        #expect(
            PrepBriefBuilder.build(
                eventTitle: "Design review",
                startDate: Date(),
                notes: notes
            ) == nil
        )
    }

    @Test
    func digestsNeverCountAsHistory() {
        var notes = [sitting("Design review", daysAgo: 3)]
        notes[0].kind = .digest

        #expect(
            PrepBriefBuilder.build(
                eventTitle: "Design review",
                startDate: Date(),
                notes: notes
            ) == nil
        )
    }
}
