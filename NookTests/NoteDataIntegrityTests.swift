import Foundation
import Testing
@testable import Nook

/// Saving a note rebuilds its whole file from a model, so anything the model
/// forgets is deleted from disk. These are the things it used to forget.
struct NoteFidelityTests {
    private static func temporaryDirectory(
        _ label: String
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Nook\(label)-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }

    @MainActor
    private static func store(in directory: URL) -> MarkdownStore {
        let store = MarkdownStore(noteLoader: { _, _ in
            .success((notes: [], issues: []))
        })
        store.storageURL = directory
        return store
    }

    private static let meetingWithTickedActions = """
    ---
    id: 6C0A2D6E-2F81-4C2B-9E4B-7C1D0A5F3B22
    kind: meeting
    title: "Launch review"
    started: 2026-07-30T09:00:00Z
    ended: 2026-07-30T10:00:00Z
    source: "Zoom"
    ---

    # Launch review

    ## Summary

    The team agreed on the launch scope.

    ## Key points

    - Beta starts next week

    ## Decisions

    - Keep the onboarding short

    ## Action items

    - [x] Publish the checklist [due: 2026-09-12]
    - [ ] Draft the announcement
    - [x] Book the room

    ## My notes

    Ask about legal review.

    ## Transcript

    - **[00:12]** **Meeting:** Welcome everyone.
    """

