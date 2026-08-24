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
}
