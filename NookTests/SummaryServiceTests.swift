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

    // MARK: Plans sized to the meeting

    /// A short meeting keeps the fixed plan's margin.
    @Test
    func smallMeetingsKeepTheStandardRoundCount() {
        let plan = TranscriptReducePlan.standard(
            forCharacters: 8_000,
            condensedPartCeiling: SummaryService.condensedPartCharacterEstimate
        )
        #expect(plan.maximumRounds == TranscriptReducePlan.standard.maximumRounds)
    }

    /// The copied-note case: a seventy minute meeting's prompt ran to about
    /// seventy-eight thousand characters. Under a chunk budget that cannot
    /// hold two ceiling-length answers side by side, every round maps twenty
    /// blocks to twenty blocks and nothing shrinks; with answers able to
    /// pack, the material converges inside the planned rounds.
    @Test
    func aSeventyMinuteMeetingConvergesWithinThePlannedRounds() async throws {
        let source = transcript(characters: 77_556)

        let plan = TranscriptReducePlan.standard(
            forCharacters: source.count,
            condensedPartCeiling: SummaryService.condensedPartCharacterEstimate
        )
        let reduced = try await TranscriptReducer.reduce(
            source,
            plan: plan,
            condense: ceilingBoundCondense
        )
        #expect(plan.fits(reduced))
    }

    /// Three hours of speech: the fixed four-round plan runs out even once
    /// answers pack, and the sized plan is what carries it home.
    @Test
    func anEnormousMeetingNeedsTheSizedPlan() async throws {
        let source = transcript(characters: 200_000)

        do {
            _ = try await TranscriptReducer.reduce(
                source,
                plan: .standard,
                condense: ceilingBoundCondense
            )
            Issue.record("the fixed four-round plan unexpectedly converged")
        } catch {
            #expect(error is TranscriptReduceError)
        }

        let plan = TranscriptReducePlan.standard(
            forCharacters: source.count,
            condensedPartCeiling: SummaryService.condensedPartCharacterEstimate
        )
        #expect(plan.maximumRounds > TranscriptReducePlan.standard.maximumRounds)
        let reduced = try await TranscriptReducer.reduce(
            source,
            plan: plan,
            condense: ceilingBoundCondense
        )
        #expect(plan.fits(reduced))
    }
}

/// A condensing pass that always comes back at the response ceiling the
/// plan factory budgets against, the worst case a real model can produce.
private func ceilingBoundCondense(
    _ part: String, _ index: Int, _ total: Int, _ round: Int
) async throws -> String {
    String(
        repeating: "condensed material sentence. ",
        count: max(
            1,
            min(SummaryService.condensedPartCharacterEstimate, part.count) / 29
        )
    )
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


/// A two hour meeting was written up as two thin sentences with no key
/// points: the summary ceiling never moved with meeting length, and the
/// final pass had no idea how much conversation its condensed source stood
/// in for. These pin the calibration pieces.
struct SummaryQualityTests {

    private func transcript(charactersPerSegment: Int, segments: Int) -> [TranscriptSegment] {
        (0..<segments).map { index in
            TranscriptSegment(
                startTime: Double(index) * 30,
                duration: 25,
                text: String(repeating: "w", count: charactersPerSegment),
                source: .mixed
            )
        }
    }

    @Test
    func longMeetingsMayWriteLongerSummaries() {
        let longTranscript = transcript(
            charactersPerSegment: 120,
            segments: 300
        )
        let summary = String(repeating: "sentence one. ", count: 140)
        let proposed = MeetingInsights(
            title: "Planning",
            summary: summary,
            keyPoints: [],
            decisions: [],
            actionItems: []
        )

        // 2,100 characters: over the short-meeting ceiling, under the
        // long-meeting one, and far below the echo ratio.
        #expect(summary.count > 1_600)
        #expect(summary.count <= 2_400)
        #expect(MeetingInsightValidator.validate(proposed, against: longTranscript) != nil)

        let shortTranscript = transcript(
            charactersPerSegment: 60,
            segments: 5
        )
        #expect(MeetingInsightValidator.validate(proposed, against: shortTranscript) == nil)
    }

    @Test
    func coverageDescribesTheConversationAtHumanScale() {
        // Segments land every thirty seconds; 265 of them span two hours
        // and change, which is what the note should say rather than a
        // number nobody said out loud.
        let coverage = SummaryService.TranscriptCoverage.forTranscript(
            transcript(charactersPerSegment: 10, segments: 265)
        )
        #expect(coverage.durationSentence == "about 2 hours 12 minutes")
        #expect(coverage.spokenWords == 265)
    }

    @Test
    func anHourReadsAsAnHourNotSixtyMinutes() {
        let coverage = SummaryService.TranscriptCoverage.forTranscript(
            transcript(charactersPerSegment: 10, segments: 121)
        )
        #expect(coverage.durationSentence == "about 1 hour")
    }
}

/// The candidate ledger is the guarantee that specifics harvested from the
/// raw transcript reach the structured pass untouched by narrative rounds:
/// first occurrence wins, near-duplicates collapse, and the block it renders
/// stays inside the window budget.
struct CandidateLedgerTests {

    @Test
    func harvestKeepsConcreteItemsUnderTheirHeadings() async {
        let ledger = CandidateLedger()
        await ledger.add(
            facts: ["Modelled at 1.9%"],
            decisions: ["Ship in October"],
            actions: ["Ana drafts the rollout plan"]
        )
        let rendered = await ledger.rendered()

        #expect(rendered.contains("KEY FACTS\n- Modelled at 1.9%"))
        #expect(rendered.contains("DECISIONS\n- Ship in October"))
        #expect(rendered.contains("ACTIONS\n- Ana drafts the rollout plan"))
    }

    @Test
    func restatementsCollapseIntoTheFirstWording() async {
        let ledger = CandidateLedger()
        await ledger.add(
            facts: ["Modelled at 1.9%!"],
            decisions: [],
            actions: []
        )
        await ledger.add(
            facts: ["modelled at 1.9%"],
            decisions: [],
            actions: []
        )

        let facts = await ledger.keyPoints
        #expect(facts == ["Modelled at 1.9%!"])
    }

    @Test
    func emptyAndBlankCandidatesAreDropped() async {
        let ledger = CandidateLedger()
        await ledger.add(facts: ["  ", "", "Real fact"], decisions: [], actions: [])

        let facts = await ledger.keyPoints
        #expect(facts == ["Real fact"])
    }

    @Test
    func aFullListStopsGrowingAtTheWindowBound() async {
        let ledger = CandidateLedger()
        for index in 0..<40 {
            await ledger.add(
                facts: ["Fact number \(index) about pricing"],
                decisions: [],
                actions: []
            )
        }

        let facts = await ledger.keyPoints
        #expect(facts.count == CandidateLedger.maximumItemsPerList)
        #expect(facts.first == "Fact number 0 about pricing")
    }

    @Test
    func anEmptyLedgerRendersNothing() async {
        let ledger = CandidateLedger()
        let rendered = await ledger.rendered()
        #expect(rendered.isEmpty)
        let empty = await ledger.isEmpty
        #expect(empty)
    }
}
