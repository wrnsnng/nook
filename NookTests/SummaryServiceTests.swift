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

    /// The condense callback and progress callback use the same one-based
    /// numbering. The stage reporter consumes the former directly, so making
    /// it zero-based or incrementing it again produces "part 2" first and a
    /// final part larger than the total.
    @Test
    func condenseReceivesOneBasedPartNumbers() async throws {
        let plan = TranscriptReducePlan(
            chunkBudget: 2_000,
            finalBudget: 3_000,
            maximumRounds: 3
        )
        let reports = Reports()

        _ = try await TranscriptReducer.reduce(
            transcript(characters: 12_000),
            plan: plan,
            condense: { part, index, total, _ in
                await reports.record(index, total)
                return String(part.prefix(max(1, part.count / 5)))
            }
        )

        let seen = await reports.all
        #expect(seen.first?.part == 1)
        #expect(seen.allSatisfy { $0.part >= 1 && $0.part <= $0.total })
        #expect(seen.contains(where: { $0.part == $0.total }))
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

/// Attention is deliberately a small projection of the note, not another
/// transcript-sized input. These tests keep the prompt contract deterministic
/// without requiring Apple Intelligence to be enabled on the test machine.
struct SummaryAttentionTests {
    @Test
    func notesAndFlaggedContextsStayBounded() {
        let transcript = (0..<12).map { index in
            TranscriptSegment(
                startTime: Double(index) * 20,
                duration: 8,
                text: "Transcript segment \(index) with enough context to inspect."
            )
        }
        let moments = (0..<12).map { index in
            MeetingMoment(offset: Double(index) * 20)
        }
        let attention = SummaryAttention(
            myNotes: String(repeating: "My note. ", count: 400),
            moments: moments,
            transcript: transcript
        )

        #expect(
            attention.myNotes.count <= SummaryAttention.maximumMyNotesCharacters
        )
        #expect(
            attention.flaggedMoments.count
                <= SummaryAttention.maximumFlaggedMoments
        )
        #expect(
            attention.flaggedMoments.allSatisfy {
                $0.segments.count <= SummaryAttention.maximumSegmentsPerMoment
            }
        )
        #expect(
            attention.rendered.count <= SummaryAttention.maximumRenderedCharacters
        )
    }

    @Test
    func flaggedMomentUsesOnlyNearbyTranscriptSegments() {
        let transcript = [
            TranscriptSegment(
                startTime: 0,
                duration: 5,
                text: "Far before the flagged moment."
            ),
            TranscriptSegment(
                startTime: 50,
                duration: 5,
                text: "Nearest transcript context."
            ),
            TranscriptSegment(
                startTime: 100,
                duration: 5,
                text: "Far after the flagged moment."
            )
        ]
        let attention = SummaryAttention(
            moments: [MeetingMoment(offset: 52)],
            transcript: transcript
        )

        #expect(attention.flaggedMoments.count == 1)
        #expect(
            attention.flaggedMoments.first?.segments.map(\.text)
                == ["Nearest transcript context."]
        )
    }

    @Test
    func renderedAttentionAppearsAsGuidanceAndRealFlaggedContext() {
        let attention = SummaryAttention(
            myNotes: "Emphasize the budget decision.",
            moments: [MeetingMoment(offset: 52)],
            transcript: [
                TranscriptSegment(
                    startTime: 50,
                    duration: 5,
                    text: "The team approved the revised budget."
                )
            ]
        )
        let prompt = SummaryService.insightsPrompt(
            source: "[00:50] The team approved the revised budget.",
            coverage: SummaryService.TranscriptCoverage(
                spokenWords: 8,
                durationSentence: "about 1 minute"
            ),
            candidates: "",
            previous: nil,
            fallbackTitle: "Planning",
            attention: attention
        )

        #expect(prompt.contains("USER GUIDANCE ONLY, FROM MY NOTES"))
        #expect(prompt.contains("BEGIN MY NOTES"))
        #expect(prompt.contains("Emphasize the budget decision."))
        #expect(prompt.contains("FLAGGED TRANSCRIPT CONTEXT"))
        #expect(prompt.contains("The team approved the revised budget."))
        #expect(!prompt.contains("(attention.rendered)"))
    }

    @Test
    func emptyAttentionPreservesTheExistingPrompt() {
        let arguments = (
            source: "[00:01] We reviewed the plan.",
            coverage: SummaryService.TranscriptCoverage(
                spokenWords: 5,
                durationSentence: "about 1 minute"
            ),
            candidates: "",
            previous: Optional<MeetingInsights>.none,
            fallbackTitle: "Planning"
        )
        let withoutAttention = SummaryService.insightsPrompt(
            source: arguments.source,
            coverage: arguments.coverage,
            candidates: arguments.candidates,
            previous: arguments.previous,
            fallbackTitle: arguments.fallbackTitle
        )
        let withEmptyAttention = SummaryService.insightsPrompt(
            source: arguments.source,
            coverage: arguments.coverage,
            candidates: arguments.candidates,
            previous: arguments.previous,
            fallbackTitle: arguments.fallbackTitle,
            attention: .empty
        )

        #expect(withEmptyAttention == withoutAttention)
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
    func decimalPercentagesDoNotCollapseIntoWholePercentages() async {
        let ledger = CandidateLedger()
        await ledger.add(
            facts: ["Modelled at 1.9%", "Modelled at 19%"],
            decisions: [],
            actions: []
        )

        let facts = await ledger.keyPoints
        #expect(facts == ["Modelled at 1.9%", "Modelled at 19%"])
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
                facts: ["Fact \(index)"],
                decisions: [],
                actions: []
            )
        }

        let facts = await ledger.keyPoints
        #expect(facts.count == CandidateLedger.maximumItemsPerList)
        #expect(facts.first == "Fact 0")
    }

    @Test
    func renderedLedgerStaysInsideItsSharedPromptBudget() async {
        let ledger = CandidateLedger()
        let longTail = String(repeating: " detailed evidence", count: 20)
        for index in 0..<40 {
            await ledger.add(
                facts: ["Fact \(index)\(longTail)"],
                decisions: ["Decision \(index)\(longTail)"],
                actions: ["Action \(index)\(longTail)"]
            )
        }

        let rendered = await ledger.rendered()
        #expect(rendered.count <= CandidateLedger.maximumRenderedCharacters)
        #expect(rendered.contains("KEY FACTS"))
        #expect(rendered.contains("DECISIONS"))
        #expect(rendered.contains("ACTIONS"))
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

/// FoundationModels screens its input: raw profanity made it refuse a whole
/// transcript outright. Masking is deliberately dumb, fixed-list and word-
/// bounded, so it can never invent or remove anything else.
struct TranscriptProfanityMaskTests {

    @Test
    func coarseWordsAreMaskedCaseInsensitively() {
        #expect(SummaryService.masked("we were going cap in hand") == "we were going cap in hand")
        #expect(
            SummaryService.masked("that's Fucking beautiful")
                == "that's F****** beautiful"
        )
        #expect(SummaryService.masked("SHIT experience") == "S*** experience")
    }

    @Test
    func wordsThatMerelyContainCoarseLettersStayUntouched() {
        #expect(SummaryService.masked("let's assess the class") == "let's assess the class")
        #expect(SummaryService.masked("analysis of Casserly") == "analysis of Casserly")
    }

    @Test
    func numbersAndNamesPassThroughByteForByte() {
        let line = "modelled at 1.9%, Mcoin, Luke Trickett, $1,000,000 TIV"
        #expect(SummaryService.masked(line) == line)
    }

    @Test
    func peopleNamedDickAndTheSportingGoodsBrandStayExact() {
        let line = "Dick Costolo met the team at Dick's Sporting Goods."
        #expect(SummaryService.masked(line) == line)
        #expect(SummaryService.masked("those dicks") == "those d****")
    }

    @Test
    func promptTextMasksEverySegment() {
        let segments = [
            TranscriptSegment(startTime: 0, duration: 2, text: "fuck off", source: .system),
            TranscriptSegment(startTime: 3, duration: 2, text: "clean line", source: .mixed),
        ]
        let prompt = SummaryService.promptText(for: segments)
        #expect(prompt.contains("f*** off"))
        #expect(prompt.contains("clean line"))
        #expect(!prompt.contains("fuck off"))
    }
}

