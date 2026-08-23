import Foundation
import Testing
@testable import Nook

/// A ninety minute meeting used to become the words "Nook couldn't generate a
/// structured summary". Chunks were condensed once and then joined into a
/// single final pass, which overflowed the on-device context window every
/// time. The reduce below is the arithmetic that fixes it, tested against a
/// stand-in responder so the shape can be verified without Apple Intelligence
/// being installed, enabled, or willing.
struct TranscriptReduceTests {
    /// A responder that shrinks whatever it is handed, the way a real
    /// condensing pass does.
    private func shrinking(by factor: Int) -> @Sendable (
        String, Int, Int, Int
    ) async throws -> String {
        { part, _, _, _ in String(part.prefix(max(1, part.count / factor))) }
    }

    private func transcript(characters: Int) -> String {
        let line = "[00:01] System: We reviewed the migration plan today.\n"
        var text = ""
        while text.count < characters { text += line }
        return text
    }

    @Test
    func condensingRepeatsUntilTheMaterialFitsTheWindow() async throws {
        let plan = TranscriptReducePlan(
            chunkBudget: 4_000,
            finalBudget: 5_000,
            maximumRounds: 4
        )
        let source = transcript(characters: 90_000)

        let reduced = try await TranscriptReducer.reduce(
            source,
            plan: plan,
            condense: shrinking(by: 4)
        )

        #expect(plan.fits(reduced))
        #expect(reduced.count < source.count)
    }

    /// One pass over ninety thousand characters is exactly the case that used
    /// to overflow: the condensed text is smaller, and still far too big.
    @Test
    func oneRoundIsNotEnoughForALongMeeting() async throws {
        let plan = TranscriptReducePlan.standard
        let source = transcript(characters: 90_000)
        let rounds = Rounds()

        _ = try await TranscriptReducer.reduce(
            source,
            plan: plan,
            condense: { part, _, _, round in
                await rounds.record(round)
                return String(part.prefix(max(1, part.count / 4)))
            }
        )

        #expect(await rounds.highest > 1)
    }

