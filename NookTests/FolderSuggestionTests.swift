import Foundation
import Testing
@testable import Nook

/// Nook suggests a folder for a note at the library's root and files a new
/// recurring meeting with its earlier sittings. Every rule prefers silence
/// to a wrong answer, so most of these pin when nothing happens.
@MainActor
struct FolderSuggestionTests {
    // MARK: - Fixtures

    private let library = URL(fileURLWithPath: "/tmp/Nook-FolderSuggestion-Fixture", isDirectory: true)

    private func note(
        _ title: String,
        in folder: String? = nil,
        day: Double = 0,
        kind: NoteKind = .meeting,
        speakers: [String] = []
    ) -> MeetingNote {
        let start = Date(timeIntervalSince1970: 1_780_000_000 + day * 86_400)
        let directory = folder.map { library.appendingPathComponent($0, isDirectory: true) } ?? library
        return MeetingNote(
            kind: kind,
            title: title,
            startedAt: start,
            endedAt: start.addingTimeInterval(1_800),
            sourceApp: "Manual",
            summary: "Synthetic summary.",
            transcript: speakers.enumerated().map { index, name in
                TranscriptSegment(
                    startTime: Double(index), duration: 1, text: "Synthetic line.",
                    source: .system, speaker: name
                )
            },
            fileURL: directory.appendingPathComponent("\(UUID().uuidString).md")
        )
    }

    private func suggestion(
        for candidate: MeetingNote,
        among notes: [MeetingNote],
        folders: [String]
    ) -> FolderSuggestion? {
        FolderSuggestionIndex(notes: notes + [candidate], folders: folders, libraryURL: library)
            .suggestion(for: candidate, isInFolder: false)
    }

    private func temporaryDefaults() throws -> (UserDefaults, String) {
        let name = "NookTests-FolderSuggestion-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return (defaults, name)
    }