/// Input screening rejects a prompt before any generation happens and
/// arrives as a bare error, not a GenerationError. An 85k character meeting
/// died this way one second in, journalled as a generic generation failure.
struct SensitiveContentRejectionTests {

    /// Stands in for the framework's screening error, which carries its
    /// message as a localized description with no typed case to match.
    private struct ScreenedInput: LocalizedError {
        var errorDescription: String? { "May contain sensitive content" }
    }

    @Test
    func aScreeningRejectionIsNamedAsSuchNotAsAGenericFailure() {
        #expect(
            SummaryService.failureReason(for: ScreenedInput())
                == .sensitiveContent
        )
        struct Unrelated: Error {}
        #expect(
            SummaryService.failureReason(for: Unrelated())
                == .generationFailed
        )
        #expect(
            SummaryService.failureReason(for: TranscriptReduceError.didNotFit)
                == .transcriptTooLong
        )
    }

    @Test
    func detectionSurvivesNSErrorBridging() {
        let bridged = NSError(
            domain: "LanguageModel",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: "May contain sensitive content"
            ]
        )
        #expect(SummaryService.isSensitiveContentRejection(bridged))
        #expect(!SummaryService.isSensitiveContentRejection(
            TranscriptReduceError.didNotFit
        ))
    }

    /// A refusal of the write-up must not cost the harvest: the ledger holds
    /// items taken from the raw transcript, and they reach the note through
    /// the same validation and grounding every model result passes.
    @Test
    func salvageBuildsAGroundedNoteFromTheHarvest() throws {
        let transcript = [
            TranscriptSegment(
                startTime: 0,
                duration: 30,
                text: "So we agreed the pricing model lands at 1.9% from October."
            ),
            TranscriptSegment(
                startTime: 30,
                duration: 30,
                text: "I will draft the rollout plan before the board review."
            ),
            TranscriptSegment(
                startTime: 60,
                duration: 30,
                text: "The team confirmed the migration window stays in October."
            ),
        ]

        let salvaged = SummaryService.salvagedInsights(
            facts: ["Pricing modelled at 1.9%"],
            decisions: ["Ship in October"],
            actions: ["Ana drafts the rollout plan"],
            transcript: transcript,
            fallbackTitle: "Manual meeting"
        )

        let note = try #require(salvaged)
        #expect(note.keyPoints == ["Pricing modelled at 1.9%"])
        #expect(note.decisions == ["Ship in October"])
        #expect(note.actionItems == ["Ana drafts the rollout plan"])
        #expect(note.summary.contains("taken directly from the transcript"))
        #expect(note.title != "Manual meeting")
    }

    /// Grounding is what makes the salvage honest: an entry nothing in the
    /// conversation supports does not survive, so a refusal cannot be turned
    /// into a licence to invent.
    @Test
    func salvageDropsEntriesNothingSaid() throws {
        let transcript = [
            TranscriptSegment(
                startTime: 0,
                duration: 30,
                text: "We reviewed the migration plan for the October release."
            )
        ]

        let salvaged = SummaryService.salvagedInsights(
            facts: ["Budget approved at four million dollars"],
            decisions: [],
            actions: [],
            transcript: transcript,
            fallbackTitle: "Manual meeting"
        )

        let note = try #require(salvaged)
        #expect(note.keyPoints.isEmpty)
    }

    @Test
    func salvageOfNothingYieldsNothing() {
        let salvaged = SummaryService.salvagedInsights(
            facts: [],
            decisions: [],
            actions: [],
            transcript: [],
            fallbackTitle: "Manual meeting"
        )
        #expect(salvaged == nil)
    }

    /// Guided generation renamed its parse failure in newer runtimes, and
    /// the new type cannot be named by a build targeting the stable SDK.
    /// The description is what both spellings share.
    private struct RenamedParseFailure: LocalizedError {
        var errorDescription: String? {
            "Failed to parse generated content."
        }
    }

    /// The renamed refusal, matched the same way.
    private struct RenamedRefusal: LocalizedError {
        var errorDescription: String? { "The model refused to answer." }
    }

    @Test
    func aParsingErrorIsAnUnreadableAnswer() {
        #expect(
            SummaryService.isUnparsableAnswer(RenamedParseFailure())
        )
        struct Unrelated: Error {}
        #expect(!SummaryService.isUnparsableAnswer(Unrelated()))
        #expect(
            SummaryService.failureReason(for: RenamedParseFailure())
                == .malformedAnswer
        )
    }

    /// The same refusal has two runtime shapes across the OS rename. A
    /// meeting died because only the old one was tolerated, so the
    /// classifier must speak both.
    @Test
    func refusalsAreRecognisedUnderBothNames() {
        #expect(SummaryService.classify(RenamedRefusal()) == .refused)
        #expect(
            SummaryService.failureReason(for: RenamedRefusal()) == .declined
        )
    }

    /// macOS 27 bridges the renamed enum through this domain and case-order
    /// code when the concrete Swift error has already been erased. Every case
    /// that changes a recovery path must survive that bridge.
    @Test
    func modernGenerationFailuresKeepTheirRecoveryPathsAfterBridging() {
        let cases: [(Int, SummaryService.GenerationFailure)] = [
            (0, .overflow),
            (1, .busy),
            (2, .refused),
            (3, .refused),
            (4, .schemaUnsupported),
            (5, .refused),
            (6, .schemaUnsupported),
            (7, .languageUnsupported),
            (8, .timedOut),
        ]

        for (code, expected) in cases {
            let error = NSError(
                domain: "FoundationModels.LanguageModelError",
                code: code,
                userInfo: [NSLocalizedDescriptionKey: "Opaque framework error"]
            )
            #expect(SummaryService.classify(error) == expected)
        }
    }
}

