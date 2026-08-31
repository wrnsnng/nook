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
        let saved = try store.save(decoded)
        var written = try String(contentsOf: file, encoding: .utf8)
        #expect(written.contains("Open with the demo, then the numbers."))
        #expect(written.contains("- [x] Book the room"))

        // A model that lost the body is refused rather than written.
        var hollow = saved
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

@MainActor
struct ExactFileRevisionTests {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NookExactRevision-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func store(in directory: URL) -> MarkdownStore {
        let store = MarkdownStore(noteLoader: { _, cache in
            MarkdownStore.loadNotes(in: directory, cache: cache)
        })
        store.storageURL = directory
        return store
    }

    private func note(in store: MarkdownStore) throws -> MeetingNote {
        try store.save(MeetingNote(
            title: "Revision safety",
            startedAt: Date(timeIntervalSince1970: 1_780_000_000),
            endedAt: Date(timeIntervalSince1970: 1_780_000_060),
            sourceApp: "Manual",
            summary: "Original summary."
        ))
    }

    @Test(arguments: [false, true])
    func refreshedPersonalNotesRequireExactBaselineOrProposedText(
        canonicallyMatchesProposal: Bool
    ) throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(in: directory)
        let composed = "Review caf\u{00E9} decisions."
        let decomposed = "Review cafe\u{0301} decisions."
        let baseline = canonicallyMatchesProposal ? "Original personal notes." : composed
        let proposed = canonicallyMatchesProposal ? composed : "The local unfinished edit."
        let file = directory.appendingPathComponent("external-personal-edit.md")
        let external = MeetingNote(
            title: "Externally edited personal notes",
            startedAt: Date(timeIntervalSince1970: 1_780_000_000),
            endedAt: Date(timeIntervalSince1970: 1_780_000_060),
            sourceApp: "Manual",
            summary: "Synthetic meeting summary.", personalNotes: decomposed
        )
        let externalBytes = Data(MarkdownCodec.encode(external).utf8)
        try externalBytes.write(to: file)
        // This model carries the current file revision, as after a library
        // refresh. Only the editor's field baseline can detect the conflict.
        let refreshed = try #require(
            MarkdownStore.loadNotes(in: directory, cache: nil).get().notes.first
        )
        #expect(refreshed.fileRevision == MeetingNote.contentRevision(externalBytes))
        #expect(composed == decomposed)
        #expect(!composed.utf8.elementsEqual(decomposed.utf8))

        #expect(throws: MarkdownStoreError.personalNotesChangedElsewhere) {
            try store.updatePersonalNotes(
                proposed, for: refreshed, expectedPersonalNotes: baseline
            )
        }
        #expect(try Data(contentsOf: file) == externalBytes)

        // An explicit choice of the exact external text still resolves the
        // conflict without changing its Unicode representation.
        let saved = try store.updatePersonalNotes(
            decomposed, for: refreshed, expectedPersonalNotes: baseline
        )
        #expect(saved.personalNotes.utf8.elementsEqual(decomposed.utf8))
        #expect(try Data(contentsOf: file) == externalBytes)
    }

    @Test(arguments: [0.0, 0.25])
    func wholeNoteWritesRefuseChangedBytesEvenWhenTheTimestampLooksUnchanged(
        timestampOffset: TimeInterval
    ) throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(in: directory)
        var note = try note(in: store)
        let file = try #require(note.fileURL)
        let modified = try #require(note.fileModified)
        let external = try String(contentsOf: file, encoding: .utf8)
            .replacingOccurrences(of: "Original summary.", with: "Externally edited summary.")
        try external.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: modified.addingTimeInterval(timestampOffset)],
            ofItemAtPath: file.path
        )
        note.title = "A title edited in Nook"
        #expect(throws: MarkdownStoreError.fileChangedElsewhere) { try store.save(note) }
        #expect(try String(contentsOf: file, encoding: .utf8) == external)
    }

    @Test
    func changingOnlyTheModificationDateDoesNotBlockAnUnchangedDocument() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(in: directory)
        var note = try note(in: store)
        let file = try #require(note.fileURL)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(120)],
            ofItemAtPath: file.path
        )
        note.title = "Renamed without losing anything"
        let saved = try store.save(note)
        #expect(saved.title == note.title)
        #expect(saved.summary == "Original summary.")
    }

    @Test
    func aRawDraftConflictThrowsAndSurvivesReloadUntilExplicitlyDiscarded() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(in: directory)
        let note = try note(in: store)
        let file = try #require(note.fileURL)
        let modified = try #require(note.fileModified)
        let draft = MarkdownDraftController()
        draft.prepare(for: note, store: store)
        let original = draft.originalMarkdown
        draft.rawMarkdown += "\n\n## Local addition\n\nKeep this draft.\n"
        let unsaved = draft.rawMarkdown
        let external = original.replacingOccurrences(
            of: "Original summary.", with: "Externally edited summary."
        )
        try external.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
        #expect(throws: MarkdownStoreError.fileChangedElsewhere) {
            try draft.save(note: note, store: store)
        }
        for _ in 0..<100 where store.isLoading { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!store.isLoading)
        let refreshed = try #require(store.notes.first { $0.id == note.id })
        draft.refresh(for: refreshed, store: store)
        #expect(throws: MarkdownStoreError.fileChangedElsewhere) {
            try draft.save(note: refreshed, store: store)
        }
        #expect(draft.hasChanges)
        #expect(draft.rawMarkdown == unsaved)
        #expect(draft.originalMarkdown == original)
        #expect(try String(contentsOf: file, encoding: .utf8) == external)
        draft.discardChanges()
        draft.refresh(for: refreshed, store: store)
        #expect(draft.rawMarkdown == external)
        draft.rawMarkdown += "\n\nReviewed after loading the current file.\n"
        try draft.save(note: refreshed, store: store)
        #expect(!draft.hasChanges)
        #expect(try String(contentsOf: file, encoding: .utf8).contains("Externally edited summary."))
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