    @Test
    @MainActor
    func renamingANoteKeepsItsTickedItemsAndDueDates() throws {
        let directory = try Self.temporaryDirectory("Rename")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("launch-review.md")
        try Self.meetingWithTickedActions.write(
            to: file,
            atomically: true,
            encoding: .utf8
        )

        var note = try #require(
            MarkdownCodec.decode(Self.meetingWithTickedActions, fileURL: file)
        )
        #expect(note.completedActionItems.contains(
            "Publish the checklist [due: 2026-09-12]"
        ))

        let store = Self.store(in: directory)
        note.title = "Launch review, final"
        _ = try store.save(note)

        let written = try String(contentsOf: file, encoding: .utf8)
        #expect(written.contains(
            "- [x] Publish the checklist [due: 2026-09-12]"
        ))
        #expect(written.contains("- [ ] Draft the announcement"))
        #expect(written.contains("- [x] Book the room"))
        #expect(written.contains("title: \"Launch review, final\""))
    }

    @Test
    func actionItemsSectionSurvivesEveryReEncoding() throws {
        let first = try #require(
            MarkdownCodec.decode(Self.meetingWithTickedActions)
        )
        let reEncoded = MarkdownCodec.encode(first)
        let second = try #require(MarkdownCodec.decode(reEncoded))

        #expect(second.actionItems == first.actionItems)
        #expect(second.completedActionItems == first.completedActionItems)
        #expect(MarkdownCodec.encode(second) == reEncoded)
        #expect(
            MarkdownCodec.section("Action items", in: reEncoded)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                == """
                - [x] Publish the checklist [due: 2026-09-12]
                - [ ] Draft the announcement
                - [x] Book the room
                """
        )
    }

    private static let meetingWithUserWriting = """
    ---
    id: 1D2E3F40-5A6B-4C7D-8E9F-0A1B2C3D4E5F
    kind: meeting
    title: "Roadmap"
    started: 2026-07-30T09:00:00Z
    ended: 2026-07-30T10:00:00Z
    source: "Zoom"
    ---

    # Roadmap

    ## Summary

    We walked the roadmap.

    ### Not a section

    ## Open questions

    Who owns pricing?

    ## Key points

    Written before the list, by hand.

    - Ship in October

    ## Decisions

    - Hold the date

    ## Action items

    - [ ] Confirm the date

    ## Agenda

    1. Pricing
    2. Hiring

    ## My notes

    Nothing yet.

    ## Transcript

    - **[00:05]** Hello.
    """

    @Test
    func aUserSubheadingInsideSummaryIsNotTreatedAsTheEndOfIt() throws {
        let decoded = try #require(
            MarkdownCodec.decode(Self.meetingWithUserWriting)
        )

        #expect(decoded.summary.contains("### Not a section"))
        #expect(decoded.summary.contains("## Open questions"))
        #expect(decoded.summary.contains("Who owns pricing?"))
        #expect(decoded.keyPoints == ["Ship in October"])
    }

    @Test
    func handWrittenSectionsAndLooseLinesSurviveAWholeNoteSave() throws {
        let decoded = try #require(
            MarkdownCodec.decode(Self.meetingWithUserWriting)
        )
        let reEncoded = MarkdownCodec.encode(decoded)

        #expect(reEncoded.contains("## Agenda"))
        #expect(reEncoded.contains("1. Pricing"))
        #expect(reEncoded.contains("2. Hiring"))
        #expect(reEncoded.contains("Written before the list, by hand."))
        #expect(reEncoded.contains("## Open questions"))

        // Stable from the second encoding on, so repeated saves cannot
        // duplicate or erode what was preserved.
        let second = try #require(MarkdownCodec.decode(reEncoded))
        #expect(MarkdownCodec.encode(second) == reEncoded)
    }

    @Test
    func aPreservedSectionStaysAttachedToTheHeadingItFollowed() throws {
        let decoded = try #require(
            MarkdownCodec.decode(Self.meetingWithUserWriting)
        )
        let reEncoded = MarkdownCodec.encode(decoded)
        let agenda = try #require(reEncoded.range(of: "## Agenda"))
        let actions = try #require(reEncoded.range(of: "## Action items"))
        let myNotes = try #require(reEncoded.range(of: "## My notes"))

        #expect(actions.lowerBound < agenda.lowerBound)
        #expect(agenda.lowerBound < myNotes.lowerBound)
    }

    @Test
    func aNoteWithoutHandWritingEncodesExactlyAsItAlwaysDid() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let note = MeetingNote(
            id: UUID(uuidString: "C417A77A-6D3D-42E0-A4E8-D96A715C4E65")!,
            title: "Product sync",
            startedAt: start,
            endedAt: start.addingTimeInterval(1_800),
            sourceApp: "Teams",
            summary: "The team agreed on the launch scope.",
            keyPoints: ["Beta starts next week"],
            decisions: ["Keep the onboarding short"],
            actionItems: ["Publish the checklist"],
            personalNotes: "Ask Sam about legal."
        )

        #expect(MarkdownCodec.encode(note) == """
        ---
        id: C417A77A-6D3D-42E0-A4E8-D96A715C4E65
        kind: meeting
        title: "Product sync"
        started: \(ISO8601DateFormatter().string(from: start))
        ended: \(ISO8601DateFormatter().string(from: start.addingTimeInterval(1_800)))
        source: "Teams"
        ---

        # Product sync

        ## Summary

        The team agreed on the launch scope.

        ## Key points

        - Beta starts next week

        ## Decisions

        - Keep the onboarding short

        ## Action items

        - [ ] Publish the checklist

        ## My notes

        Ask Sam about legal.

        ## Transcript

        _No speech was detected._
        """)
    }
}

/// A spoken note is title then prose. People delete that title line by hand,
/// and a decoder that needs it read their words as nothing.
struct SpokenNoteBodyTests {
    private static let spokenWithoutHeading = """
    ---
    id: 0B4E7C1A-9D2F-4A3B-8C5E-1F6A7B8C9D0E
    kind: spoken
    title: "Ideas for the talk"
    started: 2026-07-30T09:00:00Z
    ended: 2026-07-30T09:01:00Z
    source: "Spoken note"
    ---

    Open with the demo, then the numbers.

    - [x] Book the room
    """

    @Test
    func aSpokenNoteWhoseHeadingWasDeletedStillDecodesItsWords() throws {
        let decoded = try #require(
            MarkdownCodec.decode(Self.spokenWithoutHeading)
        )

        #expect(decoded.summary == """
        Open with the demo, then the numbers.

        - [x] Book the room
        """)
    }

    @Test
    @MainActor
    func savingAfterADecodeGapCannotEmptyTheFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "NookEmptyGuard-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("ideas.md")
        try Self.spokenWithoutHeading.write(
            to: file,
            atomically: true,
            encoding: .utf8
        )
        let store = MarkdownStore(noteLoader: { _, _ in
            .success((notes: [], issues: []))
        })
        store.storageURL = directory

        // The words the decoder found are saved back intact.
        let decoded = try #require(
            MarkdownCodec.decode(Self.spokenWithoutHeading, fileURL: file)
        )
        _ = try store.save(decoded)
        var written = try String(contentsOf: file, encoding: .utf8)
        #expect(written.contains("Open with the demo, then the numbers."))
        #expect(written.contains("- [x] Book the room"))

        // A model that lost the body is refused rather than written.
        var hollow = decoded
        hollow.summary = ""
        var thrown: Error?
        do {
            _ = try store.save(hollow)
        } catch {
            thrown = error
        }
        #expect(thrown as? MarkdownStoreError == .wouldEmptyNote)
        written = try String(contentsOf: file, encoding: .utf8)
        #expect(written.contains("Open with the demo, then the numbers."))
        #expect(store.lastError != nil)
    }

    @Test
    @MainActor
    func clearingTheOnlyNotesATemplateHasIsAnEditAndNotAGap() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "NookEmptyGuard-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = MarkdownStore(noteLoader: { _, _ in
            .success((notes: [], issues: []))
        })
        store.storageURL = directory

        // A blank template has no summary, no items, and no transcript, so its
        // personal notes are the only content it will ever have.
        let note = try store.createTemplatedNote(from: .blank)
        let written = try store.updatePersonalNotes(
            "A thought I typed here.",
            for: note
        )

        // Select all, delete. The user meant it.
        let cleared = try store.updatePersonalNotes("", for: written)

        #expect(cleared.personalNotes.isEmpty)
        let onDisk = try String(
            contentsOf: try #require(cleared.fileURL),
            encoding: .utf8
        )
        #expect(!onDisk.contains("A thought I typed here."))
        #expect(store.lastError == nil)
    }
}

/// One note belongs in one file. Deriving the destination from the title again
/// on every save is what let hands-free capture scatter a single thought.
struct NoteDestinationTests {
    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "NookDestination-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }

    private static func markdownFiles(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "md" }
    }

    @Test
    @MainActor
    func savingTheSameNoteUnderANewTitleWritesOneFile() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MarkdownStore(noteLoader: { _, _ in
            .success((notes: [], issues: []))
        })
        store.storageURL = directory

        let id = UUID()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try store.save(
            MeetingNote(
                id: id,
                kind: .spoken,
                title: "Remember to",
                startedAt: start,
                endedAt: start,
                sourceApp: "Spoken note",
                summary: "Remember to"
            )
        )
        // A caller that forgot the URL still cannot fork the note.
        _ = try store.save(
            MeetingNote(
                id: id,
                kind: .spoken,
                title: "Remember to call the venue back",
                startedAt: start,
                endedAt: start,
                sourceApp: "Spoken note",
                summary: "Remember to call the venue back"
            )
        )

        let files = try Self.markdownFiles(in: directory)
        #expect(files.count == 1)
        let written = try String(contentsOf: try #require(files.first), encoding: .utf8)
        #expect(written.contains("Remember to call the venue back"))
    }

    @Test
    @MainActor
    func handsFreeCaptureKeepsGrowingOneNoteInOneFile() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MarkdownStore(noteLoader: { _, _ in
            .success((notes: [], issues: []))
        })
        store.storageURL = directory
        let controller = QuickNoteController(store: store)

        controller.text = "Book the venue for the offsite."
        let first = try #require(controller.saveIfNeeded())
        controller.text += " Then confirm the catering numbers."
        let second = try #require(controller.saveIfNeeded())
        controller.text += " And send the invitations on Monday."
        let third = try #require(controller.saveIfNeeded())

        let files = try Self.markdownFiles(in: directory)
        #expect(first.id == third.id)
        #expect(first.fileURL == second.fileURL)
        #expect(second.fileURL == third.fileURL)
        #expect(files.count == 1)
    }

    @Test
    @MainActor
    func explicitlyRenamingAFileUsesTheCurrentTitleAndPreservesItsContent() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MarkdownStore(noteLoader: { _, _ in
            .success((notes: [], issues: []))
        })
        store.storageURL = directory

        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let original = try store.save(
            MeetingNote(
                title: "Planning",
                startedAt: start,
                endedAt: start.addingTimeInterval(60),
                sourceApp: "Manual",
                summary: "Keep this content.",
                actionItems: ["Send the recap"]
            )
        )
        let source = try #require(original.fileURL)
        let before = try String(contentsOf: source, encoding: .utf8)
        var titled = original
        titled.title = "Planning / Final"

        let renamed = try store.renameManagedFile(for: titled)
        let destination = try #require(renamed.fileURL)

        #expect(destination != source)
        #expect(destination.lastPathComponent.hasSuffix("-planning-final.md"))
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect(try String(contentsOf: destination, encoding: .utf8) == before)
        #expect(renamed.id == original.id)
        #expect(renamed.title == titled.title)
        #expect(store.notes.first(where: { $0.id == original.id })?.fileURL == destination)

        // A second explicit request is a no-op at the same destination.
        let repeated = try store.renameManagedFile(for: renamed)
        #expect(repeated.fileURL == destination)
        #expect(try Self.markdownFiles(in: directory).count == 1)
    }

    @Test
    @MainActor
    func explicitlyRenamingAroundAnOccupiedNameNeverOverwritesTheOtherFile() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MarkdownStore(noteLoader: { _, _ in
            .success((notes: [], issues: []))
        })
        store.storageURL = directory

        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let original = try store.save(
            MeetingNote(
                title: "Planning",
                startedAt: start,
                endedAt: start.addingTimeInterval(60),
                sourceApp: "Manual",
                summary: "Original content."
            )
        )
        let occupied = try store.save(
            MeetingNote(
                title: "Planning Final",
                startedAt: start,
                endedAt: start.addingTimeInterval(60),
                sourceApp: "Manual",
                summary: "Keep the other note here."
            )
        )
        let occupiedURL = try #require(occupied.fileURL)
        let occupiedBefore = try String(contentsOf: occupiedURL, encoding: .utf8)
        var titled = original
        titled.title = "Planning Final"

        let renamed = try store.renameManagedFile(for: titled)
        let destination = try #require(renamed.fileURL)

        #expect(destination != occupiedURL)
        #expect(destination.lastPathComponent.contains(
            String(original.id.uuidString.prefix(8)).lowercased()
        ))
        #expect(FileManager.default.fileExists(atPath: occupiedURL.path))
        #expect(try String(contentsOf: occupiedURL, encoding: .utf8) == occupiedBefore)
        #expect(try String(contentsOf: destination, encoding: .utf8).contains("Original content."))
    }

    @Test
    @MainActor
    func explicitlyRenamingAnExternallyChangedFileLeavesItInPlace() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MarkdownStore(noteLoader: { _, _ in
            .success((notes: [], issues: []))
        })
        store.storageURL = directory

        let original = try store.save(
            MeetingNote(
                title: "Pricing",
                startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                endedAt: Date(timeIntervalSince1970: 1_700_000_060),
                sourceApp: "Manual",
                summary: "Nook wrote this."
            )
        )
        let source = try #require(original.fileURL)
        let elsewhere = try String(contentsOf: source, encoding: .utf8)
            .replacingOccurrences(
                of: "Nook wrote this.",
                with: "A person wrote this instead."
            )
        try elsewhere.write(to: source, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(120)],
            ofItemAtPath: source.path
        )

        var titled = original
        titled.title = "Pricing, revisited"
        var thrown: Error?
        do {
            _ = try store.renameManagedFile(for: titled)
        } catch {
            thrown = error
        }

        #expect(thrown as? MarkdownStoreError == .fileChangedElsewhere)
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(try String(contentsOf: source, encoding: .utf8).contains("A person wrote this instead."))
        #expect(try Self.markdownFiles(in: directory).count == 1)
        #expect(store.notes.first(where: { $0.id == original.id })?.fileURL == source)
    }
}

/// Nook is not the only writer of these files, and a whole-note save replaces
/// every byte. An edit made elsewhere has to stop it.
struct ExternalEditTests {
    @Test
    @MainActor
    func anEditMadeOutsideNookIsReloadedRatherThanOverwritten() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "NookExternalEdit-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = MarkdownStore(noteLoader: { _, _ in
            .success((notes: [], issues: []))
        })
        store.storageURL = directory

        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var saved = try store.save(
            MeetingNote(
                title: "Pricing",
                startedAt: start,
                endedAt: start,
                sourceApp: "Zoom",
                summary: "Nook wrote this."
            )
        )
        let file = try #require(saved.fileURL)

        // Somebody else edits the file after Nook last read it.
        let elsewhere = try String(contentsOf: file, encoding: .utf8)
            .replacingOccurrences(
                of: "Nook wrote this.",
                with: "A person wrote this instead."
            )
        try elsewhere.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(120)],
            ofItemAtPath: file.path
        )

        saved.title = "Pricing, revisited"
        var thrown: Error?
        do {
            _ = try store.save(saved)
        } catch {
            thrown = error
        }
        #expect(thrown as? MarkdownStoreError == .fileChangedElsewhere)

        let onDisk = try String(contentsOf: file, encoding: .utf8)
        #expect(onDisk.contains("A person wrote this instead."))
        #expect(store.lastError != nil)
    }

    @Test
    @MainActor
    func ourOwnConsecutiveSavesAreNeverMistakenForSomebodyElse() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "NookConsecutive-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = MarkdownStore(noteLoader: { _, _ in
            .success((notes: [], issues: []))
        })
        store.storageURL = directory

        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var note = try store.save(
            MeetingNote(
                title: "Standup",
                startedAt: start,
                endedAt: start,
                sourceApp: "Zoom",
                summary: "One"
            )
        )
        for word in ["Two", "Three", "Four"] {
            note.summary = word
            note = try store.save(note)
        }

        let written = try String(
            contentsOf: try #require(note.fileURL),
            encoding: .utf8
        )
        #expect(written.contains("Four"))
        #expect(store.lastError == nil)
    }
}

/// A failure message that describes the wrong outcome is its own defect: it
/// tells somebody their file is safe at the moment it was rewritten.
struct SaveFailureCopyTests {
    @Test
    @MainActor
    func aRoundTripFailureLeavesTheFileUntouchedAsItSays() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "NookNotesCopy-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = MarkdownStore(noteLoader: { _, _ in
            .success((notes: [], issues: []))
        })
        store.storageURL = directory

        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let saved = try store.save(
            MeetingNote(
                title: "Retro",
                startedAt: start,
                endedAt: start,
                sourceApp: "Zoom",
                summary: "We talked.",
                personalNotes: "Keep this."
            )
        )
        let file = try #require(saved.fileURL)
        let before = try String(contentsOf: file, encoding: .utf8)

        // The placeholder is how an empty field is written, so it cannot also
        // be stored as somebody's text. That is a round-trip the note fails.
        var thrown: Error?
        do {
            _ = try store.updatePersonalNotes("_No personal notes._", for: saved)
        } catch {
            thrown = error
        }
        #expect(thrown as? MarkdownStoreError == .writeVerificationFailed)
        #expect(try String(contentsOf: file, encoding: .utf8) == before)
    }

    @Test
    func onlyTheUntouchedFailureClaimsTheFileWasUntouched() {
        #expect(
            MarkdownStoreError.writeVerificationFailed.errorDescription?
                .contains("left untouched") == true
        )
        #expect(
            MarkdownStoreError.saveReadBackFailed.errorDescription?
                .contains("untouched") == false
        )
    }
}

private final class TrashRejectingFileManager: FileManager {
    struct TrashUnavailable: Error {}

    override func trashItem(
        at url: URL,
        resultingItemURL: AutoreleasingUnsafeMutablePointer<NSURL?>?
    ) throws {
        throw TrashUnavailable()
    }
}

private final class TrashRecordingFileManager: FileManager {
    private(set) var trashedURLs: [URL] = []

    override func trashItem(
        at url: URL,
        resultingItemURL: AutoreleasingUnsafeMutablePointer<NSURL?>?
    ) throws {
        trashedURLs.append(url)
        // Tests model a successful reversible move without touching the
        // developer's real Trash.
        try removeItem(at: url)
    }
}

struct NoteDeletionSafetyTests {
    @Test
    @MainActor
    func deletingUsesTrashBeforeRemovingTheLibraryEntry() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "NookDeleteSuccess-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileManager = TrashRecordingFileManager()
        let store = MarkdownStore(
            fileManager: fileManager,
            noteLoader: { _, _ in
                .success((notes: [], issues: []))
            }
        )
        store.storageURL = directory
        let note = try store.save(
            MeetingNote(
                title: "Trash this note",
                startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                endedAt: Date(timeIntervalSince1970: 1_700_000_060),
                sourceApp: "Manual",
                summary: "This deletion is reversible in production."
            )
        )
        let file = try #require(note.fileURL)

        #expect(store.delete(note))
        #expect(fileManager.trashedURLs == [file])
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(!store.notes.contains { $0.id == note.id })
        #expect(store.lastError == nil)
    }

    @Test
    @MainActor
    func deletingWithNoTrashLeavesTheFileAndLibraryEntryIntact() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "NookDeleteSafety-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = MarkdownStore(
            fileManager: TrashRejectingFileManager(),
            noteLoader: { _, _ in
                .success((notes: [], issues: []))
            }
        )
        store.storageURL = directory
        let note = try store.save(
            MeetingNote(
                title: "Keep this note",
                startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                endedAt: Date(timeIntervalSince1970: 1_700_000_060),
                sourceApp: "Manual",
                summary: "The file must remain recoverable."
            )
        )
        let file = try #require(note.fileURL)
        let before = try Data(contentsOf: file)

        #expect(!store.delete(note))
        #expect(store.notes.contains { $0.id == note.id })
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(try Data(contentsOf: file) == before)
        #expect(store.lastError?.contains("Trash") == true)
    }
}