/// When the OS cannot deliver guided generation at all, the final pass falls
/// back to a labelled prose answer parsed here. The parser is deterministic:
/// it reads only lines it recognises and invents nothing.
struct ProseInsightParserTests {

    @Test
    func aWellFormedAnswerParsesIntoEveryField() throws {
        let text = """
            TITLE: Migration rollout planning
            SUMMARY: The team settled the October window and priced the work.
            at 1.9% with board sign-off pending.
            KEY POINTS:
            - Modelled at 1.9%
            - Migration stays in October
            DECISIONS:
            - Ship in October
            ACTIONS:
            - Ana drafts the rollout plan
            """

        let parsed = try #require(SummaryService.parsedProseInsights(text))

        #expect(parsed.title == "Migration rollout planning")
        #expect(
            parsed.summary == "The team settled the October window and "
                + "priced the work. at 1.9% with board sign-off pending."
        )
        #expect(parsed.keyPoints == ["Modelled at 1.9%", "Migration stays in October"])
        #expect(parsed.decisions == ["Ship in October"])
        #expect(parsed.actionItems == ["Ana drafts the rollout plan"])
    }

    @Test
    func emptySectionsAreDroppedAndBulletsOutsideSectionsIgnored() throws {
        let text = """
            TITLE: Standup
            SUMMARY: Short sync.
            - stray bullet nobody asked about
            """

        let parsed = try #require(SummaryService.parsedProseInsights(text))

        #expect(parsed.summary == "Short sync.")
        #expect(parsed.keyPoints.isEmpty)
        #expect(parsed.decisions.isEmpty)
        #expect(parsed.actionItems.isEmpty)
    }

    @Test
    func anAnswerWithoutASummaryIsRefused() {
        #expect(SummaryService.parsedProseInsights("TITLE: only a title") == nil)
        #expect(SummaryService.parsedProseInsights("") == nil)
    }
}

