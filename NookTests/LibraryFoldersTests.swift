import Foundation
import Testing
@testable import Nook

/// Folders are real directories inside the notes folder. These pin that the
/// library loads them, that Nook's folder actions change the disk the way
/// Finder would, and that a moved note is still the same note.
@MainActor
struct LibraryFoldersTests {
    private func temporaryStore() throws -> (directory: URL, store: MarkdownStore) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Nook-Folders-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = MarkdownStore(noteLoader: { _, _ in .success((notes: [], issues: [])) })
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

    private func write(_ note: MeetingNote, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(MarkdownCodec.encode(note).utf8).write(to: url)
    }

    private func loaded(_ directory: URL) throws -> [MeetingNote] {
        try MarkdownStore.loadNotes(in: directory).get().notes
    }

    // MARK: - Loading

    @Test
    func theLibraryLoadsNotesFromItsRootAndFromEachFolderOneLevelDown() throws {
        let (directory, _) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = note("Planning")
        let oneOnOne = note("1:1 with Massimo", minutes: 10)
        let nested = note("Too deep", minutes: 20)
        try write(root, to: directory.appendingPathComponent("planning.md"))
        try write(oneOnOne, to: directory.appendingPathComponent("Massimo/one-on-one.md"))
        try write(nested, to: directory.appendingPathComponent("Massimo/Archive/deep.md"))

        let notes = try loaded(directory)

        #expect(Set(notes.map(\.id)) == [root.id, oneOnOne.id])
        let massimo = try #require(notes.first { $0.id == oneOnOne.id })
        #expect(LibraryFolders.folderName(of: try #require(massimo.fileURL), in: directory) == "Massimo")
        let planning = try #require(notes.first { $0.id == root.id })
        #expect(LibraryFolders.folderName(of: try #require(planning.fileURL), in: directory) == nil)
    }