    private func temporaryStore() throws -> (directory: URL, store: MarkdownStore, defaults: UserDefaults) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Nook-FolderFiling-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = MarkdownStore(noteLoader: { _, _ in .success((notes: [], issues: [])) })
        store.storageURL = directory
        store.refreshFolders()
        let (defaults, _) = try temporaryDefaults()
        store.folderPlacements = FolderPlacementMemory(defaults: defaults)
        return (directory, store, defaults)
    }

    private func saved(
        _ title: String, in folder: String? = nil, day: Double, store: MarkdownStore
    ) throws -> MeetingNote {
        let start = Date(timeIntervalSince1970: 1_780_000_000 + day * 86_400)
        let note = try store.save(MeetingNote(
            title: title, startedAt: start, endedAt: start.addingTimeInterval(1_800),
            sourceApp: "Manual", summary: "Synthetic summary."
        ))
        guard let folder else { return note }
        return try store.move(note, toFolder: folder)
    }

    // MARK: - Series

    @Test
    func earlierSittingsFiledInOneFolderSuggestThatFolder() {
        let notes = [
            note("Weekly sync with Ana", in: "Team", day: 0),
            note("Weekly sync with Ana", in: "Team", day: 7),
        ]
        let candidate = note("Weekly sync with Ana", day: 14)

        let result = suggestion(for: candidate, among: notes, folders: ["Team", "Other"])

        #expect(result?.folder == "Team")
        #expect(result?.signal == .series)
        #expect(result?.reason == "Earlier meetings are filed there")
    }

    @Test
    func aClearMajorityOfFiledSittingsIsEnoughButAnEvenSplitIsNot() {
        let majority = [
            note("Roadmap review", in: "Planning", day: 0),
            note("Roadmap review", in: "Planning", day: 7),
            note("Roadmap review", in: "Archive 2025", day: 14),
        ]
        let split = [
            note("Roadmap review", in: "Planning", day: 0),
            note("Roadmap review", in: "Archive 2025", day: 7),
        ]
        let candidate = note("Roadmap review", day: 21)
        let folders = ["Planning", "Archive 2025"]

        #expect(suggestion(for: candidate, among: majority, folders: folders)?.folder == "Planning")
        #expect(suggestion(for: candidate, among: split, folders: folders) == nil)
    }

    @Test
    func placeholderTitlesAreNeverTreatedAsOneSeries() {
        let notes = [
            note("Meeting Thu 7:34 PM", in: "Team", day: 0),
            note("Meeting Mon 9:02 AM", in: "Team", day: 1),
        ]
        let candidate = note("Meeting Wed 2:03 PM", day: 2)

        #expect(suggestion(for: candidate, among: notes, folders: ["Team"]) == nil)
    }

    // MARK: - Folder names

    @Test
    func aFolderNamedForAPersonMatchesATitleThatMentionsThem() {
        let candidate = note("1:1 with Massimo", day: 3)

        let result = suggestion(for: candidate, among: [], folders: ["11 Massimo", "Design reviews"])

        #expect(result?.folder == "11 Massimo")
        #expect(result?.signal == .name)
        #expect(result?.reason == "The title mentions Massimo")
    }

    @Test
    func possessiveFolderNamesMatchOnTheOwnerWithEitherApostrophe() {
        let folders = ["Massimo’s ramblings", "Design reviews"]

        let curly = suggestion(for: note("Budget chat, Massimo", day: 1), among: [], folders: folders)
        let straight = suggestion(
            for: note("Massimo's hiring plan", day: 2), among: [], folders: ["Massimo's ramblings"]
        )

        #expect(curly?.folder == "Massimo’s ramblings")
        #expect(straight?.folder == "Massimo's ramblings")
    }

    @Test
    func aMultiWordFolderNeedsEveryWordAndPluralsReadAsSingular() {
        let folders = ["Design reviews", "Drafts"]

        #expect(suggestion(for: note("Checkout design review", day: 1), among: [], folders: folders)?.folder
            == "Design reviews")
        #expect(suggestion(for: note("Design sync", day: 2), among: [], folders: ["Design reviews"]) == nil)
    }

    @Test
    func aNamedSpeakerMatchesAFolderNamedAfterThem() {
        let candidate = note("Quarterly budget", day: 1, speakers: ["Speaker 1", "Massimo"])

        let result = suggestion(for: candidate, among: [], folders: ["11 Massimo"])

        #expect(result?.folder == "11 Massimo")
        #expect(result?.reason == "Massimo speaks in this meeting")
    }

    @Test
    func twoEquallySpecificFolderNamesAreAmbiguousAndSuggestNothing() {
        let candidate = note("Ana and Leo planning", day: 1)

        #expect(suggestion(for: candidate, among: [], folders: ["Ana", "Leo"]) == nil)
    }

    @Test
    func genericOrNumericFolderNamesNeverMatchByName() {
        #expect(FolderNameKey(folderName: "Notes") == nil)
        #expect(FolderNameKey(folderName: "2024") == nil)
        #expect(suggestion(for: note("Meeting notes for launch", day: 1), among: [], folders: ["Notes", "2024"])
            == nil)
    }

    // MARK: - Similarity

    @Test
    func titlesThatShareAFoldersDistinctiveWordsSuggestIt() {
        let notes = [
            note("Checkout funnel analysis", in: "Growth", day: 0),
            note("Onboarding funnel analysis", in: "Growth", day: 1),
            note("Pricing funnel analysis", in: "Growth", day: 2),
            note("Hiring loop debrief", in: "People", day: 3),
            note("Offsite logistics", day: 4),
        ]
        let candidate = note("Signup funnel analysis", day: 5)

        let result = suggestion(for: candidate, among: notes, folders: ["Growth", "People"])

        #expect(result?.folder == "Growth")
        #expect(result?.signal == .similarity)
        #expect(result?.reason == "Similar to 3 notes there")
    }

    @Test
    func aSingleSharedCommonWordIsTooWeakToSuggest() {
        let notes = [
            note("Launch review", in: "Launches", day: 0),
            note("Budget review", day: 1),
            note("Hiring review", day: 2),
            note("Security review", day: 3),
        ]
        let candidate = note("Accessibility review", day: 4)

        #expect(suggestion(for: candidate, among: notes, folders: ["Launches"]) == nil)
    }

    @Test
    func oneMatchingNoteInAFolderIsNotEnoughSupport() {
        let notes = [
            note("Checkout funnel analysis", in: "Growth", day: 0),
            note("Unrelated quarterly planning", in: "Growth", day: 1),
        ]
        let candidate = note("Signup funnel analysis", day: 5)

        #expect(suggestion(for: candidate, among: notes, folders: ["Growth"]) == nil)
    }

    @Test
    func nothingIsSuggestedWithoutFoldersForFiledNotesOrForDigests() {
        let notes = [
            note("Weekly sync with Ana", in: "Team", day: 0),
            note("Weekly sync with Ana", in: "Team", day: 7),
        ]
        let candidate = note("Weekly sync with Ana", day: 14)
        let digest = note("Weekly sync with Ana", day: 15, kind: .digest)

        #expect(suggestion(for: candidate, among: notes, folders: []) == nil)
        #expect(
            FolderSuggestionIndex(notes: notes + [candidate], folders: ["Team"], libraryURL: library)
                .suggestion(for: candidate, isInFolder: true) == nil
        )
        #expect(suggestion(for: digest, among: notes, folders: ["Team"]) == nil)
    }

    @Test
    func aFolderThatNoLongerExistsIsNeverSuggested() {
        let notes = [
            note("Weekly sync with Ana", in: "Removed", day: 0),
            note("Weekly sync with Ana", in: "Removed", day: 7),
        ]

        #expect(suggestion(for: note("Weekly sync with Ana", day: 14), among: notes, folders: ["Team"]) == nil)
    }

    @Test
    func buildingTheIndexStaysFastForALargeLibrary() {
        let folders = (0..<20).map { "Folder \($0) project" }
        var notes: [MeetingNote] = []
        for index in 0..<3_000 {
            notes.append(note(
                "Topic \(index % 150) planning session \(index)",
                in: index.isMultiple(of: 3) ? folders[index % 20] : nil,
                day: Double(index)
            ))
        }
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            let index = FolderSuggestionIndex(notes: notes, folders: folders, libraryURL: library)
            for candidate in notes.prefix(20) {
                _ = index.suggestion(for: candidate, isInFolder: false)
            }
        }
        #expect(elapsed < .seconds(2))
    }

    // MARK: - Automatic filing rules

    @Test
    func aMeetingWithTwoEarlierSittingsInOneFolderIsFiled() {
        let notes = [
            note("Design weekly", in: "Design reviews", day: 0),
            note("Design weekly", in: "Design reviews", day: 7),
        ]
        let candidate = note("Design weekly", day: 14)
        let index = FolderSuggestionIndex(notes: notes + [candidate], folders: ["Design reviews"], libraryURL: library)

        #expect(index.autoFilingFolder(for: candidate, calendarSaysRecurring: false) == "Design reviews")
    }

    @Test
    func oneEarlierSittingNeedsTheCalendarToSayTheEventRepeats() {
        let notes = [note("Design weekly", in: "Design reviews", day: 0)]
        let candidate = note("Design weekly", day: 7)
        let index = FolderSuggestionIndex(notes: notes + [candidate], folders: ["Design reviews"], libraryURL: library)

        #expect(index.autoFilingFolder(for: candidate, calendarSaysRecurring: false) == nil)
        #expect(index.autoFilingFolder(for: candidate, calendarSaysRecurring: true) == "Design reviews")
        // Not recurring, but still a suggestion.
        #expect(index.suggestion(for: candidate, isInFolder: false)?.folder == "Design reviews")
    }

    @Test
    func aSeriesWhoseLatestSittingIsUnfiledOrElsewhereIsOnlySuggested() {
        let latestAtRoot = [
            note("Design weekly", in: "Design reviews", day: 0),
            note("Design weekly", in: "Design reviews", day: 7),
            note("Design weekly", day: 14),
        ]
        let latestElsewhere = [
            note("Design weekly", in: "Design reviews", day: 0),
            note("Design weekly", in: "Design reviews", day: 7),
            note("Design weekly", in: "Design reviews", day: 14),
            note("Design weekly", in: "Archive", day: 21),
        ]
        let candidate = note("Design weekly", day: 28)
        let folders = ["Design reviews", "Archive"]

        let first = FolderSuggestionIndex(notes: latestAtRoot + [candidate], folders: folders, libraryURL: library)
        let second = FolderSuggestionIndex(notes: latestElsewhere + [candidate], folders: folders, libraryURL: library)

        #expect(first.autoFilingFolder(for: candidate, calendarSaysRecurring: true) == nil)
        #expect(second.autoFilingFolder(for: candidate, calendarSaysRecurring: true) == nil)
    }

    @Test
    func aStrongMajorityWithTheLatestSittingInItIsFiled() {
        let notes = [
            note("Design weekly", in: "Archive", day: 0),
            note("Design weekly", in: "Design reviews", day: 7),
            note("Design weekly", in: "Design reviews", day: 14),
            note("Design weekly", in: "Design reviews", day: 21),
        ]
        let candidate = note("Design weekly", day: 28)
        let index = FolderSuggestionIndex(
            notes: notes + [candidate], folders: ["Design reviews", "Archive"], libraryURL: library
        )

        #expect(index.autoFilingFolder(for: candidate, calendarSaysRecurring: false) == "Design reviews")
    }

    @Test
    func spokenNotesAreNeverFiledAutomatically() {
        let notes = [
            note("Design weekly", in: "Design reviews", day: 0),
            note("Design weekly", in: "Design reviews", day: 7),
        ]
        let candidate = note("Design weekly", day: 14, kind: .spoken)
        let index = FolderSuggestionIndex(notes: notes + [candidate], folders: ["Design reviews"], libraryURL: library)

        #expect(index.autoFilingFolder(for: candidate, calendarSaysRecurring: true) == nil)
    }

    @Test
    func theCalendarVouchesOnlyForARepeatingEventInTheSameSeries() {
        let events = [
            CalendarMeetingEvent(title: "Design weekly", attendeeCount: 3, startDate: .now, isRecurring: false),
            CalendarMeetingEvent(title: "Budget review", attendeeCount: 3, startDate: .now, isRecurring: true),
        ]
        let key = SeriesMatcher.seriesKey(for: "Design weekly")

        #expect(!CalendarContextService.recurringEventMatches(seriesKey: key, among: events))
        #expect(CalendarContextService.recurringEventMatches(
            seriesKey: key,
            among: [CalendarMeetingEvent(title: "Design Weekly", attendeeCount: 3, startDate: .now, isRecurring: true)]
        ))
    }

    // MARK: - Automatic filing in the library

    @Test
    func aNewRecurringMeetingMovesIntoItsSeriesFolderAndCanBeMovedBack() throws {
        let (directory, store, defaults) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.createFolder(named: "11 Massimo")
        _ = try saved("Weekly sync with Massimo", in: "11 Massimo", day: 0, store: store)
        _ = try saved("Weekly sync with Massimo", in: "11 Massimo", day: 7, store: store)
        let new = try saved("Weekly sync with Massimo", day: 14, store: store)
        let filer = FolderAutoFiler(store: store, defaults: defaults)
        let announced = Box<[AutoFiledNote]>([])
        filer.onFiled = { announced.value.append($0) }

        let outcome = filer.attempt(
            noteID: new.id, generation: store.storageGeneration, calendarSaysRecurring: false
        )

        guard case .filed(let filing) = outcome else {
            Issue.record("Expected the meeting to be filed, got \(outcome)")
            return
        }
        let moved = try #require(store.uniqueNote(id: new.id))
        #expect(store.folderName(of: moved) == "11 Massimo")
        #expect(FileManager.default.fileExists(atPath: try #require(moved.fileURL).path))
        #expect(filing.notice == "Filed in 11 Massimo with earlier meetings")
        #expect(announced.value == [filing])
        #expect(store.lastAutoFiling == filing)

        // Undo: the library's ordinary move back, remembered as the
        // person's own placement.
        let restored = try store.move(moved, toFolder: nil)
        store.folderPlacements.markUserPlaced([restored.id])
        #expect(store.folderName(of: restored) == nil)
        #expect(filer.attempt(
            noteID: new.id, generation: store.storageGeneration, calendarSaysRecurring: true
        ) == .notEligible)
        let index = FolderSuggestionIndex(notes: store.notes, folders: store.folders, libraryURL: directory)
        #expect(index.offeredSuggestion(
            for: restored, isInFolder: false, isBusy: false, placements: store.folderPlacements
        ) == nil)
    }

    @Test
    func aBusyNoteIsNotMovedUntilItsWriterFinishes() async throws {
        let (directory, store, defaults) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.createFolder(named: "Design reviews")
        _ = try saved("Design weekly", in: "Design reviews", day: 0, store: store)
        _ = try saved("Design weekly", in: "Design reviews", day: 7, store: store)
        let new = try saved("Design weekly", day: 14, store: store)
        // Busy for the first two checks, as a Quick Note still writing to
        // the file would be, then free.
        let checks = Box(0)
        store.isNoteBusy = { _ in
            checks.value += 1
            return checks.value < 3
        }
        let filer = FolderAutoFiler(store: store, defaults: defaults)
        filer.retryDelay = .milliseconds(10)

        #expect(filer.attempt(
            noteID: new.id, generation: store.storageGeneration, calendarSaysRecurring: false
        ) == .busy)
        #expect(store.folderName(of: try #require(store.uniqueNote(id: new.id))) == nil)

        await filer.newMeetingSaved(new, after: nil).value

        #expect(store.folderName(of: try #require(store.uniqueNote(id: new.id))) == "Design reviews")
    }

    @Test
    func unsavedEditsForTheNoteHoldTheMoveAndGivingUpLeavesItWhereItIs() async throws {
        let (directory, store, defaults) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.createFolder(named: "Design reviews")
        _ = try saved("Design weekly", in: "Design reviews", day: 0, store: store)
        _ = try saved("Design weekly", in: "Design reviews", day: 7, store: store)
        let new = try saved("Design weekly", day: 14, store: store)
        let filer = FolderAutoFiler(store: store, defaults: defaults)
        filer.retryDelay = .milliseconds(5)
        filer.maximumAttempts = 3
        filer.hasUnsavedEdits = { $0.id == new.id }

        await filer.newMeetingSaved(new, after: nil).value

        let current = try #require(store.uniqueNote(id: new.id))
        #expect(store.folderName(of: current) == nil)
        // Still at the root, so the library offers the move instead.
        let index = FolderSuggestionIndex(notes: store.notes, folders: store.folders, libraryURL: directory)
        #expect(index.offeredSuggestion(
            for: current, isInFolder: false, isBusy: false, placements: store.folderPlacements
        )?.folder == "Design reviews")
    }

    @Test
    func turningTheSettingOffLeavesRecurringMeetingsWithASuggestion() throws {
        let (directory, store, defaults) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        defaults.set(false, forKey: AutoFilingPreference.key)
        try store.createFolder(named: "Design reviews")
        _ = try saved("Design weekly", in: "Design reviews", day: 0, store: store)
        _ = try saved("Design weekly", in: "Design reviews", day: 7, store: store)
        let new = try saved("Design weekly", day: 14, store: store)
        let filer = FolderAutoFiler(store: store, defaults: defaults)

        #expect(filer.attempt(
            noteID: new.id, generation: store.storageGeneration, calendarSaysRecurring: true
        ) == .notEligible)
        #expect(store.folderName(of: try #require(store.uniqueNote(id: new.id))) == nil)
        let index = FolderSuggestionIndex(notes: store.notes, folders: store.folders, libraryURL: directory)
        #expect(index.suggestion(for: new, isInFolder: false)?.signal == .series)
    }

    @Test
    func theSettingDefaultsToOn() throws {
        let (defaults, _) = try temporaryDefaults()
        #expect(AutoFilingPreference.isEnabled(in: defaults))
    }

    @Test
    func notesAlreadyInAFolderOrPlacedByHandAreNeverFiled() throws {
        let (directory, store, defaults) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.createFolder(named: "Design reviews")
        try store.createFolder(named: "Mine")
        _ = try saved("Design weekly", in: "Design reviews", day: 0, store: store)
        _ = try saved("Design weekly", in: "Design reviews", day: 7, store: store)
        let filedByHand = try saved("Design weekly", in: "Mine", day: 14, store: store)
        let placedAtRoot = try saved("Design weekly", day: 15, store: store)
        store.folderPlacements.markUserPlaced([placedAtRoot.id])
        let filer = FolderAutoFiler(store: store, defaults: defaults)

        #expect(filer.attempt(
            noteID: filedByHand.id, generation: store.storageGeneration, calendarSaysRecurring: true
        ) == .notEligible)
        #expect(filer.attempt(
            noteID: placedAtRoot.id, generation: store.storageGeneration, calendarSaysRecurring: true
        ) == .notEligible)
        #expect(store.folderName(of: try #require(store.uniqueNote(id: filedByHand.id))) == "Mine")
        #expect(store.folderName(of: try #require(store.uniqueNote(id: placedAtRoot.id))) == nil)
    }

    @Test
    func aChangedLibraryCancelsAPendingFiling() throws {
        let (directory, store, defaults) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.createFolder(named: "Design reviews")
        _ = try saved("Design weekly", in: "Design reviews", day: 0, store: store)
        _ = try saved("Design weekly", in: "Design reviews", day: 7, store: store)
        let new = try saved("Design weekly", day: 14, store: store)
        let filer = FolderAutoFiler(store: store, defaults: defaults)

        #expect(filer.attempt(
            noteID: new.id, generation: store.storageGeneration + 1, calendarSaysRecurring: true
        ) == .notEligible)
    }

    // MARK: - Remembering choices

    @Test
    func aDismissedSuggestionStaysDismissedAcrossLaunches() throws {
        let (defaults, _) = try temporaryDefaults()
        let notes = [
            note("Design weekly", in: "Design reviews", day: 0),
            note("Design weekly", in: "Design reviews", day: 7),
        ]
        let candidate = note("Design weekly", day: 14)
        let index = FolderSuggestionIndex(notes: notes + [candidate], folders: ["Design reviews"], libraryURL: library)
        let memory = FolderPlacementMemory(defaults: defaults)
        #expect(index.offeredSuggestion(for: candidate, isInFolder: false, isBusy: false, placements: memory) != nil)

        memory.dismissSuggestion(for: candidate.id)
        let relaunched = FolderPlacementMemory(defaults: defaults)

        #expect(relaunched.isDismissed(candidate.id))
        #expect(index.offeredSuggestion(for: candidate, isInFolder: false, isBusy: false, placements: relaunched) == nil)
        // Another note's suggestion is unaffected.
        let other = note("Design weekly", day: 21)
        #expect(!relaunched.isDismissed(other.id))
    }

    @Test
    func noSuggestionIsOfferedWhileTheNoteIsBusy() throws {
        let (defaults, _) = try temporaryDefaults()
        let candidate = note("1:1 with Massimo", day: 1)
        let index = FolderSuggestionIndex(notes: [candidate], folders: ["11 Massimo"], libraryURL: library)

        #expect(index.offeredSuggestion(
            for: candidate, isInFolder: false, isBusy: true, placements: FolderPlacementMemory(defaults: defaults)
        ) == nil)
    }

    @Test
    func rememberedIDsAreCapped() throws {
        let (defaults, _) = try temporaryDefaults()
        let memory = FolderPlacementMemory(defaults: defaults)
        let first = UUID()
        memory.dismissSuggestion(for: first)
        for _ in 0..<FolderPlacementMemory.capacity { memory.dismissSuggestion(for: UUID()) }

        #expect(!FolderPlacementMemory(defaults: defaults).isDismissed(first))
        #expect(defaults.stringArray(forKey: FolderPlacementMemory.Keys.dismissed)?.count
            == FolderPlacementMemory.capacity)
    }

    // MARK: - Notice

    @Test
    func aNoticeWithUndoStaysLongEnoughToReachTheButton() {
        var state = CopyNoticeState()
        state.show("Moved", severity: .success)
        let plain = state.current?.expirationDelay
        state.show(
            "Filed in 11 Massimo with earlier meetings",
            severity: .success,
            action: NoticeAction(title: "Undo", accessibilityLabel: "Undo filing") {}
        )

        #expect(plain == 1.8)
        #expect(state.current?.expirationDelay == 10)
        #expect(state.current?.action?.title == "Undo")
    }
}

@MainActor
private final class Box<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}
