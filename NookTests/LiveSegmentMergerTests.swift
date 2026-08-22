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

        // A system duplicate replaces a microphone line when the texts are
        // close enough to be the same sentence heard twice.
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
            [segment(30.4, "six seven eight nine", source: .system)][...]
        )
        #expect(replaced)
        #expect(merger.totalWords == 9)

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
}