/// Exercises the production write-up, salvage and final-validation boundaries
/// together. The only responder is a synthetic throwing closure; no model,
/// availability check, journal, recording or user file is touched.
struct SummaryFailureProvenanceTests {
    @Test(arguments: SyntheticWriteUpFailure.allCases)
    func salvagedEntriesKeepTheActualFailureThroughFinalValidation(failure: SyntheticWriteUpFailure) async throws {
        let result = try await SummaryProvenanceFixture.result(after: failure)

        #expect(result.failure == failure.reason)
        #expect(result.usedFallback)
        #expect(result.insights.keyPoints == SummaryProvenanceFixture.facts)
        #expect(result.insights.decisions == SummaryProvenanceFixture.decisions)
        #expect(result.insights.actionItems == SummaryProvenanceFixture.actions)
        #expect(result.insights.summary.contains("taken directly from the transcript"))
        #expect(!result.insights.summary.contains("would not write"))
        #expect(!result.insights.summary.contains("declined"))
        // Callers that consume `.insights`, including ordinary first-time
        // summarization and recovery, still receive the grounded harvest.
        let firstSummary = result.insights
        #expect(!firstSummary.summary.isEmpty)
        #expect(!firstSummary.keyPoints.isEmpty)
    }

    @MainActor
    @Test(arguments: SyntheticWriteUpFailure.allCases)
    func regenerationDoesNotCommitAnyFieldWhenOnlyASalvagedWriteUpReturns(failure: SyntheticWriteUpFailure) async throws {
        let folder = URL(fileURLWithPath: "/synthetic-summary-provenance/Notes", isDirectory: true)
        let original = SummaryProvenanceFixture.existingNote(in: folder)
        let originalBytes = Data(MarkdownCodec.encode(original).utf8)
        var current = original
        var commits = 0
        let summarizer = SyntheticFailingWriteUpSummarizer(failure: failure)
        let session = SummaryRegenerationSession { note, onStage in
            await SummaryRegenerator.regenerate(note, using: summarizer, onStage: onStage)
        }
        let started = session.start(
            note: original,
            library: { .init(directoryURL: folder, generation: 0, notes: [current]) },
            commit: { replacement in
                commits += 1
                current = replacement
                return replacement
            }
        )
        let task = try #require(started)

        await task.value

        #expect(commits == 0)
        #expect(current == original)
        #expect(Data(MarkdownCodec.encode(current).utf8) == originalBytes)
        #expect(current.personalNotes.utf8.elementsEqual(original.personalNotes.utf8))
        #expect(current.summary.utf8.elementsEqual(original.summary.utf8))
        #expect(!session.isRunning)
        let completion = try #require(session.completion)
        guard case .retained(let reason) = completion.result else {
            Issue.record("A salvaged write-up must retain the existing note")
            return
        }
        #expect(reason == failure.reason)
    }

