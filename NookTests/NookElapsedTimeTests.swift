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
}
