import CoreMedia
import Foundation
import Testing
@testable import Nook

/// Captions used to rebuild the entire transcript on every partial revision,
/// so cost grew with meeting length exactly while captions needed to stay
/// cheap. The incremental fold must produce the same transcript the full
/// saved-audio pipeline produces, including when arrivals come out of order
/// or duplicate each other across tracks.
struct LiveSegmentMergerTests {
    private func segment(
        _ start: Double,
        _ text: String,
        source: TranscriptSegment.Source = .system,
        duration: Double = 1.5
    ) -> TranscriptSegment {
        TranscriptSegment(
            startTime: start,
            duration: duration,
            text: text,
            source: source
        )
    }

    /// Appending finals one batch at a time must land exactly where one full
    /// coalesce over everything would.
    @Test
    func incrementalAppendsMatchAFullCoalescePass() {
        var merger = LiveSegmentMerger()
        let batches: [[TranscriptSegment]] = [
            [segment(0, "So the pricing question came up twice today")],
            [
                segment(2, "and honestly the team seemed split on tiers"),
                segment(4, "Luke said he would draft something by Thursday.")
            ],
            [segment(30, "A later topic entirely about onboarding")]
        ]

        for batch in batches {
            merger.consume(batch[...])
        }

        #expect(merger.interleaved.count == 4)
        #expect(
            merger.coalesced == TranscriptAssembler.coalesce(merger.interleaved)
        )
        // The middle lines are close enough to merge into one caption.
        #expect(merger.coalesced.count == 2)
    }

    /// Tracks advance independently, so a final can arrive after newer text
    /// from the other track. The fallback rebuild must still converge on the
    /// authoritative result rather than leaving the insertion unmerged.
    @Test
    func anOutOfOrderArrivalMatchesTheFullPassAfterRebuilding() {
        var merger = LiveSegmentMerger()
        merger.consume([segment(10, "Second topic begins here now")][...])
        let landedAtEnd = merger.consume(
            [segment(9.5, "first topic trailing words")][...]
        )

        #expect(landedAtEnd)
        #expect(
            merger.coalesced == TranscriptAssembler.coalesce(merger.interleaved)
        )
        #expect(merger.interleaved.first?.startTime == 9.5)
    }

    /// One sentence heard on both tracks must not appear twice. System audio
    /// wins, matching what the saved-audio pass keeps.
    @Test
    func aSystemDuplicateReplacesTheMicrophoneLine() {
        var merger = LiveSegmentMerger()
        merger.consume(
            [
                segment(
                    5,
                    "we should move the release to friday",
                    source: .microphone
                )
            ][...]
        )
        let rebuilt = merger.consume(
            [
                segment(
                    5.4,
                    "we should move the release to friday",
                    source: .system
                )
            ][...]
        )

        #expect(rebuilt)
        #expect(merger.interleaved.count == 1)
        #expect(merger.interleaved.first?.source == .system)
    }

    /// Different sentences spoken seconds apart are content, not echo.
    @Test
    func distinctSpeechIsNeverDeduplicated() {
        var merger = LiveSegmentMerger()
        merger.consume(
            [segment(5, "the migration plan needs an owner", source: .microphone)][...]
        )
        merger.consume(
            [segment(7, "the design review moved to monday")][...]
        )

        #expect(merger.interleaved.count == 2)
    }

    @Test
    func theWordCountTracksMergesAndReplacements() {
        var merger = LiveSegmentMerger()
        merger.consume([segment(0, "one two three")][...])
        #expect(merger.totalWords == 3)

        // Merging into an open line adds only the new words.
        merger.consume([segment(1, "four five", duration: 0.5)][...])
        #expect(merger.totalWords == 5)

        // A system echo keeps the words once while preferring the system track.
        merger.consume(
            [
                segment(
                    30,
                    "six seven eight",
                    source: .microphone
                )
            ][...]
        )
        #expect(merger.totalWords == 8)
        let replaced = merger.consume(
            [segment(30.4, "SIX   seven eight", source: .system)][...]
        )
        #expect(replaced)
        #expect(merger.totalWords == 8)

        // A rebuild from an out-of-order arrival must land on the same total.
        let rebuilt = merger.consume(
            [segment(20, "inserted line here", source: .system)][...]
        )
        #expect(rebuilt)
        let expected = merger.coalesced.reduce(0) {
            $0 + LiveSegmentMerger.words(in: $1.text)
        }
        #expect(merger.totalWords == expected)

        merger.reset()
        #expect(merger.totalWords == 0)
    }

    /// The old comparator treated "within eighty milliseconds" as equality,
    /// which is not transitive and made sorted() behaviour undefined. Exact
    /// ties now break toward the microphone line first, preserving what the
    /// tie-break was for.
    @Test
    func equalStartTimesOrderTheMicrophoneLineFirst() {
        let microphone = segment(3, "yes", source: .microphone)
        let system = segment(3, "welcome everyone", source: .system)

        #expect(LiveSegmentMerger.ordersBefore(microphone, system))
        #expect(!LiveSegmentMerger.ordersBefore(system, microphone))
        #expect(!LiveSegmentMerger.ordersBefore(microphone, microphone))
    }

    @Test
    func sameSpeakerCorrectionsKeepBothUtterances() {
        for (first, second) in [
            ("we will ship Friday", "we will not ship Friday"),
            ("the cost is 500 pounds", "the cost is 600 pounds"),
            ("we will ask Sam to help Jo", "we will ask Jo to help Sam"),
        ] {
            let spoken = [segment(5, first), segment(6, second)]
            var merger = LiveSegmentMerger()
            merger.consume(spoken[...])
            #expect(merger.interleaved == spoken)
            #expect(LiveSegmentMerger.deduplicated(spoken) == spoken)
            #expect(merger.coalesced.map(\.text).joined(separator: " ") == first + " " + second)
        }
    }

    @Test
    func overlappingSpeakersKeepNegationNumbersAndWordOrder() {
        for (first, second) in [
            ("we will ship Friday", "we will not ship Friday"),
            ("the cost is 500 pounds", "the cost is 600 pounds"),
            ("the quote is $1.50 today", "the quote is €1.50 today"),
            ("the value is 1.5 today", "the value is 1,5 today"),
            ("we will ask Sam to help Jo", "we will ask Jo to help Sam"),
        ] {
            let spoken = [
                segment(5, first, source: .microphone),
                segment(5.4, second, source: .system),
            ]
            var merger = LiveSegmentMerger()
            merger.consume(spoken[...])
            #expect(merger.interleaved == spoken)
            #expect(LiveSegmentMerger.deduplicated(spoken) == spoken)
            #expect(merger.coalesced.map(\.text) == [first, second])
        }
    }

    @Test
    func repeatingTheSameWordsIsContentOnOneTrack() {
        let spoken = [
            segment(5, "we will ship Friday"),
            segment(6, "we will ship Friday"),
            segment(30, "we will ship Friday"),
        ]
        var merger = LiveSegmentMerger()
        merger.consume(spoken[...])
        #expect(merger.interleaved == spoken)
        #expect(LiveSegmentMerger.deduplicated(spoken) == spoken)
        #expect(merger.totalWords == 12)
    }

    @Test
    func shortSimultaneousAgreementsKeepBothSpeakers() {
        let spoken = [
            segment(5, "Yes", source: .microphone),
            segment(5.2, "Yes", source: .system),
        ]
        var merger = LiveSegmentMerger()
        merger.consume(spoken[...])
        #expect(merger.interleaved == spoken)
        #expect(LiveSegmentMerger.deduplicated(spoken) == spoken)
    }

    @Test
    func matchingWordsNeedSubstantialAudioOverlapToBeAnEcho() {
        for secondStart in [6.2, 7.0] {
            let spoken = [
                segment(5, "we will ship Friday", source: .microphone),
                segment(secondStart, "we will ship Friday", source: .system),
            ]
            var merger = LiveSegmentMerger()
            merger.consume(spoken[...])
            #expect(merger.interleaved == spoken)
            #expect(LiveSegmentMerger.deduplicated(spoken) == spoken)
        }
    }

    @Test
    func matchingWordsWithoutMeasuredDurationsKeepBothSpeakers() {
        let spoken = [
            segment(5, "we will ship Friday", source: .microphone, duration: 0),
            segment(5.4, "we will ship Friday", source: .system, duration: 0),
        ]
        var merger = LiveSegmentMerger()
        merger.consume(spoken[...])
        #expect(merger.interleaved == spoken)
        #expect(LiveSegmentMerger.deduplicated(spoken) == spoken)
    }

    @Test
    func genuineCrossSourceEchoAppearsOnceInBothLiveAndSavedTranscripts() {
        let microphone = segment(5, "we will ship Friday", source: .microphone)
        let system = segment(5.4, "WE   will ship Friday", source: .system)
        for incoming in [[microphone, system], [system, microphone]] {
            var merger = LiveSegmentMerger()
            for value in incoming { merger.consume([value][...]) }
            #expect(merger.interleaved == [system])
            #expect(merger.coalesced.map(\.text) == ["WE will ship Friday"])
            #expect(merger.totalWords == 4)
        }
        #expect(LiveSegmentMerger.deduplicated([microphone, system]) == [system])
    }

    @Test
    func replacingAnEchoKeepsOtherSpeechInChronologicalOrder() {
        let microphone = segment(5, "we will ship Friday", source: .microphone)
        let other = segment(5.2, "a separate point about testing", source: .system)
        let system = segment(5.4, "we will ship Friday", source: .system)
        let spoken = [microphone, other, system]
        var merger = LiveSegmentMerger()
        merger.consume(spoken[...])
        #expect(merger.interleaved == [other, system])
        #expect(LiveSegmentMerger.deduplicated(spoken) == [other, system])
        #expect(merger.coalesced == TranscriptAssembler.coalesce([other, system]))
    }

    @Test
    func oneEchoCannotEraseTwoGenuineRepetitions() {
        let first = segment(5, "we will ship Friday", source: .microphone, duration: 1)
        let system = segment(5.5, "we will ship Friday", source: .system, duration: 1)
        let second = segment(6, "we will ship Friday", source: .microphone, duration: 1)
        let spoken = [first, system, second]
        for incoming in [spoken, [system, first, second], [first, second, system]] {
            var merger = LiveSegmentMerger()
            merger.consume(incoming[...])
            #expect(merger.interleaved.count == 2)
            #expect(merger.interleaved.contains(system))
            #expect(merger.totalWords == 8)
        }
        #expect(LiveSegmentMerger.deduplicated(spoken) == [system, second])
    }

    @Test
    func repeatedFinalEmissionsAreRecognizedByTheirAudioSpan() {
        var snapshot = TrackSnapshot(source: .microphone)
        let first = CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 2))
        let next = CMTimeRange(
            start: CMTime(value: 1, timescale: 1),
            duration: CMTime(value: 1, timescale: 2)
        )
        snapshot.appendFinalized("No", range: first)
        snapshot.appendFinalized("No", range: next)
        snapshot.appendFinalized("No", range: first)
        #expect(snapshot.segments.map(\.text) == ["No", "No"])
        #expect(snapshot.segments.map(\.startTime) == [0, 1])
        #expect(snapshot.segments.allSatisfy { $0.source == .microphone })
    }

    @Test
    func equivalentTimeScalesStillIdentifyTheSameFinalSpan() {
        var snapshot = TrackSnapshot(source: .system)
        snapshot.appendFinalized("we will ship Friday", range: CMTimeRange(
            start: CMTime(value: 1, timescale: 1),
            duration: CMTime(value: 1, timescale: 2)
        ))
        snapshot.appendFinalized("we will ship Friday", range: CMTimeRange(
            start: CMTime(value: 1000, timescale: 1000),
            duration: CMTime(value: 500, timescale: 1000)
        ))
        #expect(snapshot.segments.map(\.text) == ["we will ship Friday"])
    }
}