    @MainActor
    @Test
    func aFirstCaptureRetainsItsUsefulScaffoldWhenEnrichmentOnlySalvages() async throws {
        let draft = MeetingDraft(
            id: UUID(), title: "Synthetic migration review", sourceApp: "Synthetic",
            startedAt: Date(timeIntervalSince1970: 1_780_000_000),
            recordingURL: URL(fileURLWithPath: "/synthetic-summary-provenance/recording.m4a")
        )
        let transcript = SummaryProvenanceFixture.transcript
        let scaffold = MeetingCoordinator.transcriptFirstScaffold(
            for: draft, transcript: transcript,
            personalNotes: "  Cafe\u{301} preparation.\n", moments: [MeetingMoment(offset: 10)],
            endedAt: draft.startedAt.addingTimeInterval(90)
        )
        var current = scaffold
        current.personalNotes += "The user added a detail while waiting.\n"
        let before = Data(MarkdownCodec.encode(current).utf8)
        let result = try await SummaryProvenanceFixture.result(after: .busy)

        let after = try #require(MeetingCoordinator.mergingTranscriptFirstSummary(
            result, scaffold: scaffold, current: current
        ))

        #expect(result.usedFallback)
        #expect(after == current)
        #expect(Data(MarkdownCodec.encode(after).utf8) == before)
        #expect(after.summary.contains("Transcript highlights:"))
        #expect(after.transcript == transcript)
        #expect(after.moments == scaffold.moments)
        // The harvested candidates remain available in the result, but do
        // not masquerade as a successful enrichment of this durable scaffold.
        #expect(result.insights.keyPoints == SummaryProvenanceFixture.facts)
        #expect(after.summary != result.insights.summary)
    }

    @Test
    func aSuccessfulWriteUpRemainsSuccessfulAfterFinalValidation() async throws {
        let expected = MeetingInsights(
            title: "October migration", summary: "The team kept the migration window in October.",
            keyPoints: SummaryProvenanceFixture.facts,
            decisions: SummaryProvenanceFixture.decisions,
            actionItems: SummaryProvenanceFixture.actions
        )
        let generated = try await SummaryService.writeUpResult(
            transcript: SummaryProvenanceFixture.transcript, fallbackTitle: "Synthetic meeting",
            ledger: CandidateLedger(), retryOverflow: true, writing: { expected }
        )
        let result = SummaryService.finalizedResult(
            generated, transcript: SummaryProvenanceFixture.transcript,
            fallbackTitle: "Synthetic meeting"
        )

        #expect(result.failure == nil)
        #expect(!result.usedFallback)
        #expect(result.insights == expected)
    }

    @Test(arguments: [false, true])
    func contextOverflowStillRetriesUntilTheFinalAttempt(retryAllowed: Bool) async throws {
        let ledger = await SummaryProvenanceFixture.ledger()
        let overflow = NSError(domain: "FoundationModels.LanguageModelError", code: 0)
        do {
            let result = try await SummaryService.writeUpResult(
                transcript: SummaryProvenanceFixture.transcript, fallbackTitle: "Synthetic meeting",
                ledger: ledger, retryOverflow: retryAllowed, writing: { throw overflow }
            )
            #expect(!retryAllowed)
            #expect(result.failure == .transcriptTooLong)
            #expect(result.insights.keyPoints == SummaryProvenanceFixture.facts)
        } catch {
            #expect(retryAllowed)
            #expect(SummaryService.failureReason(for: error) == .transcriptTooLong)
        }
    }

    @Test
    func anEmptyHarvestPropagatesTheOriginalWriteUpFailure() async throws {
        do {
            _ = try await SummaryService.writeUpResult(
                transcript: SummaryProvenanceFixture.transcript, fallbackTitle: "Synthetic meeting",
                ledger: CandidateLedger(), retryOverflow: false,
                writing: { throw SyntheticWriteUpFailure.busy.error }
            )
            Issue.record("An empty harvest must not become a successful summary")
        } catch {
            #expect(SummaryService.failureReason(for: error) == .modelBusy)
        }
    }

    @Test
    func cancellationNeverTurnsIntoSalvagedContent() async throws {
        let ledger = await SummaryProvenanceFixture.ledger()
        await #expect(throws: CancellationError.self) {
            try await SummaryService.writeUpResult(
                transcript: SummaryProvenanceFixture.transcript, fallbackTitle: "Synthetic meeting",
                ledger: ledger, retryOverflow: false, writing: { throw CancellationError() }
            )
        }
        await #expect(throws: CancellationError.self) {
            try await SummaryService.salvagedResult(
                after: CancellationError(), from: ledger,
                transcript: SummaryProvenanceFixture.transcript, fallbackTitle: "Synthetic meeting"
            )
        }
    }

    @Test(arguments: [false, true])
    func finalValidationCannotPromoteAnInvalidAnswerOrEraseItsOriginalFailure(alreadyFailed: Bool) {
        let invalid = SummaryResult(
            insights: MeetingInsights(title: "Unusable", summary: "", keyPoints: [], decisions: [], actionItems: []),
            failure: alreadyFailed ? .modelBusy : nil
        )
        let result = SummaryService.finalizedResult(
            invalid, transcript: SummaryProvenanceFixture.transcript, fallbackTitle: "Synthetic meeting"
        )

        #expect(result.failure == (alreadyFailed ? .modelBusy : .ungrounded))
        #expect(result.usedFallback)
        #expect(!result.insights.summary.isEmpty)
        #expect(result.insights.summary.contains("Transcript highlights:"))
    }
}

