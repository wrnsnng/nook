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

    @Test
    func paletteReturnStillOpensTheChosenFileAfterReloadReordersCopies() {
        let sharedID = UUID()
        let first = LibraryNoteIdentity(
            noteID: sharedID, fileURL: URL(fileURLWithPath: "/synthetic/first.md")
        )
        let second = LibraryNoteIdentity(
            noteID: sharedID, fileURL: URL(fileURLWithPath: "/synthetic/second.md")
        )
        var openedFile: LibraryNoteIdentity?
        let items = [first, second].map { identity in
            CommandPaletteItem(
                id: "note-\(identity.navigationKey)", symbol: "doc",
                title: "Copied meeting", subtitle: identity.filePath,
                destination: .note(sharedID),
                perform: { openedFile = identity }
            )
        }
        var selection = CommandPaletteSelection()
        selection.select(items[1])

        let reloaded = Array(items.reversed())
        selection.refresh(in: reloaded)
        selection.selectedItem(in: reloaded)?.perform()

        #expect(openedFile == second)
        #expect(selection.itemID == items[1].id)
    }

    @Test
    func removingTheHighlightedPaletteFileRequiresAnotherChoiceBeforeReturn() {
        var openedReplacement = false
        let removed = paletteItem("note-removed")
        let replacement = CommandPaletteItem(
            id: "note-replacement", symbol: "doc", title: "Other file",
            subtitle: nil, destination: .note(UUID()),
            perform: { openedReplacement = true }
        )
        var selection = CommandPaletteSelection()
        selection.select(removed)
        selection.refresh(in: [replacement])
        selection.selectedItem(in: [replacement])?.perform()
        // Another background publication must not re-arm Return either.
        selection.refresh(in: [replacement])
        selection.selectedItem(in: [replacement])?.perform()

        #expect(selection.itemID == nil)
        #expect(!openedReplacement)

        selection.move(1, in: [replacement])
        selection.selectedItem(in: [replacement])?.perform()
        #expect(openedReplacement)
    }

    @Test
    func typingANewPaletteQueryChoosesItsFirstResult() {
        var selection = CommandPaletteSelection()
        selection.select(paletteItem("previous-query-result"))
        let results = [paletteItem("first-match"), paletteItem("second-match")]

        selection.refresh(in: results, selectFirst: true)

        #expect(selection.selectedItem(in: results)?.id == "first-match")
        selection.refresh(in: [], selectFirst: true)
        #expect(selection.selectedItem(in: results) == nil)
    }

    @Test
    func equallyDatedCopiesKeepTheSamePaletteOrderRegardlessOfFolderEnumeration() {
        var first = note("Copied meeting", daysAgo: 0)
        first.fileURL = URL(fileURLWithPath: "/synthetic/a.md")
        var second = first
        second.fileURL = URL(fileURLWithPath: "/synthetic/b.md")

        for query in ["", "copied"] {
            let forward = CommandPaletteNoteOrder.ordered([first, second], matching: query)
            let reversed = CommandPaletteNoteOrder.ordered([second, first], matching: query)
            #expect(forward.map(\.libraryIdentity) == [first.libraryIdentity, second.libraryIdentity])
            #expect(reversed.map(\.libraryIdentity) == forward.map(\.libraryIdentity))
        }
    }

    // MARK: - Ask examples

    @Test(arguments: [
        "/synthetic/Other/meeting.md",
        "/synthetic/Notes Copy/meeting.md",
        "/synthetic/Notes/archive/meeting.md"
    ])
    func librarySheetsRefuseSavedNotesFromOtherFoldersEvenWithMatchingIDs(
        otherPath: String
    ) {
        var current = note("Current meeting", daysAgo: 0)
        current.fileURL = URL(fileURLWithPath: "/synthetic/Notes/current.md")
        var previous = current
        previous.fileURL = URL(fileURLWithPath: otherPath)

        #expect(!LibrarySheetOwnership.matchesCurrentFolder(
            [current, previous], directoryURL: URL(fileURLWithPath: "/synthetic/Notes", isDirectory: true)
        ))
        #expect(!LibrarySheetOwnership.matchesCurrentFolder(
            [previous], directoryURL: URL(fileURLWithPath: "/synthetic/Notes", isDirectory: true)
        ))
    }

    @Test
    func librarySheetsAcceptStandardizedAddressesInTheSameFolder() {
        var current = note("Current meeting", daysAgo: 0)
        current.fileURL = URL(fileURLWithPath: "/synthetic/Notes/./current.md")

        #expect(LibrarySheetOwnership.matchesCurrentFolder(
            [current], directoryURL: URL(fileURLWithPath: "/synthetic/Notes/", isDirectory: true)
        ))
    }

    @Test
    func librarySheetsAllowUnsavedModelsAndAnEmptyCurrentFolder() {
        let unsaved = note("Unsaved note", daysAgo: 0)
        let directory = URL(fileURLWithPath: "/synthetic/Notes", isDirectory: true)

        #expect(unsaved.fileURL == nil)
        #expect(LibrarySheetOwnership.matchesCurrentFolder([unsaved], directoryURL: directory))
        #expect(LibrarySheetOwnership.matchesCurrentFolder([], directoryURL: directory))
    }

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
            matchingIDs: [yesterday.libraryIdentity]
        )
        #expect(searched.map(\.id) == [yesterday.id])
    }

    @Test
    func sidebarSearchFeedbackNamesTheRangeWhenAMatchIsFromYesterday() {
        let yesterday = timedNote(
            "Research review 0001",
            startedAt: Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        )
        let matches: Set<LibraryNoteIdentity> = [yesterday.libraryIdentity]
        let todayResults = LibraryNoteGrouping.filter(
            [yesterday], todayOnly: true, matchingIDs: matches
        )
        let allResults = LibraryNoteGrouping.filter(
            [yesterday], todayOnly: false, matchingIDs: matches
        )

        #expect(LibrarySidebarPolicy.emptySearchMessage(
            query: "Research review 0001", todayOnly: true,
            isLoading: false, isSearching: false,
            hasVisibleNotes: !todayResults.isEmpty
        ) == "No matching notes today")
        #expect(LibrarySidebarPolicy.emptySearchMessage(
            query: "Research review 0001", todayOnly: false,
            isLoading: false, isSearching: false,
            hasVisibleNotes: !allResults.isEmpty
        ) == nil)
        #expect(LibrarySidebarPolicy.emptySearchMessage(
            query: "An absent note", todayOnly: false,
            isLoading: false, isSearching: false, hasVisibleNotes: false
        ) == "No matching notes")
    }

    @Test
    func sidebarDoesNotClaimMissingMatchesWhileSearchingOrLoading() {
        for state in [(isLoading: true, isSearching: false),
                      (isLoading: false, isSearching: true)] {
            #expect(LibrarySidebarPolicy.emptySearchMessage(
                query: "Research", todayOnly: true,
                isLoading: state.isLoading, isSearching: state.isSearching,
                hasVisibleNotes: false
            ) == nil)
        }
        #expect(LibrarySidebarPolicy.emptySearchMessage(
            query: " \n\t", todayOnly: true,
            isLoading: false, isSearching: false, hasVisibleNotes: false
        ) == nil)
    }

    @Test
    func cancellingADirtyScopeChangeKeepsTheOriginalRange() {
        for initialTodayOnly in [false, true] {
            var scope = LibraryScopeState()
            scope.request(initialTodayOnly, needsConfirmation: false)
            let decision = LibraryLeaveGuard.decide(
                hasMarkdownChanges: true, hasPersonalNotesChanges: false
            )
            scope.request(!initialTodayOnly, needsConfirmation: decision == .askAboutMarkdown)

            // The range remains unchanged while Save, Discard, or Cancel is
            // being chosen, so the original editor's row stays visible.
            #expect(scope.todayOnly == initialTodayOnly)
            scope.settle(confirmed: false)

            #expect(scope.todayOnly == initialTodayOnly)
            #expect(scope.pendingTodayOnly == nil)
        }
    }

    @Test
    func reloadsAndPhaseChangesKeepTheEditorWhileItsScopeDecisionIsOpen() {
        var original = timedNote("Yesterday's draft", startedAt: Date())
        original.fileURL = URL(fileURLWithPath: "/synthetic/original.md")
        var otherCopy = original
        otherCopy.fileURL = URL(fileURLWithPath: "/synthetic/other-copy.md")
        let today = timedNote("Today's note", startedAt: Date())
        let selected: LibrarySelection? = .note(original.libraryIdentity)
        var scope = LibraryScopeState()
        scope.request(true, needsConfirmation: true)

        // An empty reload used to clear the editor directly. A subsequent
        // reload or completed meeting could then replace it before Cancel.
        let automaticProposals: [LibrarySelection?] = [
            nil, .note(otherCopy.libraryIdentity), .note(today.libraryIdentity), .live
        ]
        for proposal in automaticProposals {
            let decision = LibraryLeaveGuard.decide(
                from: selected, to: proposal, isConfirmingMarkdown: true,
                hasMarkdownChanges: true, hasPersonalNotesChanges: true
            )
            // No decision means requestSelection returns before replacing
            // either the editor identity or its pending destination/range.
            #expect(decision == nil)
            #expect(!scope.todayOnly)
            #expect(scope.pendingTodayOnly == true)
        }
        scope.settle(confirmed: false)

        #expect(selected == .note(original.libraryIdentity))
        #expect(!scope.todayOnly)
        #expect(scope.pendingTodayOnly == nil)
    }

    @Test
    func aReloadOrCompletedMeetingStillAsksBeforeLeavingANewDirtyEditor() {
        let original = timedNote("Original", startedAt: Date())
        let replacement = timedNote("Replacement", startedAt: Date())
        let proposals: [LibrarySelection?] = [nil, .note(replacement.libraryIdentity)]
        for proposal in proposals {
            #expect(LibraryLeaveGuard.decide(
                from: .note(original.libraryIdentity), to: proposal,
                isConfirmingMarkdown: false,
                hasMarkdownChanges: true, hasPersonalNotesChanges: false
            ) == .askAboutMarkdown)
            #expect(LibraryLeaveGuard.decide(
                from: .note(original.libraryIdentity), to: proposal,
                isConfirmingMarkdown: false,
                hasMarkdownChanges: false, hasPersonalNotesChanges: true
            ) == .saveFirst)
            #expect(LibraryLeaveGuard.decide(
                from: .note(original.libraryIdentity), to: proposal,
                isConfirmingMarkdown: false,
                hasMarkdownChanges: false, hasPersonalNotesChanges: false
            ) == .leave)
        }
    }

    @Test
    func confirmingTodaySelectsAVisibleFileInsteadOfThePreviousDaysNote() {
        let calendar = Calendar.current
        let now = Date()
        let today = timedNote("Today's note", startedAt: now)
        let yesterday = timedNote(
            "Yesterday's note",
            startedAt: calendar.date(byAdding: .day, value: -1, to: now)!
        )
        var scope = LibraryScopeState()
        scope.request(true, needsConfirmation: true)
        scope.settle(confirmed: true)
        let visible = LibraryNoteGrouping.filter(
            [yesterday, today], todayOnly: scope.todayOnly, matchingIDs: nil,
            calendar: calendar
        )

        let selected = LibraryScopeState.visibleSelection(
            preserving: yesterday.libraryIdentity, in: visible
        )

        #expect(scope.todayOnly)
        #expect(selected == today.libraryIdentity)
        #expect(!visible.contains { $0.libraryIdentity == yesterday.libraryIdentity })
    }

    @Test
    func aScopeChangeKeepsTheExactSelectedFileWhenItIsStillVisible() {
        var first = timedNote("Same note ID", startedAt: Date())
        first.fileURL = URL(fileURLWithPath: "/synthetic/first.md")
        var second = first
        second.fileURL = URL(fileURLWithPath: "/synthetic/second.md")

        #expect(LibraryScopeState.visibleSelection(
            preserving: second.libraryIdentity, in: [first, second]
        ) == second.libraryIdentity)
        #expect(LibraryScopeState.visibleSelection(
            preserving: second.libraryIdentity, in: []
        ) == nil)
    }

    @Test
    func anEmptyTodayRangeOffersAllNotesInsteadOfFirstRecording() {
        let state = LibraryPlaceholderState.choose(
            isLoading: false, hasNotes: true, todayOnly: true,
            hasVisibleNotes: false, hasSearch: false, hasLoadError: false
        )
        var scope = LibraryScopeState()
        scope.request(true, needsConfirmation: false)
        scope.request(false, needsConfirmation: false)

        #expect(state == .emptyToday)
        #expect(!scope.todayOnly)
    }

    @Test
    func loadingNeverClaimsAnEmptyLibraryBeforeTheFilesArrive() {
        for todayOnly in [false, true] {
            #expect(LibraryPlaceholderState.choose(
                isLoading: true, hasNotes: false, todayOnly: todayOnly,
                hasVisibleNotes: false, hasSearch: false, hasLoadError: false
            ) == .loading)
        }
        #expect(LibraryPlaceholderState.choose(
            isLoading: false, hasNotes: false, todayOnly: false,
            hasVisibleNotes: false, hasSearch: false, hasLoadError: false
        ) == .emptyLibrary)
    }

    @Test
    func failedLoadingAndFilteredResultsDoNotOfferFirstRecording() {
        #expect(LibraryPlaceholderState.choose(
            isLoading: false, hasNotes: false, todayOnly: false,
            hasVisibleNotes: false, hasSearch: false, hasLoadError: true
        ) == .loadFailure)
        #expect(LibraryPlaceholderState.choose(
            isLoading: false, hasNotes: true, todayOnly: false,
            hasVisibleNotes: false, hasSearch: true, hasLoadError: false
        ) == .noSearchMatches)
        #expect(LibraryPlaceholderState.choose(
            isLoading: false, hasNotes: true, todayOnly: false,
            hasVisibleNotes: true, hasSearch: false, hasLoadError: false
        ) == .noSelection)
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
            matchingIDs: [original[0].libraryIdentity],
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
