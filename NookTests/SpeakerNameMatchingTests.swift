import Foundation
import Testing
@testable import Nook

struct SpeakerNameMatchingTests {
    /// Readings once a second from `start` up to (not including) `end`.
    private func highlighted(_ name: String, from start: Int, to end: Int) -> [ActiveSpeakerObservation] {
        (start..<end).map { ActiveSpeakerObservation(time: TimeInterval($0), name: name) }
    }

    private func line(
        _ start: TimeInterval, _ duration: TimeInterval,
        _ speaker: String? = nil, source: TranscriptSegment.Source = .system
    ) -> TranscriptSegment {
        TranscriptSegment(startTime: start, duration: duration, text: "Words.", source: source, speaker: speaker)
    }

    /// Each voice takes the name the meeting app highlighted while it spoke,
    /// on every line it said.
    @Test
    func voicesTakeTheNameHighlightedWhileTheySpoke() {
        let transcript = [
            line(0, 8, "Speaker 1"),
            line(9, 6, "Speaker 2"),
            line(16, 5, "Speaker 1"),
        ]
        let roster = MeetingRoster(
            participants: ["Ana Ruiz", "Ben Ode"],
            activeSpeakers: highlighted("Ana Ruiz", from: 0, to: 9)
                + highlighted("Ben Ode", from: 9, to: 16)
                + highlighted("Ana Ruiz", from: 16, to: 21)
        )
        let named = SpeakerNameMatching.named(transcript, roster: roster)
        #expect(named.map(\.speaker) == ["Ana Ruiz", "Ben Ode", "Ana Ruiz"])
    }

    /// When the highlight is split between two people, the voice keeps its
    /// placeholder for the user rather than taking a guessed name.
    @Test
    func anAmbiguousVoiceKeepsItsPlaceholder() {
        let transcript = [line(0, 10, "Speaker 1")]
        let roster = MeetingRoster(
            activeSpeakers: highlighted("Ana Ruiz", from: 0, to: 5) + highlighted("Ben Ode", from: 5, to: 10)
        )
        #expect(SpeakerNameMatching.names(for: transcript, roster: roster).isEmpty)
    }

    /// A brief overlap is not evidence.
    @Test
    func aMomentaryHighlightNamesNobody() {
        let transcript = [line(0, 10, "Speaker 1")]
        let roster = MeetingRoster(activeSpeakers: highlighted("Ana Ruiz", from: 0, to: 1))
        #expect(SpeakerNameMatching.names(for: transcript, roster: roster).isEmpty)
    }

    /// The user's own name is never given to someone on the other end, even
    /// when the app does not mark it: it is recognised from the microphone.
    @Test
    func theUsersOwnNameIsNeverGivenToAnotherVoice() {
        let transcript = [
            line(0, 6, source: .microphone),
            line(6, 6, "Speaker 1"),
            line(12, 6, source: .microphone),
        ]
        // The app keeps highlighting the user, slow to switch.
        let roster = MeetingRoster(activeSpeakers: highlighted("Jo Kay", from: 0, to: 18))
        #expect(SpeakerNameMatching.names(for: transcript, roster: roster).isEmpty)

        let marked = MeetingRoster(
            activeSpeakers: highlighted("Jo Kay", from: 6, to: 12),
            selfName: "Jo Kay"
        )
        #expect(SpeakerNameMatching.names(for: [line(6, 6, "Speaker 1")], roster: marked).isEmpty)
    }

