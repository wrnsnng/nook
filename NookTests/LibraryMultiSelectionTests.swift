import Foundation
import Testing
@testable import Nook

/// Selecting several notes at once, as in Finder and Mail. These pin how the
/// sidebar's proposed rows become a selection, that the unsaved-edit guard
/// still stands between an editor and a multi-selection, and that bulk moves
/// and deletions report partial failure instead of hiding it.
@MainActor
struct LibraryMultiSelectionTests {
    private func identity(_ name: String) -> LibraryNoteIdentity {
        LibraryNoteIdentity(noteID: UUID(), fileURL: URL(fileURLWithPath: "/tmp/Nook/\(name).md"))
    }

    private func temporaryStore(
        fileManager: FileManager = TrashFileManager()
    ) throws -> (directory: URL, store: MarkdownStore) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Nook-MultiSelect-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = MarkdownStore(
            fileManager: fileManager,
            noteLoader: { _, _ in .success((notes: [], issues: [])) }
        )
        store.storageURL = directory
        store.refreshFolders()
        return (directory, store)
    }

    private func note(_ title: String, minutes: Double = 0) -> MeetingNote {
        let start = Date(timeIntervalSince1970: 1_780_000_000 + minutes * 60)
        return MeetingNote(
            title: title,
            startedAt: start,
            endedAt: start.addingTimeInterval(1_800),
            sourceApp: "Manual",
            summary: "Synthetic summary for \(title)."
        )
    }

    // MARK: - Selection model

    @Test
    func oneSelectedNoteIsAnOrdinarySelectionAndTwoAreAMultiSelection() {
        let a = identity("a"), b = identity("b")
        #expect(LibrarySelection.forNotes([LibraryNoteIdentity]()) == nil)
        #expect(LibrarySelection.forNotes([a]) == .note(a))
        #expect(LibrarySelection.forNotes([a, a]) == .note(a))
        #expect(LibrarySelection.forNotes([a, b]) == .notes([a, b]))
        #expect(LibrarySelection.forNotes([a, b])?.isMultipleNotes == true)
    }

    @Test
    func shiftClickExtendsTheSelectionToTheWholeRange() {
        let a = identity("a"), b = identity("b"), c = identity("c")
        let extended = LibrarySelection.fromList(
            [.note(a), .note(b), .note(c)], replacing: .note(a)
        )
        #expect(extended == .notes([a, b, c]))
        #expect(LibrarySelection.listRows(for: extended) == [.note(a), .note(b), .note(c)])
    }

    @Test
    func commandClickTogglesOneNoteInAndOutOfTheSelection() {
        let a = identity("a"), b = identity("b"), c = identity("c")
        let three: LibrarySelection = .notes([a, b, c])
        #expect(LibrarySelection.fromList([.note(a), .note(c)], replacing: three) == .notes([a, c]))
        // Toggling down to one note is an ordinary selection again, so the
        // detail shows that note as it always has.
        #expect(LibrarySelection.fromList([.note(c)], replacing: .notes([a, c])) == .note(c))
        #expect(LibrarySelection.fromList([], replacing: .note(c)) == nil)
    }

    @Test
    func choosingTheLiveOrPrepRowClearsAMultiSelection() {
        let a = identity("a"), b = identity("b")
        let many: LibrarySelection = .notes([a, b])
        #expect(LibrarySelection.fromList([.live], replacing: many) == .live)
        // Command-click adds the row to the proposal; it still replaces the
        // notes rather than joining them.
        #expect(LibrarySelection.fromList([.note(a), .note(b), .prep], replacing: many) == .prep)
    }

    @Test
    func selectAllAndRangesAcrossStandingRowsKeepOnlyNotes() {
        let a = identity("a"), b = identity("b"), c = identity("c")
        // Select All proposes every tagged row, standing rows included.
        let all: Set<LibrarySelection> = [.live, .prep, .note(a), .note(b), .note(c)]
        #expect(LibrarySelection.fromList(all, replacing: .note(a)) == .notes([a, b, c]))
        // A Shift-click range from the live row down into the notes.
        #expect(
            LibrarySelection.fromList([.live, .note(a), .note(b)], replacing: .live)
                == .notes([a, b])
        )
    }

    @Test
    func aScopeChangeKeepsTheSelectedNotesItStillShows() {
        let a = identity("a"), b = identity("b"), c = identity("c")
        let selection: LibrarySelection = .notes([a, b, c])
        #expect(selection.restricted(to: [a, c, identity("d")]) == .notes([a, c]))
        #expect(selection.restricted(to: [b]) == .note(b))
        #expect(selection.restricted(to: [identity("e")]) == nil)
    }

    @Test
    func aMultiSelectionFollowsMovedFilesAndDropsDeletedNotes() {
        let a = identity("a"), b = identity("b"), c = identity("c")
        let movedB = LibraryNoteIdentity(
            noteID: b.noteID, fileURL: URL(fileURLWithPath: "/tmp/Nook/Team/b.md")
        )
        let selection: LibrarySelection = .notes([a, b, c])
        let followed = selection.following(present: [a, movedB]) { id in
            id == b.noteID ? movedB : nil
        }
        #expect(followed == .notes([a, movedB]))
        #expect(selection.following(present: [a]) { _ in nil } == .note(a))
        #expect(selection.applyingMoves([a: movedB]) == .notes([movedB, b, c]))
        #expect(LibrarySelection.note(a).applyingMoves([a: movedB]) == .note(movedB))
    }

    @Test
    func aRowsMenuActsOnTheWholeSelectionOnlyWhenTheRowIsPartOfIt() {
        let a = identity("a"), b = identity("b"), c = identity("c")
        let selection: LibrarySelection = .notes([a, b])
        #expect(selection.contextTargets(for: a) == [a, b])
        #expect(selection.contextTargets(for: c) == [c])
        #expect(LibrarySelection.note(a).contextTargets(for: a) == [a])
        #expect(LibrarySelection.live.contextTargets(for: a) == [a])
    }

    @Test
    func leavingAnEditedNoteForAMultiSelectionStillAsksFirst() {
        let a = identity("a"), b = identity("b")
        func decide(_ from: LibrarySelection?, _ to: LibrarySelection?, markdown: Bool, notes: Bool) -> UnsavedEditDecision? {
            LibraryLeaveGuard.decide(
                from: from, to: to, isConfirmingMarkdown: false,
                hasMarkdownChanges: markdown, hasPersonalNotesChanges: notes
            )
        }
        #expect(decide(.note(a), .notes([a, b]), markdown: true, notes: false) == .askAboutMarkdown)
        #expect(decide(.note(a), .notes([a, b]), markdown: false, notes: true) == .saveFirst)
        #expect(decide(.note(a), .notes([a, b]), markdown: false, notes: false) == .leave)
        // An unanswered question keeps its destination.
        #expect(LibraryLeaveGuard.decide(
            from: .note(a), to: .notes([a, b]), isConfirmingMarkdown: true,
            hasMarkdownChanges: true, hasPersonalNotesChanges: false
        ) == nil)
    }

    // MARK: - Drag payload

    @Test
    func aDraggedMultiSelectionCarriesEveryNoteAndIgnoresForeignLines() {
        let a = identity("a"), b = identity("b")
        let payload = LibraryNoteDrag.payload(for: [a, b])
        #expect(LibraryNoteDrag.identities(from: [payload]) == [a, b])
        #expect(LibraryNoteDrag.identities(from: [payload, LibraryNoteDrag.payload(for: a)]) == [a, b])
        let mixed = "Just some text\n" + LibraryNoteDrag.payload(for: b) + "\nnook-note:not-a-uuid:/x.md"
        #expect(LibraryNoteDrag.identities(from: [mixed]) == [b])
        // The single-note form is unchanged.
        #expect(LibraryNoteDrag.identity(from: LibraryNoteDrag.payload(for: a)) == a)
    }

    // MARK: - Bulk actions

    @Test
    func movingSeveralNotesMovesEachAndSaysSoOnce() throws {
        let (directory, store) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.createFolder(named: "Team")
        let first = try store.save(note("Planning"))
        let second = try store.save(note("Retro", minutes: 5))
        let already = try store.move(try store.save(note("Standup", minutes: 10)), toFolder: "Team")

        let outcome = LibraryBulkNoteAction.move(
            [first.libraryIdentity, second.libraryIdentity, already.libraryIdentity],
            toFolder: "Team", store: store
        )

        #expect(outcome.moved.count == 2)
        #expect(outcome.alreadyThere == 1)
        #expect(outcome.failures.isEmpty)
        #expect(store.notes.allSatisfy { store.folderName(of: $0) == "Team" })
        let moved = try #require(outcome.moved[first.libraryIdentity])
        #expect(store.note(matching: moved)?.id == first.id)
        let notice = LibraryBulkNoteAction.moveNotice(outcome, toFolder: "Team")
        #expect(notice.message == "Moved 2 notes to Team")
        #expect(!notice.isFailure)
    }

    @Test
    func aBulkMoveReportsTheNoteThatCouldNotMoveAndMovesTheRest() throws {
        let (directory, store) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.createFolder(named: "Team")
        let first = try store.save(note("Planning"))
        let busy = try store.save(note("Summarising", minutes: 5))
        let third = try store.save(note("Retro", minutes: 10))
        store.isNoteBusy = { $0 == busy.libraryIdentity }

        let outcome = LibraryBulkNoteAction.move(
            [first.libraryIdentity, busy.libraryIdentity, third.libraryIdentity],
            toFolder: "Team", store: store
        )

        #expect(outcome.moved.count == 2)
        #expect(outcome.failures == [LibraryBulkNoteAction.Failure(
            title: "Summarising",
            reason: LibraryFolderError.noteIsBusy.localizedDescription
        )])
        #expect(store.note(matching: busy.libraryIdentity) != nil)
        #expect(FileManager.default.fileExists(atPath: try #require(busy.fileURL).path))
        let notice = LibraryBulkNoteAction.moveNotice(outcome, toFolder: "Team")
        #expect(notice.isFailure)
        #expect(notice.message.hasPrefix("Moved 2 of 3 notes to Team. “Summarising” wasn’t moved."))
        #expect(!notice.message.contains("\u{2014}"))

        let nothing = LibraryBulkNoteAction.MoveOutcome(
            total: 2,
            failures: [.init(title: "A", reason: "Gone."), .init(title: "B", reason: "Gone.")]
        )
        #expect(LibraryBulkNoteAction.moveNotice(nothing, toFolder: nil).message
            == "No notes were moved. Gone.")
    }

    @Test
    func trashingSeveralNotesTrashesEachAndKeepsTheOneTheTrashRefused() throws {
        let fileManager = TrashFileManager()
        let (directory, store) = try temporaryStore(fileManager: fileManager)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try store.save(note("Planning"))
        let kept = try store.save(note("Keep me", minutes: 5))
        let third = try store.save(note("Retro", minutes: 10))
        let keptFile = try #require(kept.fileURL)
        fileManager.refusedURL = keptFile

        let outcome = LibraryBulkNoteAction.delete(
            [first.libraryIdentity, kept.libraryIdentity, third.libraryIdentity], store: store
        )

        #expect(outcome.deleted == [first.libraryIdentity, third.libraryIdentity])
        #expect(outcome.failures.map(\.title) == ["Keep me"])
        #expect(fileManager.trashedURLs.count == 2)
        #expect(store.notes.map(\.id) == [kept.id])
        #expect(FileManager.default.fileExists(atPath: keptFile.path))
        // A later success must not erase the refusal from the library status.
        #expect(store.lastError?.contains("Trash") == true)
        let notice = LibraryBulkNoteAction.deleteNotice(outcome)
        #expect(notice.isFailure)
        #expect(notice.message.hasPrefix("Moved 2 of 3 notes to the Trash. Couldn’t move"))

        let clean = LibraryBulkNoteAction.DeleteOutcome(
            total: 2, deleted: [first.libraryIdentity, third.libraryIdentity]
        )
        #expect(LibraryBulkNoteAction.deleteNotice(clean).message == "Moved 2 notes to the Trash")
    }

    @Test
    func theMultiSelectionCopyNamesTheCountWithoutDashes() {
        #expect(LibraryBulkCopy.selectedTitle(3) == "3 Notes Selected")
        #expect(LibraryBulkCopy.trashTitle(3) == "Move 3 notes to the Trash?")
        #expect(LibraryBulkCopy.titleSummary(["A", "B"]) == "“A” and “B”")
        #expect(LibraryBulkCopy.titleSummary(["A", "B", "C", "D"]) == "“A”, “B” and 2 more")
        for text in [
            LibraryBulkCopy.trashMessage, LibraryBulkCopy.mergeMessage(target: "Planning"),
        ] {
            #expect(!text.contains("\u{2014}"))
        }
    }
}

/// Models the Trash without touching the developer's real one, and refuses
/// one chosen file the way an unavailable Trash would.
private final class TrashFileManager: FileManager {
    struct TrashUnavailable: LocalizedError {
        var errorDescription: String? { "The Trash is not available." }
    }

    var refusedURL: URL?
    private(set) var trashedURLs: [URL] = []

    override func trashItem(
        at url: URL,
        resultingItemURL: AutoreleasingUnsafeMutablePointer<NSURL?>?
    ) throws {
        if url.standardizedFileURL == refusedURL?.standardizedFileURL {
            throw TrashUnavailable()
        }
        trashedURLs.append(url)
        try removeItem(at: url)
    }
}
