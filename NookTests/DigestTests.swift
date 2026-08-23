import Foundation
import Testing
@testable import Nook

/// A digest compiles the week deterministically: real counts, real decisions,
/// no invented outcomes. The only model-written part is an optional overview,
/// and the digest is complete without it.
@MainActor
struct DigestTests {
    private func meeting(
        _ title: String,
        daysAgo: Double,
        decisions: [String] = [],
        keyPoints: [String] = [],
        moments: Int = 0
    ) -> MeetingNote {
        MeetingNote(
            title: title,
            startedAt: Date().addingTimeInterval(-daysAgo * 86_400),
            endedAt: Date().addingTimeInterval(-daysAgo * 86_400 + 3_600),
            sourceApp: "Zoom",
            summary: "\(title) happened.",
            keyPoints: keyPoints,
            decisions: decisions,
            moments: (0..<moments).map { MeetingMoment(offset: Double($0) * 60) }
        )
    }

    @Test
    func theDigestCoversOnlyTheLastSevenDays() async {
        let inside = meeting("Standup", daysAgo: 2)
        let outside = meeting("Old offsite", daysAgo: 12)

        let digest = await DigestBuilder.build(
            from: [inside, outside],
            overviewProvider: { _ in nil }
        )

        #expect(digest.kind == .digest)
        #expect(digest.summary.contains("1 meeting between"))
        // Each helper meeting runs an hour; the week's conversation time is
        // stated plainly.
        #expect(digest.summary.contains("1h of conversation"))
        #expect(!digest.summary.contains("Offsite"))
        // No model, no overview paragraph beyond the deterministic facts.
        #expect(digest.keyPoints.isEmpty)
    }

    @Test
    func conversationTimeLabelsStayHuman() {
        #expect(
            DigestBuilder.conversationTimeLabel(for: 45 * 60)
                == "45m of conversation"
        )
        #expect(
            DigestBuilder.conversationTimeLabel(for: 60 * 60)
                == "1h of conversation"
        )
        #expect(
            DigestBuilder.conversationTimeLabel(for: 3 * 3_600 + 25 * 60)
                == "3h 25m of conversation"
        )
    }

    @Test
    func decisionsAreDeduplicatedAcrossMeetings() async {
        let monday = meeting(
            "Monday",
            daysAgo: 1,
            decisions: ["Hold pricing until q4"],
            keyPoints: ["Tiers questioned"]
        )
        let tuesday = meeting(
            "Tuesday",
            daysAgo: 0.5,
            decisions: ["Hold pricing until q4", "Ship friday"],
            keyPoints: ["Tiers questioned"]
        )

        let digest = await DigestBuilder.build(
            from: [monday, tuesday],
            overviewProvider: { _ in nil }
        )

        #expect(digest.decisions == ["Hold pricing until q4", "Ship friday"])
        // A week with more than one meeting stays plural.
        #expect(digest.summary.contains("2 meetings between"))
        // Two highlights per meeting maximum, labelled with their source.
        #expect(
            digest.keyPoints == [
                "Monday: Tiers questioned",
                "Tuesday: Tiers questioned"
            ]
        )
    }

    @Test
    func flaggedMomentsAreCounted() async {
        let flagged = meeting("Review", daysAgo: 1, moments: 3)

        let digest = await DigestBuilder.build(
            from: [flagged],
            overviewProvider: { _ in nil }
        )

        #expect(digest.summary.contains("3 moments flagged"))
    }

    /// A digest round-trips like any note, and its file carries no transcript.
    @Test
    func digestSurvivesTheRoundTrip() throws {
        let digest = MeetingNote(
            kind: .digest,
            title: "Week of Aug 16",
            startedAt: Date(timeIntervalSince1970: 1_000_000),
            endedAt: Date(timeIntervalSince1970: 1_060_000),
            sourceApp: "Digest",
            summary: "2 meetings. Lots of shipping.",
            keyPoints: ["Review: Tiers questioned"],
            decisions: ["Ship friday"]
        )

        let encoded = MarkdownCodec.encode(digest)
        #expect(encoded.contains("kind: digest"))
        #expect(!encoded.contains("## Transcript"))
        #expect(!encoded.contains("## My notes"))

        let decoded = try #require(MarkdownCodec.decode(encoded))
        #expect(decoded.kind == .digest)
        #expect(MarkdownCodec.encode(decoded) == encoded)
    }

    /// `coveredMeetings` is `build`'s own 7-day filter, exposed so a caller
    /// deciding whether there is anything to compile does not need a second
    /// copy of the window logic.
    @Test
    func coveredMeetingsMatchesWhatBuildItselfCompiles() async {
        let inside = meeting("Standup", daysAgo: 2)
        let outside = meeting("Old offsite", daysAgo: 12)

        let covered = DigestBuilder.coveredMeetings(from: [inside, outside])
        #expect(covered.map(\.title) == ["Standup"])

        let digest = await DigestBuilder.build(
            from: [inside, outside],
            overviewProvider: { _ in nil }
        )
        #expect(digest.summary.contains("1 meeting between"))
    }

    /// Creating a digest twice for the same week must update the existing
    /// file rather than leave a second, near-duplicate one behind.
    @Test
    func buildReusesTheGivenIdAndFileURLWhenProvided() async {
        let existingID = UUID()
        let existingURL = URL(fileURLWithPath: "/tmp/week-of-test.md")
        let meetingNote = meeting("Standup", daysAgo: 1)

        let digest = await DigestBuilder.build(
            from: [meetingNote],
            id: existingID,
            fileURL: existingURL,
            overviewProvider: { _ in nil }
        )

        #expect(digest.id == existingID)
        #expect(digest.fileURL == existingURL)
    }

    /// Without an explicit id or URL, `build` behaves exactly as before:
    /// a fresh identity for a fresh file.
    @Test
    func buildDefaultsToAFreshIdentityWhenNoneIsGiven() async {
        let meetingNote = meeting("Standup", daysAgo: 1)

        let digest = await DigestBuilder.build(
            from: [meetingNote],
            overviewProvider: { _ in nil }
        )

        #expect(digest.fileURL == nil)
    }
}