    /// Several people behind one Zoom name, such as a meeting room, keep
    /// that name with a number each, in the order they first spoke.
    @Test
    func voicesSharingOneNameAreNumbered() {
        let transcript = [
            line(0, 6, "Unclear · voice 1"),
            line(7, 6, "Unclear · voice 2"),
            line(14, 6, "Unclear · voice 1"),
            line(21, 6, "Unclear · voice 3"),
        ]
        let roster = MeetingRoster(
            activeSpeakers: highlighted("Boardroom", from: 0, to: 21) + highlighted("Ana Ruiz", from: 21, to: 27)
        )
        let named = SpeakerNameMatching.named(transcript, roster: roster)
        #expect(named.map(\.speaker) == [
            "Boardroom · voice 1", "Boardroom · voice 2", "Boardroom · voice 1", "Ana Ruiz",
        ])
    }

    /// A gap in readings is not stretched into a name.
    @Test
    func unreadableStretchesAreNotFilledIn() {
        let transcript = [line(10, 10, "Speaker 1")]
        let roster = MeetingRoster(activeSpeakers: [ActiveSpeakerObservation(time: 9, name: "Ana Ruiz")])
        #expect(SpeakerNameMatching.names(for: transcript, roster: roster).isEmpty)
    }

    /// Names the user already chose are kept, and not reused for another voice.
    @Test
    func namesTheUserChoseAreLeftAlone() {
        let transcript = [line(0, 8, "Ana Ruiz"), line(9, 8, "Speaker 2")]
        let roster = MeetingRoster(activeSpeakers: highlighted("Ana Ruiz", from: 0, to: 17))
        let named = SpeakerNameMatching.named(transcript, roster: roster)
        #expect(named.map(\.speaker) == ["Ana Ruiz", "Speaker 2"])
    }

    /// Suggestions skip names in use, placeholders, repeats and unusable text.
    @Test
    func suggestionsOfferOnlyUnusedNames() {
        let transcript = [line(0, 4, "Ana Ruiz"), line(5, 4, "Speaker 2")]
        let suggestions = SpeakerNameMatching.suggestions(
            participants: ["Ben Ode", "ana ruiz", "Speaker 3", "ben ode", "**", "Cy Lam"],
            transcript: transcript
        )
        #expect(suggestions == ["Ben Ode", "Cy Lam"])
    }

    /// The names offered for a note survive a save and reload; notes without
    /// any keep the exact file they always had.
    @Test
    func participantsRoundTripThroughMarkdown() throws {
        var note = MeetingNote(
            title: "Budget",
            startedAt: Date(timeIntervalSince1970: 1_790_000_000),
            endedAt: Date(timeIntervalSince1970: 1_790_000_060),
            sourceApp: "Zoom",
            summary: "Budget talk.",
            transcript: [line(0, 4, "Speaker 1")]
        )
        #expect(!MarkdownCodec.encode(note).contains("participants:"))

        note.participants = ["Ana Ruiz", "Ben Ode"]
        let markdown = MarkdownCodec.encode(note)
        #expect(markdown.contains("participants: [\"Ana Ruiz\",\"Ben Ode\"]"))
        let decoded = try #require(MarkdownCodec.decode(markdown, fileURL: nil))
        #expect(decoded.participants == ["Ana Ruiz", "Ben Ode"])
    }

    /// Zoom's list comes first, then invitees, without the user or repeats.
    @MainActor
    @Test
    func offeredNamesPutTheMeetingAppFirstAndLeaveOutTheUser() {
        let roster = MeetingRoster(participants: ["Ana Ruiz", "Ben Ode"], selfName: "Jo Kay")
        let names = MeetingCoordinator.participantNames(
            roster: roster, invitees: ["ben ode", "Jo Kay", "Cy Lam"]
        )
        #expect(names == ["Ana Ruiz", "Ben Ode", "Cy Lam"])
    }

    /// Invitees come from the event the recording overlapped most, so a
    /// meeting that ran into the next slot keeps its own guests.
    @Test
    func inviteesComeFromTheEventTheMeetingOverlappedMost() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let own = CalendarMeetingEvent(
            title: "Budget", attendeeCount: 2, startDate: start,
            attendeeNames: ["Ana Ruiz", "Ben Ode"], endDate: start.addingTimeInterval(1_800)
        )
        let next = CalendarMeetingEvent(
            title: "Design", attendeeCount: 1, startDate: start.addingTimeInterval(1_800),
            attendeeNames: ["Cy Lam"], endDate: start.addingTimeInterval(3_600)
        )
        let names = CalendarContextService.attendeeNames(
            forMeetingFrom: start, to: start.addingTimeInterval(2_100), among: [own, next]
        )
        #expect(names == ["Ana Ruiz", "Ben Ode"])
    }

    /// With Zoom's panel closed nothing marks the user, so a name Zoom showed
    /// speaking while the microphone carried the speech is not offered.
    @MainActor
    @Test
    func theUserIsNotOfferedEvenWhenZoomDidNotMarkThem() {
        let transcript = [line(0, 6, source: .microphone), line(6, 6, "Speaker 1")]
        let roster = MeetingRoster(
            participants: ["Jo Kay", "Ana Ruiz"],
            activeSpeakers: highlighted("Jo Kay", from: 0, to: 6) + highlighted("Ana Ruiz", from: 6, to: 12)
        )
        let names = MeetingCoordinator.participantNames(
            roster: roster, invitees: [],
            userNames: SpeakerNameMatching.likelyUserNames(in: transcript, roster: roster)
        )
        #expect(names == ["Ana Ruiz"])
    }

    /// Zoom marks a speaker about a second late (measured on Zoom 7.1), so a
    /// turn whose start Zoom missed is still credited to them.
    @Test
    func zoomsLateMarkerStillCountsTheStartOfATurn() {
        let transcript = [line(10, 3.5, "Speaker 1")]
        let roster = MeetingRoster(activeSpeakers: highlighted("Ana Ruiz", from: 11, to: 14))
        #expect(SpeakerNameMatching.names(for: transcript, roster: roster) == ["Speaker 1": "Ana Ruiz"])
    }
}
