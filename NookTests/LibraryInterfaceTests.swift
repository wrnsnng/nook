import Foundation
import Testing
@testable import Nook

/// The library's own arithmetic: what fits in the sidebar, how the palette is
/// grouped, and the sentences built from a person's notes.
///
/// All of it deliberately lives outside the views so the wording and the
/// counts can be pinned without rendering anything.
struct LibraryInterfaceTests {

    // MARK: - Sidebar cap

    private func action(_ index: Int) -> OpenAction {
        OpenAction(
            noteID: UUID(),
            itemIndex: index,
            text: "Item \(index)",
            dueDate: nil,
            noteTitle: "A meeting",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    @Test
    func theSidebarShowsAtMostThreeOpenActionsUntilAsked() {
        let entries = (0..<5).map(action)

        let collapsed = LibrarySidebarPolicy.visibleOpenActions(
            entries,
            showingAll: false
        )

        #expect(collapsed.count == 3)
        #expect(collapsed.map(\.text) == ["Item 0", "Item 1", "Item 2"])
    }

    @Test
    func askingForMoreShowsEveryOpenActionInTheSidebar() {
        let entries = (0..<5).map(action)

        let expanded = LibrarySidebarPolicy.visibleOpenActions(
            entries,
            showingAll: true
        )

        #expect(expanded.count == 5)
    }

    @Test
    func aShortListOfActionsOffersNothingToExpand() {
        let entries = (0..<3).map(action)
        let visible = LibrarySidebarPolicy.visibleOpenActions(
            entries,
            showingAll: false
        )

        #expect(
            LibrarySidebarPolicy.disclosureLabel(
                pool: entries.count,
                visible: visible.count,
                showingAll: false
            ) == nil
        )
    }

    @Test
    func theDisclosureCountsOnlyWhatItWillReveal() {
        let entries = (0..<7).map(action)
        let visible = LibrarySidebarPolicy.visibleOpenActions(
            entries,
            showingAll: false
        )

        #expect(
            LibrarySidebarPolicy.disclosureLabel(
                pool: entries.count,
                visible: visible.count,
                showingAll: false
            ) == "4 more"
        )
        #expect(
            LibrarySidebarPolicy.disclosureLabel(
                pool: entries.count,
                visible: entries.count,
                showingAll: true
            ) == "Show fewer"
        )
    }

    // MARK: - Command palette sections

    private func paletteItem(_ id: String) -> CommandPaletteItem {
        CommandPaletteItem(
            id: id,
            symbol: "circle",
            title: id,
            subtitle: nil,
            destination: .verb,
            perform: {}
        )
    }

    @Test
    func thePaletteGroupsCommandsNotesAndActionsInThatOrder() {
        let sections = CommandPaletteSection.grouped(
            commands: [paletteItem("record")],
            notes: [paletteItem("note")],
            openActions: [paletteItem("action")]
        )

        #expect(sections.map(\.title) == ["Commands", "Notes", "Open actions"])
    }

    @Test
    func thePaletteNeverShowsAHeadingWithNothingUnderIt() {
        let sections = CommandPaletteSection.grouped(
            commands: [paletteItem("record")],
            notes: [],
            openActions: []
        )

        #expect(sections.map(\.title) == ["Commands"])
        #expect(sections.flatMap(\.items).count == 1)
    }

    // MARK: - Ask examples

    private func note(
        _ title: String,
        daysAgo: Int,
        kind: NoteKind = .default
    ) -> MeetingNote {
        let started = Date(timeIntervalSince1970: 1_700_000_000)
            .addingTimeInterval(TimeInterval(-daysAgo) * 86_400)
        return MeetingNote(
            kind: kind,
            title: title,
            startedAt: started,
            endedAt: started.addingTimeInterval(1_800),
            sourceApp: "Zoom",
            summary: "Talked it through."
        )
    }

    @Test
    func askSuggestsThreeQuestionsFromTheMostRecentMeetings() {
        let examples = LibraryAskExamples.questions(for: [
            note("Research synthesis", daysAgo: 0),
            note("Summer launch planning", daysAgo: 1),
            note("Design weekly", daysAgo: 2),
            note("Hiring loop", daysAgo: 3),
        ])

        #expect(examples.count == 3)
        #expect(examples[0].contains("Research synthesis"))
        #expect(examples[1].contains("Summer launch planning"))
        #expect(examples[2].contains("Design weekly"))
    }

    @Test
    func askSuggestionsIgnoreDigestsAndRepeatedTitles() {
        let examples = LibraryAskExamples.questions(for: [
            note("This week in meetings", daysAgo: 0, kind: .digest),
            note("Design weekly", daysAgo: 1),
            note("Design weekly", daysAgo: 8),
        ])

        #expect(examples.count == 1)
        #expect(
            examples[0]
                == "What did we decide about \u{201C}Design weekly\u{201D}?"
        )
    }

    @Test
    func anEmptyLibraryOffersNoExampleQuestions() {
        #expect(LibraryAskExamples.questions(for: []).isEmpty)
    }

    // MARK: - Prep brief copy

    @Test
    func prepHistoryReadsAsASentenceAtEveryCount() {
        #expect(
            PrepBriefCopy.history(sittings: 1, totalDuration: 22 * 60)
                == "You have met once before, 22m total"
        )
        #expect(
            PrepBriefCopy.history(sittings: 2, totalDuration: 39 * 60)
                == "You have met twice before, 39m total"
        )
        #expect(
            PrepBriefCopy.history(sittings: 4, totalDuration: 130 * 60)
                == "You have met 4 times before, 2h 10m total"
        )
    }

    @Test
    func aMeetingShorterThanAMinuteStillCountsAsHavingHappened() {
        #expect(
            PrepBriefCopy.history(sittings: 1, totalDuration: 20)
                == "You have met once before, 1m total"
        )
    }

    // MARK: - Sidebar grouping

    private func timedNote(_ title: String, startedAt: Date) -> MeetingNote {
        MeetingNote(
            title: title,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(1_800),
            sourceApp: "Zoom",
            summary: "Talked it through."
        )
    }

    @Test
    func filteringNarrowsToTodayOnlyAndSearchMatches() {
        let calendar = Calendar.autoupdatingCurrent
        let now = Date()
        let today = timedNote("Today's standup", startedAt: now)
        let yesterday = timedNote(
            "Yesterday's sync",
            startedAt: calendar.date(byAdding: .day, value: -1, to: now)!
        )
        let notes = [today, yesterday]

        let todayOnly = LibraryNoteGrouping.filter(
            notes,
            todayOnly: true,
            matchingIDs: nil,
            calendar: calendar
        )
        #expect(todayOnly.map(\.id) == [today.id])

        let searched = LibraryNoteGrouping.filter(
            notes,
            todayOnly: false,
            matchingIDs: [yesterday.id]
        )
        #expect(searched.map(\.id) == [yesterday.id])
    }

    @Test
    func groupingBucketsTodayAndYesterdaySeparatelyFromOlderMeetings() {
        let calendar = Calendar.autoupdatingCurrent
        let now = Date()
        let today = timedNote("Today's standup", startedAt: now)
        let yesterday = timedNote(
            "Yesterday's sync",
            startedAt: calendar.date(byAdding: .day, value: -1, to: now)!
        )
        // Far enough back to fall outside "This week" regardless of which
        // day the current locale's week starts on.
        let older = timedNote(
            "Quarterly planning",
            startedAt: calendar.date(byAdding: .day, value: -400, to: now)!
        )

        let groups = LibraryNoteGrouping.group(
            [today, yesterday, older],
            referenceDate: now,
            calendar: calendar
        )

        #expect(groups.map(\.title) == [
            "Today",
            "Yesterday",
            older.startedAt.formatted(.dateTime.month(.wide).year()),
        ])
        #expect(
            groups.map { $0.notes.map(\.id) }
                == [[today.id], [yesterday.id], [older.id]]
        )
    }

    @Test
    func liveActivityCoversRecordingProcessingAndFailedPhases() {
        #expect(
            MeetingPhase.recording(title: "x", startedAt: .now)
                .presentsLiveActivity
        )
        #expect(MeetingPhase.processing(.transcribing).presentsLiveActivity)
        #expect(MeetingPhase.failed("oops").presentsLiveActivity)
        #expect(!MeetingPhase.idle.presentsLiveActivity)
        #expect(!MeetingPhase.completed("done").presentsLiveActivity)
    }

    // MARK: - Grouping cache key

    @Test
    func theGroupingCacheKeyIsStableWhenNothingRelevantChanges() {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let notes = [note("Design weekly", daysAgo: 0)]

        let first = LibraryGroupingCacheKey(
            notes: notes,
            matchingIDs: nil,
            todayOnly: false,
            now: stamp
        )
        let second = LibraryGroupingCacheKey(
            notes: notes,
            matchingIDs: nil,
            todayOnly: false,
            now: stamp
        )

        #expect(first == second)
    }

    @Test
    func theGroupingCacheKeyChangesWithNotesSearchScopeOrDay() {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let original = [note("Design weekly", daysAgo: 0)]
        var withAnotherNote = original
        withAnotherNote.append(note("Hiring loop", daysAgo: 1))

        let base = LibraryGroupingCacheKey(
            notes: original,
            matchingIDs: nil,
            todayOnly: false,
            now: stamp
        )

        #expect(base != LibraryGroupingCacheKey(
            notes: withAnotherNote,
            matchingIDs: nil,
            todayOnly: false,
            now: stamp
        ))
        #expect(base != LibraryGroupingCacheKey(
            notes: original,
            matchingIDs: [original[0].id],
            todayOnly: false,
            now: stamp
        ))
        #expect(base != LibraryGroupingCacheKey(
            notes: original,
            matchingIDs: nil,
            todayOnly: true,
            now: stamp
        ))
        #expect(base != LibraryGroupingCacheKey(
            notes: original,
            matchingIDs: nil,
            todayOnly: false,
            now: stamp.addingTimeInterval(86_400)
        ))
    }

    @Test
    func theGroupingCacheKeyTracksTheNewestFileModifiedDate() {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        var edited = note("Design weekly", daysAgo: 0)
        edited.fileModified = stamp
        var untouched = note("Design weekly", daysAgo: 0)
        untouched.fileModified = nil

        let before = LibraryGroupingCacheKey(
            notes: [untouched],
            matchingIDs: nil,
            todayOnly: false,
            now: stamp
        )
        let after = LibraryGroupingCacheKey(
            notes: [edited],
            matchingIDs: nil,
            todayOnly: false,
            now: stamp
        )

        #expect(before != after)
    }

    @Test
    func theGroupingCacheKeyChangesWhenATitleChangesAtTheSameModifiedTime() {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        // Deliberately identical: a coarse filesystem clock, or two saves
        // landing in the same tick, can leave `fileModified` looking
        // unchanged even though the note's title on disk did change. The
        // fingerprint has to catch this from the title alone.
        let modified = Date(timeIntervalSince1970: 1_699_999_999)
        var original = note("Design weekly", daysAgo: 0)
        original.fileModified = modified

        var renamed = original
        renamed.title = "Design weekly, renamed"

        let before = LibraryGroupingCacheKey(
            notes: [original],
            matchingIDs: nil,
            todayOnly: false,
            now: stamp
        )
        let after = LibraryGroupingCacheKey(
            notes: [renamed],
            matchingIDs: nil,
            todayOnly: false,
            now: stamp
        )

        #expect(before != after)
    }

    @Test
    func theGroupingCacheKeyDoesNotDependOnNoteOrder() {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let first = note("Design weekly", daysAgo: 0)
        let second = note("Hiring loop", daysAgo: 1)

        let forward = LibraryGroupingCacheKey(
            notes: [first, second],
            matchingIDs: nil,
            todayOnly: false,
            now: stamp
        )
        let reversed = LibraryGroupingCacheKey(
            notes: [second, first],
            matchingIDs: nil,
            todayOnly: false,
            now: stamp
        )

        // A reload that returns the same notes in a different order must not
        // look like a change, or every reload would defeat the cache.
        #expect(forward == reversed)
    }

    // MARK: - Detail presentation

    @Test
    func longSummaryParagraphsKeepExactTextAndUseSentenceBoundaries() {
        let summary = (1...18)
            .map { "Sentence \($0) has useful detail." }
            .joined(separator: " ")

        let paragraphs = DetailSummaryParagraphPolicy.paragraphs(for: summary)

        #expect(paragraphs.count == 2)
        #expect(paragraphs.joined() == summary)
        #expect(
            paragraphs.allSatisfy {
                $0.split(whereSeparator: \.isWhitespace).count
                    >= DetailSummaryParagraphPolicy.minimumWordsPerParagraph
            }
        )
    }

    @Test
    func veryLongSummaryUsesThreeBalancedParagraphsWithoutRewriting() {
        let summary = (1...36)
            .map { "Sentence \($0) has useful detail." }
            .joined(separator: " ")

        let paragraphs = DetailSummaryParagraphPolicy.paragraphs(for: summary)

        #expect(paragraphs.count == 3)
        #expect(paragraphs.joined() == summary)
        #expect(
            paragraphs.map {
                $0.split(whereSeparator: \.isWhitespace).count
            } == [60, 60, 60]
        )
    }

    @Test
    func shortSummaryParagraphsStayOneExactSelectionValue() {
        let summary = "A short summary stays intact.\n"

        #expect(DetailSummaryParagraphPolicy.paragraphs(for: summary) == [summary])
    }

    @Test
    func longSemicolonSummaryUsesClauseBoundariesWithoutRewriting() {
        let summary = (1...20)
            .map { "Clause \($0) records useful detail" }
            .joined(separator: "; ") + "."

        let paragraphs = DetailSummaryParagraphPolicy.paragraphs(for: summary)

        #expect(paragraphs.count == 2)
        #expect(paragraphs.joined() == summary)
        #expect(
            paragraphs.allSatisfy {
                $0.split(whereSeparator: \.isWhitespace).count
                    >= DetailSummaryParagraphPolicy.minimumWordsPerParagraph
            }
        )
    }

    @Test
    func realWorldSemicolonSummaryGetsAReadableBreak() {
        let summary = """
            The discussion covered conversion barriers for Pop and Podcast customers, including a three-step onboarding process requiring supplier agreement, accounting connection, and KYC documentation; approximately 100–200 customers have meaningful M-coin balances but do not convert, with 40% of entities having opted in since January; KYC requirements must be defined per entity, documentation is required before fund payouts, and the process must be streamlined to avoid blocking onboarding; risk management considerations include stolen data, stolen IDs, and the need for secured products with PPSR registration, while customer data must be returned and ABM pre-populated; a $1,000,000 pool is available, LTI plans last 3 years, and early payment incentives include 6% fee instead of 3.45% and double M-coin for on-time or early payment
            """

        let paragraphs = DetailSummaryParagraphPolicy.paragraphs(for: summary)

        #expect(paragraphs.count == 2)
        #expect(paragraphs.joined() == summary)
    }

    @Test
    func shortSemicolonSummaryStaysOneExactSelectionValue() {
        let summary = "First clause stays concise; second clause is still short."

        #expect(DetailSummaryParagraphPolicy.paragraphs(for: summary) == [summary])
    }

    @Test
    func renameActionsRequireCleanMarkdownDrafts() {
        #expect(!DetailRenamePolicy.allowsTitleRename(hasMarkdownChanges: true))
        #expect(
            !DetailRenamePolicy.allowsFileRename(
                hasMarkdownChanges: true,
                hasManagedFile: true
            )
        )
        #expect(
            DetailRenamePolicy.allowsFileRename(
                hasMarkdownChanges: false,
                hasManagedFile: true
            )
        )
    }

    @Test
    func transcriptGroupingShowsChangedSourcesGapsAndTheFirstFilteredRow() {
        let first = TranscriptSegment(
            startTime: 0,
            duration: 3,
            text: "First line",
            source: .microphone
        )
        let nearby = TranscriptSegment(
            startTime: 8,
            duration: 3,
            text: "Nearby line",
            source: .microphone
        )
        let afterPause = TranscriptSegment(
            startTime: 40,
            duration: 3,
            text: "After the pause",
            source: .microphone
        )
        let changedSource = TranscriptSegment(
            startTime: 44,
            duration: 3,
            text: "Other source",
            source: .system
        )

        let visible = TranscriptBadgeGroupingPolicy.visibleBadgeIDs(
            in: [first, nearby, afterPause, changedSource]
        )
        #expect(visible == [first.id, afterPause.id, changedSource.id])

        // Filtering removes the predecessor, so the first result must regain
        // its source context even if it was grouped in the full transcript.
        let filtered = TranscriptBadgeGroupingPolicy.visibleBadgeIDs(
            in: [nearby]
        )
        #expect(filtered == [nearby.id])
    }

    @Test
    func transcriptGroupingRestoresTheBadgeAtASessionBoundary() {
        let first = TranscriptSegment(
            startTime: 0,
            duration: 3,
            text: "First sitting",
            source: .microphone
        )
        let next = TranscriptSegment(
            startTime: 10,
            duration: 3,
            text: "Second sitting",
            source: .microphone
        )
        let sessions = [
            MeetingSession(
                startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                endedAt: Date(timeIntervalSince1970: 1_700_000_010)
            ),
            MeetingSession(
                startedAt: Date(timeIntervalSince1970: 1_700_001_000),
                endedAt: Date(timeIntervalSince1970: 1_700_001_010)
            )
        ]

        let visible = TranscriptBadgeGroupingPolicy.visibleBadgeIDs(
            in: [first, next],
            sessions: sessions
        )

        #expect(visible == [first.id, next.id])
    }
}