    @Test
    func nooksOwnHiddenAndLinkedDirectoriesAreNeverFolders() throws {
        let (directory, store) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileManager = FileManager.default
        let recorded = note("Recording sidecar")
        let hidden = note("Hidden")
        try write(recorded, to: store.recordingsDirectory().appendingPathComponent("stray.md"))
        try write(hidden, to: directory.appendingPathComponent(".private/hidden.md"))
        let outside = fileManager.temporaryDirectory
            .appendingPathComponent("Nook-Folders-Outside-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: outside) }
        try write(note("Linked"), to: outside.appendingPathComponent("linked.md"))
        try fileManager.createSymbolicLink(
            at: directory.appendingPathComponent("Linked"), withDestinationURL: outside
        )
        try fileManager.createDirectory(
            at: directory.appendingPathComponent("Made in Finder"), withIntermediateDirectories: false
        )

        store.refreshFolders()

        #expect(store.folders == ["Made in Finder"])
        #expect(try loaded(directory).isEmpty)
        #expect(!LibraryFolders.isFolderName(".recordings"))
        #expect(!LibraryFolders.isFolderName(".RECORDINGS"))
    }

    // MARK: - Creating, renaming and deleting folders

    @Test
    func creatingAFolderMakesARealDirectoryWithATrimmedName() throws {
        let (directory, store) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let name = try store.createFolder(named: "  Massimo \n")

        var isDirectory: ObjCBool = false
        #expect(name == "Massimo")
        #expect(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("Massimo").path, isDirectory: &isDirectory
        ))
        #expect(isDirectory.boolValue)
        #expect(store.folders == ["Massimo"])
    }

    @Test
    func unsafeAndDuplicateFolderNamesAreRefusedWithoutTouchingTheDisk() throws {
        let (directory, store) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.createFolder(named: "Massimo")

        #expect(throws: LibraryFolderError.duplicateName("Massimo")) {
            try store.createFolder(named: "massimo")
        }
        #expect(throws: LibraryFolderError.nameContainsSeparator) {
            try store.createFolder(named: "Team/Massimo")
        }
        #expect(throws: LibraryFolderError.hiddenName) {
            try store.createFolder(named: ".recordings")
        }
        #expect(throws: LibraryFolderError.emptyName) {
            try store.createFolder(named: "   ")
        }
        let entries = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(entries == ["Massimo"])
    }

    @Test
    func renamingAFolderRenamesItsDirectoryAndItsNotesFollow() throws {
        let (directory, store) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.createFolder(named: "Massimo")
        let saved = try store.save(note("Weekly 1:1"))
        let moved = try store.move(saved, toFolder: "Massimo")
        let bytes = try Data(contentsOf: try #require(moved.fileURL))

        let newName = try store.renameFolder("Massimo", to: "Massimo one-on-ones")

        #expect(newName == "Massimo one-on-ones")
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("Massimo").path))
        let current = try #require(store.uniqueNote(id: saved.id))
        let file = try #require(current.fileURL)
        #expect(file.deletingLastPathComponent().lastPathComponent == "Massimo one-on-ones")
        #expect(try Data(contentsOf: file) == bytes)
        #expect(store.folders == ["Massimo one-on-ones"])
        #expect(try loaded(directory).map(\.id) == [saved.id])
    }

    @Test
    func aFolderCanChangeOnlyTheCaseOfItsName() throws {
        let (directory, store) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.createFolder(named: "massimo")

        #expect(try store.renameFolder("massimo", to: "Massimo") == "Massimo")
        #expect(store.folders == ["Massimo"])
    }

    @Test
    func renamingOntoAnotherFolderIsRefused() throws {
        let (directory, store) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.createFolder(named: "Massimo")
        try store.createFolder(named: "Team")

        #expect(throws: LibraryFolderError.duplicateName("Team")) {
            try store.renameFolder("Massimo", to: "TEAM")
        }
        #expect(store.folders == ["Massimo", "Team"])
    }

    @Test
    func deletingAFolderMovesItsNotesBackToTheLibraryAndNeverDeletesThem() throws {
        let (directory, store) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.createFolder(named: "Massimo")
        let first = try store.move(try store.save(note("First 1:1")), toFolder: "Massimo")
        let second = try store.move(try store.save(note("Second 1:1", minutes: 30)), toFolder: "Massimo")

        try store.deleteFolder("Massimo")

        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("Massimo").path))
        #expect(store.folders.isEmpty)
        let reloaded = try loaded(directory)
        #expect(Set(reloaded.map(\.id)) == [first.id, second.id])
        #expect(reloaded.allSatisfy {
            $0.fileURL?.deletingLastPathComponent().standardizedFileURL.path
                == directory.standardizedFileURL.path
        })
    }

    @Test
    func aFolderHoldingOtherFilesIsKeptAfterItsNotesMoveOut() throws {
        let (directory, store) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.createFolder(named: "Massimo")
        let saved = try store.move(try store.save(note("1:1")), toFolder: "Massimo")
        let attachment = directory.appendingPathComponent("Massimo/agenda.pdf")
        try Data("synthetic".utf8).write(to: attachment)

        #expect(throws: LibraryFolderError.folderKeptOtherFiles("Massimo")) {
            try store.deleteFolder("Massimo")
        }
        #expect(FileManager.default.fileExists(atPath: attachment.path))
        #expect(store.folders == ["Massimo"])
        #expect(store.folderName(of: try #require(store.uniqueNote(id: saved.id))) == nil)
    }

    // MARK: - Moving notes

    @Test
    func movingANoteMovesItsFileAndKeepsItsIDAndBytes() throws {
        let (directory, store) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.createFolder(named: "Massimo")
        let saved = try store.save(note("Weekly 1:1"))
        let source = try #require(saved.fileURL)
        let bytes = try Data(contentsOf: source)

        let moved = try store.move(saved, toFolder: "Massimo")

        let destination = try #require(moved.fileURL)
        #expect(moved.id == saved.id)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(destination.lastPathComponent == source.lastPathComponent)
        #expect(destination.deletingLastPathComponent().lastPathComponent == "Massimo")
        #expect(try Data(contentsOf: destination) == bytes)
        #expect(moved.fileRevision == saved.fileRevision)
        #expect(store.notes.count == 1)
        #expect(store.note(matching: moved.libraryIdentity) != nil)
        #expect(store.note(matching: saved.libraryIdentity) == nil)

        // A moved note can still be saved in place, and moved back.
        var edited = moved
        edited.summary = "Edited after the move."
        let resaved = try store.save(edited)
        #expect(resaved.fileURL == destination)
        let back = try store.move(resaved, toFolder: nil)
        #expect(back.fileURL?.deletingLastPathComponent().standardizedFileURL.path
            == directory.standardizedFileURL.path)
        #expect(store.folderName(of: back) == nil)
    }

    @Test
    func aNameAlreadyTakenInTheFolderGetsASuffixAndTheOtherFileIsUntouched() throws {
        let (directory, store) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.createFolder(named: "Massimo")
        let saved = try store.save(note("Weekly 1:1"))
        let source = try #require(saved.fileURL)
        let occupied = directory.appendingPathComponent("Massimo/\(source.lastPathComponent)")
        let other = note("Another note that happens to share the filename")
        try write(other, to: occupied)
        let otherBytes = try Data(contentsOf: occupied)

        let moved = try store.move(saved, toFolder: "Massimo")

        let destination = try #require(moved.fileURL)
        #expect(destination != occupied)
        #expect(destination.deletingLastPathComponent().lastPathComponent == "Massimo")
        #expect(destination.lastPathComponent.contains(saved.id.uuidString.prefix(8).lowercased()))
        #expect(try Data(contentsOf: occupied) == otherBytes)
        #expect(moved.id == saved.id)
    }

    @Test
    func aNoteEditedOutsideNookIsNotMoved() throws {
        let (directory, store) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.createFolder(named: "Massimo")
        let saved = try store.save(note("Weekly 1:1"))
        let source = try #require(saved.fileURL)
        try (try String(contentsOf: source, encoding: .utf8) + "\nAn edit made in another app.\n")
            .write(to: source, atomically: true, encoding: .utf8)

        #expect(throws: MarkdownStoreError.fileChangedElsewhere) {
            try store.move(saved, toFolder: "Massimo")
        }
        #expect(FileManager.default.fileExists(atPath: source.path))
        let folder = directory.appendingPathComponent("Massimo")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    @Test
    func aNoteSomethingIsStillWritingToIsNotMoved() throws {
        let (directory, store) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.createFolder(named: "Massimo")
        let saved = try store.save(note("Receiving a recording"))
        store.isNoteBusy = { $0 == saved.libraryIdentity }

        #expect(throws: LibraryFolderError.noteIsBusy) {
            try store.move(saved, toFolder: "Massimo")
        }
        #expect(FileManager.default.fileExists(atPath: try #require(saved.fileURL).path))
    }

    @Test
    func aNewNoteCanBeCreatedDirectlyInAFolder() throws {
        let (directory, store) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.createFolder(named: "Massimo")

        let created = try store.createTemplatedNote(from: .oneOnOne, inFolder: "Massimo")

        #expect(store.folderName(of: created) == "Massimo")
        #expect(try loaded(directory).map(\.id) == [created.id])
    }

    @Test
    func renamingANotesFileKeepsItInItsFolder() throws {
        let (directory, store) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.createFolder(named: "Massimo")
        var moved = try store.move(try store.save(note("Weekly")), toFolder: "Massimo")
        moved.title = "Weekly with Massimo"

        let renamed = try store.renameManagedFile(for: moved)

        #expect(store.folderName(of: renamed) == "Massimo")
        #expect(renamed.fileURL?.lastPathComponent.hasSuffix("-weekly-with-massimo.md") == true)
    }

    // MARK: - Everything keyed by a file's address

    @Test
    func notesInFoldersBelongToTheLibraryForOwnershipChecks() throws {
        let (directory, store) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.createFolder(named: "Massimo")
        let moved = try store.move(try store.save(note("Weekly")), toFolder: "Massimo")
        let file = try #require(moved.fileURL)

        #expect(LibraryFolders.contains(file, in: directory))
        #expect(LibrarySheetOwnership.matchesCurrentFolder([moved], directoryURL: directory))
        #expect(MeetingCoordinator.attachedRecordingTarget(
            expected: moved.libraryIdentity, notes: store.notes, libraryURL: directory
        )?.id == moved.id)
        try store.validateMergeSource(moved, directory: directory, generation: store.storageGeneration)

        // Two levels down is outside the library, as the loader sees it.
        let deep = directory.appendingPathComponent("Massimo/Archive/deep.md")
        #expect(!LibraryFolders.contains(deep, in: directory))
        #expect(!LibraryFolders.contains(
            directory.appendingPathComponent(".recordings/x.md"), in: directory
        ))
    }

    @Test
    func keptAudioIsFoundAtTheLibraryRootForANoteInAFolder() throws {
        let (directory, store) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.createFolder(named: "Massimo")
        let moved = try store.move(try store.save(note("Recorded 1:1")), toFolder: "Massimo")
        let audio = store.recordingsDirectory().appendingPathComponent("\(moved.id.uuidString).m4a")
        try Data().write(to: audio)

        #expect(AudioPlaybackController.audioURL(for: moved, libraryURL: directory)?.path == audio.path)
        // Without the library, a folder's own directory has no kept audio.
        #expect(AudioPlaybackController.audioURL(for: moved) == nil)
    }

    @Test
    func theNoteListCanBeNarrowedToOneFolder() throws {
        let (directory, store) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.createFolder(named: "Massimo")
        let root = try store.save(note("Planning"))
        let moved = try store.move(try store.save(note("1:1", minutes: 5)), toFolder: "Massimo")

        let all = LibraryNoteGrouping.filter(
            store.notes, range: .all, matchingIDs: nil, folder: .all, libraryURL: directory
        )
        let massimo = LibraryNoteGrouping.filter(
            store.notes, range: .all, matchingIDs: nil, folder: .folder("Massimo"), libraryURL: directory
        )

        #expect(Set(all.map(\.id)) == [root.id, moved.id])
        #expect(massimo.map(\.id) == [moved.id])
        #expect(LibraryNoteGrouping.folderCounts(store.notes, libraryURL: directory) == ["Massimo": 1])
        #expect(LibraryNoteDrag.identity(from: LibraryNoteDrag.payload(for: moved)) == moved.libraryIdentity)
        #expect(LibraryNoteDrag.identity(from: "Just some dragged text") == nil)
    }

    @Test
    func aFolderChangeWaitsForTheUnsavedEditDecisionLikeTheDateRange() {
        var scope = LibraryScopeState()
        scope.requestFolder(.folder("Massimo"), needsConfirmation: true)
        #expect(scope.folder == .all)
        #expect(scope.hasPendingChange)
        scope.settle(confirmed: false)
        #expect(scope.folder == .all)

        scope.requestFolder(.folder("Massimo"), needsConfirmation: true)
        scope.settle(confirmed: true)
        #expect(scope.folder == .folder("Massimo"))

        scope.folderWasRenamed(from: "Massimo", to: "Massimo 1:1s")
        #expect(scope.folder == .folder("Massimo 1:1s"))
        scope.keepOnlyFolders(["Team"])
        #expect(scope.folder == .all)
    }
}