enum SyntheticWriteUpFailure: CaseIterable, Sendable {
    case declined
    case busy
    case unreadable
    case timedOut
    case unsupportedLanguage
    case unexpected

    var reason: SummaryService.FailureReason {
        switch self {
        case .declined: .declined
        case .busy: .modelBusy
        case .unreadable: .malformedAnswer
        case .timedOut: .timedOut
        case .unsupportedLanguage: .unsupportedLanguage
        case .unexpected: .generationFailed
        }
    }

    var error: Error {
        switch self {
        case .declined: NSError(domain: "FoundationModels.LanguageModelError", code: 2)
        case .busy: NSError(domain: "FoundationModels.LanguageModelError", code: 1)
        case .unreadable:
            NSError(domain: "Synthetic.WriteUp", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to parse generated content."
            ])
        case .timedOut: NSError(domain: "FoundationModels.LanguageModelError", code: 8)
        case .unsupportedLanguage: NSError(domain: "FoundationModels.LanguageModelError", code: 7)
        case .unexpected: NSError(domain: "Synthetic.WriteUp", code: 99)
        }
    }
}

private enum SummaryProvenanceFixture {
    static let facts = ["The migration window stays in October"]
    static let decisions = ["Use the staged rollout for migration"]
    static let actions = ["Draft the rollout plan before the board review"]
    static let transcript = [
        TranscriptSegment(startTime: 0, duration: 30, text: "The team agreed the migration window stays in October."),
        TranscriptSegment(startTime: 30, duration: 30, text: "I will draft the rollout plan before the board review."),
        TranscriptSegment(startTime: 60, duration: 30, text: "We decided to use the staged rollout for migration.")
    ]

    static func ledger() async -> CandidateLedger {
        let ledger = CandidateLedger()
        await ledger.add(facts: facts, decisions: decisions, actions: actions)
        return ledger
    }

    static func result(
        after failure: SyntheticWriteUpFailure,
        transcript: [TranscriptSegment] = Self.transcript,
        fallbackTitle: String = "Synthetic meeting"
    ) async throws -> SummaryResult {
        let ledger = await ledger()
        let generated = try await SummaryService.writeUpResult(
            transcript: transcript, fallbackTitle: fallbackTitle,
            ledger: ledger, retryOverflow: true, writing: { throw failure.error }
        )
        return SummaryService.finalizedResult(
            generated, transcript: transcript, fallbackTitle: fallbackTitle
        )
    }

    static func existingNote(in folder: URL) -> MeetingNote {
        MeetingNote(
            title: "My trusted migration summary",
            startedAt: Date(timeIntervalSince1970: 1_780_000_000),
            endedAt: Date(timeIntervalSince1970: 1_780_000_090), sourceApp: "Synthetic",
            summary: "A reviewed Cafe\u{301} summary that must remain exact.",
            keyPoints: ["Keep the reviewed key point"], decisions: ["Keep the reviewed decision"],
            actionItems: ["Keep the reviewed action"], completedActionItems: ["Keep the reviewed action"],
            personalNotes: "  Cafe\u{301} pre-reading.\n", transcript: transcript,
            moments: [MeetingMoment(offset: 10)],
            sessions: [.init(startedAt: Date(timeIntervalSince1970: 1_780_000_000), endedAt: Date(timeIntervalSince1970: 1_780_000_090))],
            audioStart: 4,
            extraSections: [.init(heading: "## Agenda", body: "Keep this handwritten agenda.", anchor: "## summary")],
            fileURL: folder.appendingPathComponent("review.md"),
            fileModified: Date(timeIntervalSince1970: 1_780_000_100), fileRevision: Data("synthetic revision".utf8)
        )
    }
}

private struct SyntheticFailingWriteUpSummarizer: FailureReportingSummarizing {
    let failure: SyntheticWriteUpFailure

    func summarizeReportingFailure(
        transcript: [TranscriptSegment], fallbackTitle: String,
        attention: SummaryAttention?, onStage: SummaryStageHandler?
    ) async -> SummaryResult {
        await onStage?(.writingUp)
        do {
            return try await SummaryProvenanceFixture.result(
                after: failure, transcript: transcript, fallbackTitle: fallbackTitle
            )
        } catch {
            Issue.record("The synthetic harvest unexpectedly failed: \(error)")
            return SummaryResult(
                insights: SummaryService.fallbackInsights(
                    transcript: transcript, fallbackTitle: fallbackTitle, reason: failure.reason
                ),
                failure: failure.reason
            )
        }
    }
}

