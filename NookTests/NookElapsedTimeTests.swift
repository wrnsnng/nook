import Foundation
import Testing
@testable import Nook

/// Every elapsed clock in the app reads from one formatter, so a meeting
/// that passes an hour reads the same in the menu bar, the panel, and the
/// floating notes window instead of each surface inventing its own format.
struct NookElapsedTimeTests {
    @Test
    func underAnHourShowsMinutesAndSeconds() {
        #expect(NookElapsedTime.clock(0) == "00:00")
        #expect(NookElapsedTime.clock(5) == "00:05")
        #expect(NookElapsedTime.clock(61) == "01:01")
    }

    @Test
    func theHourBoundaryKeepsSecondsVisible() {
        // The menu bar used to drop seconds at this boundary while every
        // other surface kept counting, so 59:59 jumped to 01:00:00 nowhere.
        #expect(NookElapsedTime.clock(3_599) == "59:59")
        #expect(NookElapsedTime.clock(3_600) == "1:00:00")
        #expect(NookElapsedTime.clock(3_661) == "1:01:01")
    }

    @Test
    func longMeetingsStayHonest() {
        #expect(NookElapsedTime.clock(7_258) == "2:00:58")
    }

    @Test
    func negativeIntervalsClampToZeroRatherThanGoingNegative() {
        #expect(NookElapsedTime.clock(-4) == "00:00")
    }

    @Test
    func spokenFormatNamesBothUnits() {
        #expect(NookElapsedTime.spoken(125) == "2 minutes, 5 seconds")
        #expect(NookElapsedTime.spoken(0) == "0 minutes, 0 seconds")
    }

    @Test
    func spokenFormatNamesHoursInsteadOfCountingPastSixty() {
        // "65 minutes" made an hour-long meeting sound like a long call, and
        // the menu bar announced a three-hour workshop as "185 minutes".
        #expect(NookElapsedTime.spoken(3_900) == "1 hour, 5 minutes, 0 seconds")
        #expect(
            NookElapsedTime.spoken(7_323) == "2 hours, 2 minutes, 3 seconds"
        )
    }

    @Test
    func spokenFormatUsesSingularUnitsForOne() {
        #expect(NookElapsedTime.spoken(61) == "1 minute, 1 second")
    }

    @Test
    func transcriptStampsKeepTheTwoDigitHourNotesAreWrittenWith() {
        // Notes already on disk carry "01:02:03". The emitter has to keep
        // producing exactly that, so this shape is deliberately not `clock`.
        #expect(NookElapsedTime.stamp(0) == "00:00")
        #expect(NookElapsedTime.stamp(62) == "01:02")
        #expect(NookElapsedTime.stamp(3_723) == "01:02:03")
        #expect(NookElapsedTime.stamp(-9) == "00:00")
    }

    @Test
    func everyStampInANoteComesFromTheSameFormatter() {
        let segment = TranscriptSegment(
            startTime: 3_723,
            duration: 4,
            text: "Synthetic line.",
            source: .system
        )
        #expect(segment.timestamp == NookElapsedTime.stamp(3_723))
        #expect(
            MeetingMoment(offset: 3_723).timestamp
                == NookElapsedTime.stamp(3_723)
        )
    }

    @Test
    func finishedDurationsRoundToWholeMinutes() {
        #expect(NookElapsedTime.minutes(45 * 60) == "45m")
        #expect(NookElapsedTime.minutes(3_600) == "1h")
        #expect(NookElapsedTime.minutes(3 * 3_600 + 25 * 60) == "3h 25m")
        #expect(NookElapsedTime.minutes(20) == "0m")
    }

    @Test
    func aSavedNoteNeverClaimsItLastedNoTime() {
        // A twenty-second recording is still a recording. "0m" in the library
        // reads as a note that failed to capture anything.
        #expect(NookElapsedTime.minutes(20, atLeastAMinute: true) == "1m")
    }

    @Test
    func theLibraryAndTheDigestAgreeOnTheSameDuration() {
        let note = MeetingNote(
            title: "Synthetic",
            startedAt: Date(),
            endedAt: Date().addingTimeInterval(3_600),
            sourceApp: "Zoom",
            summary: ""
        )
        #expect(note.durationLabel == "1h")
        #expect(
            DigestBuilder.conversationTimeLabel(for: 3_600)
                == "\(note.durationLabel) of conversation"
        )
    }
}