    @Test
    func materialThatNeverShrinksStopsInsteadOfLooping() async {
        let plan = TranscriptReducePlan.standard

        do {
            _ = try await TranscriptReducer.reduce(
                transcript(characters: 40_000),
                plan: plan,
                condense: { part, _, _, _ in part }
            )
            Issue.record("Expected the reduce to give up")
        } catch TranscriptReduceError.didNotFit {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    /// A transcript arriving as one enormous line has no newline to split on.
    /// Returning it whole made every round produce the same oversized part.
    @Test
    func oneEnormousLineIsStillSplit() {
        let line = String(repeating: "a", count: 10_000)

        let parts = TranscriptReducePlan.parts(of: line, maximumCharacters: 1_000)

        #expect(parts.count >= 10)
        #expect(parts.allSatisfy { $0.count <= 1_000 })
        #expect(parts.joined().replacingOccurrences(of: "\n", with: "") == line)
    }

    @Test
    func everyPartIsReportedSoProgressCanBeShown() async throws {
        let plan = TranscriptReducePlan(
            chunkBudget: 2_000,
            finalBudget: 3_000,
            maximumRounds: 3
        )
        let reports = Reports()

        _ = try await TranscriptReducer.reduce(
            transcript(characters: 20_000),
            plan: plan,
            onProgress: { part, total in await reports.record(part, total) },
            condense: shrinking(by: 5)
        )

        let seen = await reports.all
        #expect(seen.count >= 10)
        #expect(seen.first?.part == 1)
        #expect(seen.allSatisfy { $0.part <= $0.total })
    }

    @Test
    func cancellingStopsTheReduceBetweenParts() async {
        let task = Task {
            try await TranscriptReducer.reduce(
                transcript(characters: 40_000),
                plan: TranscriptReducePlan.standard,
                condense: shrinking(by: 2)
            )
        }
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected the cancelled reduce to stop")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    /// Text that already fits is handed to the final pass untouched, because a
    /// second model pass on an ordinary meeting only adds a way to fail.
    @Test
    func anOrdinaryMeetingIsNotCondensedAtAll() async throws {
        let source = transcript(characters: 2_000)
        let calls = Rounds()

        let reduced = try await TranscriptReducer.reduce(
            source,
            plan: TranscriptReducePlan.standard,
            condense: { part, _, _, round in
                await calls.record(round)
                return part
            }
        )

        #expect(reduced == source)
        #expect(await calls.highest == 0)
    }

    @Test
    func aTightenedPlanAsksForLessRoom() {
        let tightened = TranscriptReducePlan.standard.tightened

        #expect(tightened.chunkBudget < TranscriptReducePlan.standard.chunkBudget)
        #expect(tightened.finalBudget < TranscriptReducePlan.standard.finalBudget)
    }
}

private actor Rounds {
    private(set) var highest = 0

    func record(_ round: Int) { highest = max(highest, round) }
}

private actor Reports {
    private(set) var all: [(part: Int, total: Int)] = []

    func record(_ part: Int, _ total: Int) {
        all.append((part: part, total: total))
    }
}

/// "Nook couldn't summarize this" was the same sentence whether Apple
/// Intelligence was switched off, still downloading, or had refused, and only
/// some of those are worth acting on.
struct SummaryFailureReasonTests {
    @Test
    func everyFailureExplainsItselfDifferently() {
        let sentences = SummaryService.FailureReason.allCases.map(\.userSentence)

        #expect(Set(sentences).count == sentences.count)
        #expect(sentences.allSatisfy { $0.count > 20 })
        #expect(sentences.allSatisfy { !$0.contains("\u{2014}") })
    }

    @Test
    func everyFailureIsJournaledUnderItsOwnName() {
        let events = SummaryService.FailureReason.allCases.map(\.logEvent.rawValue)

        #expect(Set(events).count == events.count)
    }

    @Test
    func aTranscriptThatWillNotFitIsNamedAsSuch() {
        struct Unexpected: Error {}

        #expect(
            SummaryService.failureReason(for: TranscriptReduceError.didNotFit)
                == .transcriptTooLong
        )
        #expect(
            SummaryService.failureReason(for: Unexpected()) == .generationFailed
        )
    }

    @Test
    func theFallbackSummaryNamesTheReasonItIsShowing() {
        let transcript = [
            TranscriptSegment(
                startTime: 0,
                duration: 5,
                text: "We agreed to move the migration to the following week."
            )
        ]

        let explained = SummaryService.fallbackInsights(
            transcript: transcript,
            fallbackTitle: "Manual meeting",
            reason: .appleIntelligenceOff
        )
        let unexplained = SummaryService.fallbackInsights(
            transcript: transcript,
            fallbackTitle: "Manual meeting"
        )

        #expect(explained.summary.contains("System Settings"))
        #expect(explained.summary.contains("Transcript highlights:"))
        #expect(!unexplained.summary.contains("System Settings"))
        #expect(unexplained.summary.contains("Transcript highlights:"))
    }
}

/// A live refresh used to send the whole meeting to the model every time, so
/// each pass cost more than the last one while telling the user less.
struct LiveSummaryTailTests {
    private func segments(_ count: Int) -> [TranscriptSegment] {
        (0..<count).map { index in
            TranscriptSegment(
                startTime: Double(index) * 10,
                duration: 8,
                text: "Line \(index) of the conversation about the migration plan."
            )
        }
    }

    @Test
    func onlyTheRecentStretchOfALongMeetingIsSent() {
        let tail = SummaryService.liveTail(
            of: segments(600),
            maximumCharacters: 1_000
        )

        #expect(tail.count < 600)
        #expect(tail.reduce(0) { $0 + $1.text.count } <= 1_100)
        #expect(tail.last?.text == "Line 599 of the conversation about the migration plan.")
    }

    @Test
    func aShortMeetingIsSentWhole() {
        let all = segments(5)

        #expect(SummaryService.liveTail(of: all).map(\.text) == all.map(\.text))
    }

    /// A single segment longer than the budget is still the only thing there
    /// is to summarize, so it goes rather than nothing going.
    @Test
    func oneOverlongSegmentIsStillSent() {
        let long = [
            TranscriptSegment(
                startTime: 0,
                duration: 30,
                text: String(repeating: "words ", count: 500)
            )
        ]

        #expect(SummaryService.liveTail(of: long, maximumCharacters: 100).count == 1)
    }
}