/// Numbers in agenda labels and capture timestamps are not evidence for
/// quantities in the write-up. All data is synthetic; finalization exercises
/// the production guard without asking an installed model to hallucinate.
struct SummaryNumericGroundingTests {
    @Test(arguments: [
        "A team of 18 individuals worked for 18 minutes, each minute dedicated to designing 40 discussion items.",
        "The team worked for 18 minutes on the discussion items.",
        "40 participants reviewed the design discussion.",
    ])
    func agendaNumbersCannotBecomeParticipantCountsOrDurations(summary: String) {
        let result = finalized(summary: summary)

        #expect(result.failure == .ungrounded)
        #expect(result.usedFallback)
        #expect(result.insights.summary.contains("Transcript highlights:"))
        #expect(result.insights.summary != summary)
    }

    @Test(arguments: ["18 participants", "18 minutes of design review"])
    func aNumericTitleNeedsItsOwnSpokenSupport(title: String) {
        let result = finalized(summary: "The team reviewed the design wording.", title: title)

        #expect(result.failure == .ungrounded)
        #expect(result.insights.title != title)
    }

    @Test
    func captureTimingDoesNotCountAsSpokenNumericEvidence() {
        let transcript = [TranscriptSegment(
            startTime: 18, duration: 40, text: "The team reviewed the design wording."
        )]
        let result = finalized(summary: "The team reviewed the design for 18 minutes.", transcript: transcript)

        #expect(result.failure == .ungrounded)
    }

    @Test(arguments: [
        "The discussion included 40 engineers.",
        "The discussion included 18 designers.",
        "The budget was 1,200.00.",
        "The rate was 19%.",
        "The rate was 1.9.",
        "The delivery code is AB-42.",
    ])
    func digitsCannotBeReassignedOrLoseTheirCurrencyUnitOrCode(summary: String) {
        let transcript = [TranscriptSegment(startTime: 0, duration: 30, text:
            "The discussion included 18 engineers. The discussion included 40 designers. "
                + "The budget was $1,200.00. The rate was 1.9%. The delivery code is ABC-42."
        )]
        let result = finalized(summary: summary, transcript: transcript)

        #expect(result.failure == .ungrounded)
    }

    @Test(arguments: ["$1,200.00", "$ 1,200.00"])
    func supportedCountsAmountsRatesAndCodesSurviveUnchanged(amount: String) {
        let summary = "The staffing plan includes 18 engineers; the budget is \(amount). "
            + "The rate is 1.9%. The delivery code is ABC-42."
        let transcript = [TranscriptSegment(startTime: 0, duration: 30, text:
            "The staffing plan includes 18 engineers. The budget is $1,200.00. "
                + "The rate is 1.9%. The delivery code is ABC-42."
        )]
        let result = finalized(summary: summary, title: "Staffing plan for 18 engineers", transcript: transcript)

        #expect(result.failure == nil)
        #expect(result.insights.summary == summary)
        #expect(result.insights.title == "Staffing plan for 18 engineers")
    }

    @Test
    func faithfulSentencesCanBeJoinedWithoutMovingTheirQuantities() {
        let transcript = [TranscriptSegment(startTime: 0, duration: 30, text:
            "The budget is $1,200.00. The rate is 1.9%."
        )]
        let summary = "The budget is $1,200.00 and the rate is 1.9%."
        let result = finalized(summary: summary, transcript: transcript)

        #expect(result.failure == nil)
        #expect(result.insights.summary == summary)
    }

    @Test(arguments: [
        "The release is August 18, 2026.",
        "The count rose from 18 to 40.",
        "The reviews are August 18 and 19.",
    ])
    func spokenMultiNumberPhrasesKeepTheirDateOrRange(summary: String) {
        let transcript = [TranscriptSegment(startTime: 0, duration: 30, text: summary)]
        let result = finalized(summary: summary, transcript: transcript)

        #expect(result.failure == nil)
        #expect(result.insights.summary == summary)
    }

    @Test
    func writtenCurrencyCodesCannotBeReassigned() {
        let transcript = [TranscriptSegment(startTime: 0, duration: 30, text: "The budget is USD 18.")]
        let unchanged = finalized(summary: "The budget is USD 18.", transcript: transcript)
        let changed = finalized(summary: "The budget is EUR 18.", transcript: transcript)

        #expect(unchanged.failure == nil)
        #expect(changed.failure == .ungrounded)
        let items = MeetingInsightGrounder.ground(MeetingInsights(
            title: "Budget review", summary: "The team reviewed the budget.",
            keyPoints: ["Budget USD 18", "Budget EUR 18"], decisions: [], actionItems: []
        ), in: transcript)
        #expect(items.keyPoints == ["Budget USD 18"])
    }