/// Inject a competing write after preparation, where the old implementation
/// had already accepted its revision but had not replaced the file yet.
@MainActor
struct MarkdownWriteBoundaryTests {
    private func fixture(
        beforeCommit: @escaping @MainActor (URL) throws -> Void = { _ in }
    ) throws -> (root: URL, library: URL, store: MarkdownStore) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NookWriteBoundary-\(UUID().uuidString)")
            .standardizedFileURL.resolvingSymlinksInPath()
        let library = root.appendingPathComponent("Library")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let store = MarkdownStore(
            noteLoader: { _, _ in .success((notes: [], issues: [])) },
            beforeWriteCommit: beforeCommit
        )
        store.storageURL = library
        return (root, library, store)
    }

    private func note() -> MeetingNote {
        MeetingNote(
            title: "Synthetic write boundary",
            startedAt: Date(timeIntervalSince1970: 1_780_000_000),
            endedAt: Date(timeIntervalSince1970: 1_780_000_060),
            sourceApp: "Manual", summary: "Original café words."
        )
    }

    private func stagingFiles(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".nook-write-") }
    }

    @Test(arguments: [false, true])
    func aDestinationCreatedDuringPreparationIsNeverOverwritten(asSymlink: Bool) throws {
        var interleave: (@MainActor (URL) throws -> Void)?
        let f = try fixture { try interleave?($0) }
        defer {
            interleave = nil
            try? FileManager.default.removeItem(at: f.root)
        }
        let outside = f.root.appendingPathComponent("Other-writer.txt")
        let foreign = Data("Other writer’s exact café source\n".utf8)
        try foreign.write(to: outside)
        var chosenDestination: URL?
        interleave = { destination in
            chosenDestination = destination
            if asSymlink {
                try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: outside)
            } else {
                try foreign.write(to: destination)
            }
        }

        #expect(throws: MarkdownStoreError.fileChangedElsewhere) { try f.store.save(note()) }

        let destination = try #require(chosenDestination)
        #expect(try Data(contentsOf: destination) == foreign)
        #expect(try Data(contentsOf: outside) == foreign)
        #expect(f.store.notes.isEmpty)
        #expect(try stagingFiles(in: f.library).isEmpty)
        if asSymlink {
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: destination.path) == outside.path)
        }
    }

    @Test(arguments: [false, true])
    func anotherStoresInterleavedSaveKeepsTheEditorsOriginalConflictBaseline(rawEditor: Bool) throws {
        var interleave: (@MainActor (URL) throws -> Void)?
        let f = try fixture { try interleave?($0) }
        defer {
            interleave = nil
            try? FileManager.default.removeItem(at: f.root)
        }
        let original = try f.store.save(note())
        let file = try #require(original.fileURL)
        let originalDate = try #require(original.fileModified)
        let editor = MarkdownDraftController()
        editor.prepare(for: original, store: f.store)
        let baseline = editor.originalMarkdown
        editor.rawMarkdown += "\n## Local words\nKeep this unfinished edit.\n"
        let localDraft = editor.rawMarkdown
        let secondStore = MarkdownStore(noteLoader: { _, _ in .success((notes: [], issues: [])) })
        secondStore.storageURL = f.library
        var other = original
        other.summary = "An external writer’s newer words."
        var foreignBytes = Data()
        interleave = { destination in
            _ = try secondStore.save(other)
            foreignBytes = try Data(contentsOf: destination)
            try FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: destination.path)
        }

        if rawEditor {
            #expect(throws: MarkdownStoreError.fileChangedElsewhere) {
                try editor.save(note: original, store: f.store)
            }
            #expect(editor.hasChanges)
            #expect(Data(editor.rawMarkdown.utf8) == Data(localDraft.utf8))
            #expect(Data(editor.originalMarkdown.utf8) == Data(baseline.utf8))
        } else {
            var local = original
            local.title = "Locally renamed"
            #expect(throws: MarkdownStoreError.fileChangedElsewhere) { try f.store.save(local) }
        }
        #expect(!foreignBytes.isEmpty)
        #expect(try Data(contentsOf: file) == foreignBytes)
        #expect(try stagingFiles(in: f.library).isEmpty)
    }

    @Test
    func anOriginalRemovedDuringPreparationIsNotRecreated() throws {
        var interleave: (@MainActor (URL) throws -> Void)?
        let f = try fixture { try interleave?($0) }
        defer {
            interleave = nil
            try? FileManager.default.removeItem(at: f.root)
        }
        var original = try f.store.save(note())
        let file = try #require(original.fileURL)
        interleave = { try FileManager.default.removeItem(at: $0) }
        original.title = "Unsaved local change"

        #expect(throws: CocoaError.self) { try f.store.save(original) }

        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(f.store.notes.first?.title == "Synthetic write boundary")
        #expect(try stagingFiles(in: f.library).isEmpty)
    }

    @Test
    func anInterruptedPreparationKeepsThePreviousFileAndRemovesPrivateStaging() throws {
        var interleave: (@MainActor (URL) throws -> Void)?
        let f = try fixture { try interleave?($0) }
        defer {
            interleave = nil
            try? FileManager.default.removeItem(at: f.root)
        }
        var original = try f.store.save(note())
        let file = try #require(original.fileURL)
        let previous = try Data(contentsOf: file)
        original.summary = "New source that cannot be committed."
        let prepared = Data(MarkdownCodec.encode(original).utf8)
        var inspected = false
        interleave = { _ in
            let temporary = try #require(try stagingFiles(in: f.library).first)
            let attributes = try FileManager.default.attributesOfItem(atPath: temporary.path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
            #expect(try Data(contentsOf: temporary) == prepared)
            inspected = true
            throw POSIXError(.ENOSPC)
        }

        #expect(throws: POSIXError.self) { try f.store.save(original) }

        #expect(inspected)
        #expect(try Data(contentsOf: file) == previous)
        #expect(f.store.notes.first?.summary == "Original café words.")
        #expect(try stagingFiles(in: f.library).isEmpty)
    }

    @Test
    func replacingTheNamedDirectoryCannotRedirectAStagedSave() throws {
        var interleave: (@MainActor (URL) throws -> Void)?
        let f = try fixture { try interleave?($0) }
        defer {
            interleave = nil
            try? FileManager.default.removeItem(at: f.root)
        }
        var original = try f.store.save(note())
        let file = try #require(original.fileURL)
        let previous = try Data(contentsOf: file)
        let moved = f.root.appendingPathComponent("Moved")
        interleave = { destination in
            try FileManager.default.moveItem(at: f.library, to: moved)
            try FileManager.default.createDirectory(at: f.library, withIntermediateDirectories: true)
            try previous.write(to: destination)
        }
        original.title = "Local change"

        #expect(throws: MarkdownStoreError.fileChangedElsewhere) { try f.store.save(original) }

        #expect(try Data(contentsOf: file) == previous)
        #expect(try Data(contentsOf: moved.appendingPathComponent(file.lastPathComponent)) == previous)
        #expect(try stagingFiles(in: moved).isEmpty)
    }
}
