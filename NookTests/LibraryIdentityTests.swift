import Combine
import Foundation
import Testing
@testable import Nook

@MainActor
struct LibraryIdentityTests {
    private func temporaryStore() throws -> (directory: URL, store: MarkdownStore) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Nook-Library-Publication-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = MarkdownStore(noteLoader: { _, _ in .success((notes: [], issues: [])) })
        store.storageURL = directory
        return (directory, store)
    }

    private func savedCopies(in store: MarkdownStore, directory: URL) throws -> [MeetingNote] {
        try copies().enumerated().map { index, original in
            var note = original
            note.fileURL = directory.appendingPathComponent("copy-\(index).md")
            note.fileRevision = nil
            return try store.save(note)
        }
    }

    private func copies() -> [MeetingNote] {
        let id = UUID()
        let first = MeetingNote(
            id: id, title: "First copy", startedAt: Date(timeIntervalSince1970: 1_780_000_000),
            endedAt: Date(timeIntervalSince1970: 1_780_000_060), sourceApp: "Synthetic",
            summary: "Orchid belongs to the first file.", fileURL: URL(fileURLWithPath: "/synthetic/first.md"),
            fileModified: Date(timeIntervalSince1970: 1_780_000_000),
            fileRevision: MeetingNote.contentRevision(Data("first revision".utf8))
        )
        var second = first
        second.title = "Second copy"
        second.summary = "Cobalt belongs to the second file."
        second.fileURL = URL(fileURLWithPath: "/synthetic/second.md")
        second.fileRevision = MeetingNote.contentRevision(Data("second revision".utf8))
        return [first, second]
    }

    @Test
    func copiedUUIDsKeepDistinctRowAndNavigationIdentitiesWithoutChangingDocuments() {
        let notes = copies()
        #expect(notes[0].id == notes[1].id)
        #expect(Set(notes.map(\.libraryIdentity)).count == 2)
        #expect(notes[0].libraryIdentity.navigationKey != notes[1].libraryIdentity.navigationKey)
        #expect(LibraryNoteResolution.resolve(notes[0].id, in: notes) == .ambiguous)
        #expect(LibraryNoteResolution.resolve(notes[0].id, in: Array(notes.reversed())) == .ambiguous)
        #expect(LibraryNoteResolution.resolve(notes[0].id, in: [notes[1]]) == .unique(notes[1].libraryIdentity))
        #expect(LibraryNoteResolution.resolve(UUID(), in: notes) == .missing)
    }

    @Test
    func searchingForOneCopyDoesNotIncludeItsSiblingWithTheSameUUID() {
        let notes = copies()
        let hits = LibrarySearchController.matches(query: "Cobalt", notes: notes)
        let filtered = LibraryNoteGrouping.filter(notes, range: .all, matchingIDs: hits)
        #expect(filtered.map(\.libraryIdentity) == [notes[1].libraryIdentity])
        #expect(filtered.first?.summary == "Cobalt belongs to the second file.")
    }

    @Test
    func aSameTimestampRevisionOrFileMoveRefreshesTheCachedLibraryRows() {
        let notes = copies()
        let now = Date(timeIntervalSince1970: 1_780_000_100)
        let original = LibraryGroupingCacheKey(notes: notes, matchingIDs: nil, range: .all, now: now)
        var changed = notes
        changed[0].summary = "A newly saved summary."
        changed[0].fileRevision = MeetingNote.contentRevision(Data("new bytes".utf8))
        #expect(original != LibraryGroupingCacheKey(notes: changed, matchingIDs: nil, range: .all, now: now))
        changed = notes
        changed[0].fileURL = URL(fileURLWithPath: "/synthetic/renamed.md")
        #expect(original != LibraryGroupingCacheKey(notes: changed, matchingIDs: nil, range: .all, now: now))
    }

    @Test
    func fileSpecificLookupStillReturnsTheRequestedCopyAfterReloadReordersTheLibrary() async throws {
        let notes = copies()
        let store = MarkdownStore(noteLoader: { _, _ in .success((notes: Array(notes.reversed()), issues: [])) })
        for _ in 0..<100 where store.isLoading {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!store.isLoading)
        #expect(store.duplicateNoteIDs == [notes[0].id])
        #expect(store.uniqueNote(id: notes[0].id) == nil)
        #expect(store.note(matching: notes[0].libraryIdentity)?.summary == notes[0].summary)
        #expect(store.note(matching: notes[1].libraryIdentity)?.summary == notes[1].summary)
    }

    @Test
    func navigationFollowsSavingRenamingAndClearingTheNotesFileAddress() {
        var note = copies()[0]
        let revision = note.fileRevision
        let markdown = MarkdownCodec.encode(note)
        note.fileURL = nil
        #expect(note.libraryIdentity == LibraryNoteIdentity(noteID: note.id, fileURL: nil))

        for path in ["/synthetic/drafts/../saved note.md", "/synthetic/renamed note.md"] {
            let address = URL(fileURLWithPath: path)
            note.fileURL = address
            #expect(note.fileURL?.absoluteString.utf8.elementsEqual(address.absoluteString.utf8) == true)
            #expect(note.libraryIdentity == LibraryNoteIdentity(noteID: note.id, fileURL: address))
            #expect(note.fileRevision == revision)
            #expect(MarkdownCodec.encode(note).utf8.elementsEqual(markdown.utf8))
        }

        note.fileURL = nil
        #expect(note.libraryIdentity.filePath == nil)
        #expect(note.libraryIdentity.navigationKey == "\(note.id.uuidString):unsaved")
        #expect(note.fileRevision == revision)
    }

    @Test
    func optionalURLWritebackChangesOnlyTheEditedCopiesNavigationAddress() {
        let original = copies()[0]
        let originalIdentity = original.libraryIdentity
        var edited = original
        edited.fileURL?.deleteLastPathComponent()
        edited.fileURL?.appendPathComponent("new folder/renamed.md", isDirectory: false)

        #expect(edited.libraryIdentity == LibraryNoteIdentity(noteID: edited.id, fileURL: edited.fileURL))
        #expect(edited.libraryIdentity != originalIdentity)
        #expect(original.libraryIdentity == originalIdentity)
        #expect(original.fileURL?.lastPathComponent == "first.md")
        #expect(edited.fileRevision == original.fileRevision)

        let replacement = URL(fileURLWithPath: "/synthetic/reloaded.md")
        edited[keyPath: \MeetingNote.fileURL] = replacement
        #expect(edited.libraryIdentity == LibraryNoteIdentity(noteID: edited.id, fileURL: replacement))
        func rename(_ address: inout URL?) {
            address?.deleteLastPathComponent()
            address?.appendPathComponent("renamed through inout.md", isDirectory: false)
        }
        rename(&edited.fileURL)
        #expect(edited.libraryIdentity == LibraryNoteIdentity(noteID: edited.id, fileURL: edited.fileURL))
        #expect(edited.libraryIdentity.fileURL?.lastPathComponent == "renamed through inout.md")

        edited.fileURL = nil
        edited.fileURL?.appendPathComponent("must not create a file.md", isDirectory: false)
        #expect(edited.fileURL == nil)
        #expect(edited.libraryIdentity.filePath == nil)
    }

    @Test
    func capturedIdentitiesMatchFoundationNormalizationWithoutReplacingOriginalURLs() {
        let paths = [
            "/synthetic/notes/folder/../weekly review.md",
            "/synthetic/notes/Caf\u{00E9}.md",
            "/synthetic/notes/Cafe\u{0301}.md",
            "/synthetic/notes/\u{4F1A}\u{8B70} \u{1F331}.md",
            "/synthetic/notes/100% #1?.md",
        ]
        let original = copies()[0]
        for path in paths {
            let native = URL(fileURLWithPath: path, isDirectory: false)
            let bridged = NSURL(fileURLWithPath: path, isDirectory: false) as URL
            for address in [native, bridged] {
                let initialized = MeetingNote(
                    id: original.id, title: original.title,
                    startedAt: original.startedAt, endedAt: original.endedAt,
                    sourceApp: original.sourceApp, summary: original.summary,
                    fileURL: address
                )
                var assigned = original
                assigned.fileURL = address
                let expected = LibraryNoteIdentity(noteID: original.id, fileURL: address)
                for note in [initialized, assigned] {
                    #expect(note.libraryIdentity == expected)
                    #expect(note.libraryIdentity.filePath?.utf8.elementsEqual(
                        address.standardizedFileURL.path.utf8
                    ) == true)
                    #expect(note.fileURL?.absoluteString.utf8.elementsEqual(
                        address.absoluteString.utf8
                    ) == true)
                }
            }
        }
    }

    @Test
    func noteEqualityAndHashingKeepOriginalURLSemanticsAfterIdentityCaching() {
        let original = copies()[0]
        let addresses: [URL?] = [
            nil,
            URL(fileURLWithPath: "/synthetic/notes/meeting.md"),
            NSURL(fileURLWithPath: "/synthetic/notes/meeting.md") as URL,
            URL(fileURLWithPath: "/synthetic/notes/./meeting.md"),
            URL(fileURLWithPath: "/synthetic/notes/other.md"),
            URL(fileURLWithPath: "/synthetic/notes/Caf\u{00E9}.md"),
            URL(fileURLWithPath: "/synthetic/notes/Cafe\u{0301}.md"),
        ]
        for leftAddress in addresses {
            for rightAddress in addresses {
                var left = original
                var right = original
                left.fileURL = leftAddress
                right.fileURL = rightAddress
                let equal = leftAddress == rightAddress
                #expect((left == right) == equal)
                #expect(Set([left, right]).count == (equal ? 1 : 2))
                if equal { #expect(left.hashValue == right.hashValue) }
            }
        }
    }

    @Test
    func assigningAnEqualAddressKeepsTheSameNoteAsInitializingIt() {
        let original = copies()[0]
        var reassigned = original
        reassigned.fileURL = original.fileURL
        #expect(reassigned == original)
        #expect(reassigned.hashValue == original.hashValue)
        #expect(reassigned.libraryIdentity == original.libraryIdentity)

        var changedContent = reassigned
        changedContent.summary = "The saved words changed at the same address."
        changedContent.fileRevision = MeetingNote.contentRevision(Data("changed source bytes".utf8))
        #expect(changedContent != original)
        #expect(changedContent.libraryIdentity == original.libraryIdentity)
    }

    @Test
    func filesystemChangesKeepTheCapturedIdentityUntilItsAddressIsAssignedAgain() throws {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory
            .appendingPathComponent("Nook-Library-Identity-\(UUID().uuidString)", isDirectory: true)
        defer { try? manager.removeItem(at: directory) }
        let first = directory.appendingPathComponent("first/nested", isDirectory: true)
        let second = directory.appendingPathComponent("second/nested", isDirectory: true)
        try manager.createDirectory(at: first, withIntermediateDirectories: true)
        try manager.createDirectory(at: second, withIntermediateDirectories: true)
        let link = directory.appendingPathComponent("current", isDirectory: true)
        try manager.createSymbolicLink(at: link, withDestinationURL: first)
        let address = NSURL(fileURLWithPath: link.path + "/../meeting.md", isDirectory: false) as URL
        var note = copies()[0]
        note.fileURL = address
        let captured = note
        let capturedIdentity = note.libraryIdentity

        try manager.removeItem(at: link)
        try manager.createSymbolicLink(at: link, withDestinationURL: second)
        #expect(note.libraryIdentity == capturedIdentity)
        #expect(note.fileURL?.absoluteString.utf8.elementsEqual(address.absoluteString.utf8) == true)

        // Foundation's normalized spelling can depend on the OS and filesystem.
        // The contract is when to capture it, not a particular symlink spelling.
        let refreshed = LibraryNoteIdentity(noteID: note.id, fileURL: address)
        note.fileURL = address
        #expect(note.libraryIdentity == refreshed)
        #expect(note == captured)
        #expect(note.hashValue == captured.hashValue)
    }

    @Test
    func aNewNoteEntersPublishedRecentNotesInItsFinalPosition() throws {
        let (directory, store) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stamp = Date(timeIntervalSince1970: 1_780_000_000)
        for offset in 0..<5 {
            _ = try store.save(MeetingNote(
                title: "Earlier \(offset)", startedAt: stamp.addingTimeInterval(Double(offset) * 60),
                endedAt: stamp.addingTimeInterval(Double(offset + 1) * 60),
                sourceApp: "Synthetic", summary: "Existing synthetic note."
            ))
        }
        var publications: [[MeetingNote]] = []
        let observation = store.$notes.dropFirst().sink { publications.append($0) }
        defer { observation.cancel() }

        let newest = try store.save(MeetingNote(
            title: "Newest note", startedAt: stamp.addingTimeInterval(600),
            endedAt: stamp.addingTimeInterval(660), sourceApp: "Synthetic",
            summary: "A newly saved synthetic note."
        ))

        #expect(publications.count == 1)
        let published = try #require(publications.first)
        #expect(published.prefix(5).map(\.title) == ["Newest note", "Earlier 4", "Earlier 3", "Earlier 2", "Earlier 1"])
        #expect(published.map(\.libraryIdentity) == store.notes.map(\.libraryIdentity))
        #expect(published.first?.fileRevision == newest.fileRevision)
        let bytes = try Data(contentsOf: #require(newest.fileURL))
        #expect(newest.fileRevision == MeetingNote.contentRevision(bytes))
    }

    @Test
    func updatingOneCopyPublishesItsExactRevisionWithoutChangingItsSibling() throws {
        let (directory, store) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let saved = try savedCopies(in: store, directory: directory)
        var selected = saved[1]
        selected.summary = "Caf\u{00E9} review."
        selected = try store.save(selected)
        let siblingBytes = try Data(contentsOf: #require(saved[0].fileURL))
        let order = store.notes.map(\.libraryIdentity)
        var publications: [[MeetingNote]] = []
        let observation = store.$notes.dropFirst().sink { publications.append($0) }
        defer { observation.cancel() }

        var edited = selected
        edited.summary = "Cafe\u{0301} review."
        let updated = try store.save(edited)

        #expect(publications.count == 1)
        let published = try #require(publications.first)
        #expect(published.map(\.libraryIdentity) == order)
        let publishedCopy = try #require(published.first { $0.libraryIdentity == selected.libraryIdentity })
        #expect(publishedCopy.summary.utf8.elementsEqual(edited.summary.utf8))
        #expect(publishedCopy.fileRevision == updated.fileRevision)
        #expect(publishedCopy.fileRevision != selected.fileRevision)
        #expect(store.duplicateNoteIDs == [selected.id])
        #expect(store.uniqueNote(id: selected.id) == nil)
        #expect(try Data(contentsOf: #require(saved[0].fileURL)) == siblingBytes)
        #expect(store.note(matching: saved[0].libraryIdentity)?.summary == saved[0].summary)
    }

    @Test
    func renamingOneCopyPublishesOnlyItsNewAddressAndKeepsTheOtherCopy() throws {
        let (directory, store) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let saved = try savedCopies(in: store, directory: directory)
        let original = saved[0]
        let oldURL = try #require(original.fileURL)
        let originalBytes = try Data(contentsOf: oldURL)
        let siblingBytes = try Data(contentsOf: #require(saved[1].fileURL))
        let originalOrder = store.notes.map(\.libraryIdentity)
        var publications: [[MeetingNote]] = []
        let observation = store.$notes.dropFirst().sink { publications.append($0) }
        defer { observation.cancel() }

        let renamed = try store.renameManagedFile(for: original)

        #expect(publications.count == 1)
        let published = try #require(publications.first)
        #expect(renamed.libraryIdentity != original.libraryIdentity)
        #expect(published.map(\.libraryIdentity) == originalOrder.map {
            $0 == original.libraryIdentity ? renamed.libraryIdentity : $0
        })
        #expect(store.note(matching: original.libraryIdentity) == nil)
        #expect(store.note(matching: renamed.libraryIdentity)?.fileRevision == original.fileRevision)
        #expect(store.duplicateNoteIDs == [original.id])
        #expect(!FileManager.default.fileExists(atPath: oldURL.path))
        #expect(try Data(contentsOf: #require(renamed.fileURL)) == originalBytes)
        #expect(try Data(contentsOf: #require(saved[1].fileURL)) == siblingBytes)
    }
}