    @Test
    func surroundingWordsMustSupportTheNumberEvenWhenItsUnitMatches() {
        let transcript = [TranscriptSegment(startTime: 0, duration: 30, text:
            "The exercise lasted 18 minutes. The team reviewed the meeting agenda."
        )]
        let changedSubject = finalized(summary: "The meeting took 18 minutes.", transcript: transcript)
        #expect(changedSubject.failure == .ungrounded)
    }

    @Test
    func anExistingFallbackTitleDoesNotNeedToBeSpoken() {
        let result = finalized(
            summary: "The team reviewed the design wording.",
            title: "Design review 2026", fallbackTitle: "Design review 2026"
        )

        #expect(result.failure == nil)
    }

    @Test
    func unsupportedListQuantitiesAreDroppedWithoutLosingSupportedItems() {
        let transcript = [
            TranscriptSegment(startTime: 0, duration: 10, text: "Design discussion item 18."),
            TranscriptSegment(startTime: 10, duration: 10, text: "I will review 40 designs by Friday."),
            TranscriptSegment(startTime: 20, duration: 10, text: "We agreed to approve 40 designs."),
        ]
        let proposed = MeetingInsights(
            title: "Design review", summary: "The team reviewed the designs.",
            keyPoints: ["Design discussion item 18", "Design discussion with 18 participants"],
            decisions: ["Approve 40 designs", "Approve 18 designs"],
            actionItems: ["Review 40 designs by Friday", "Review 18 designs by Friday"]
        )
        let grounded = MeetingInsightGrounder.ground(proposed, in: transcript)

        #expect(grounded.keyPoints == ["Design discussion item 18"])
        #expect(grounded.decisions == ["Approve 40 designs"])
        #expect(grounded.actionItems == ["Review 40 designs by Friday"])
    }

    @MainActor
    @Test
    func anUngroundedNumericWriteUpCannotReplaceAnySavedField() async throws {
        let folder = URL(fileURLWithPath: "/synthetic-numeric-grounding/Notes", isDirectory: true)
        var original = SummaryProvenanceFixture.existingNote(in: folder)
        original.transcript = Self.agendaTranscript
        let originalBytes = Data(MarkdownCodec.encode(original).utf8)
        var current = original
        var commits = 0
        let session = SummaryRegenerationSession { note, onStage in
            await SummaryRegenerator.regenerate(note, using: SyntheticNumericWriteUpSummarizer(), onStage: onStage)
        }
        let started = session.start(
            note: original,
            library: { .init(directoryURL: folder, generation: 0, notes: [current]) },
            commit: { replacement in
                commits += 1
                current = replacement
                return replacement
            }
        )
        let task = try #require(started)

        await task.value

        #expect(commits == 0)
        #expect(current == original)
        #expect(Data(MarkdownCodec.encode(current).utf8) == originalBytes)
        #expect(!session.isRunning)
        let completion = try #require(session.completion)
        guard case .retained(let reason) = completion.result else {
            Issue.record("An ungrounded numeric write-up must retain the existing note")
            return
        }
        #expect(reason == .ungrounded)
    }

    private static let agendaTranscript = (0..<80).map { index in
        TranscriptSegment(
            startTime: Double(index * 3), duration: 3,
            text: "Design discussion item \(index). Keep the wording clear, verify the local notes and review the next step with the team."
        )
    }

    private func finalized(
        summary: String, title: String = "Design review", fallbackTitle: String = "Synthetic meeting",
        transcript: [TranscriptSegment] = Self.agendaTranscript
    ) -> SummaryResult {
        SummaryService.finalizedResult(
            SummaryResult(insights: MeetingInsights(
                title: title, summary: summary, keyPoints: [], decisions: [], actionItems: []
            ), failure: nil),
            transcript: transcript, fallbackTitle: fallbackTitle
        )
    }
}

private struct SyntheticNumericWriteUpSummarizer: FailureReportingSummarizing {
    func summarizeReportingFailure(
        transcript: [TranscriptSegment], fallbackTitle: String,
        attention: SummaryAttention?, onStage: SummaryStageHandler?
    ) async -> SummaryResult {
        await onStage?(.writingUp)
        return SummaryService.finalizedResult(
            SummaryResult(insights: MeetingInsights(
                title: "Design review",
                summary: "A team of 18 individuals worked for 18 minutes, each minute dedicated to designing 40 discussion items.",
                keyPoints: [], decisions: [], actionItems: []
            ), failure: nil),
            transcript: transcript, fallbackTitle: fallbackTitle
        )
    }
}
