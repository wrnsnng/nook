import Foundation
import Testing
@testable import Nook

/// The quick note pad is usually the only copy of something that was said out
/// loud a second ago. Two ways of ending it used to throw those words away
/// without saying anything: quitting inside the autosave debounce, and closing
/// after a save the store had refused.
@MainActor
struct QuickNotePadSafetyTests {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "NookQuickNotePad-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private func store(in directory: URL) -> MarkdownStore {
        let store = MarkdownStore(noteLoader: { _, _ in
            .success((notes: [], issues: []))
        })
        store.storageURL = directory
        return store
    }

    /// Makes the next whole-note save fail the way the store's own guard makes
    /// it fail: the file on disk is newer than the copy Nook last read, so
    /// writing it would delete somebody else's edit.
    private func markChangedElsewhere(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(30)],
            ofItemAtPath: url.path
        )
    }

    @Test
    func quittingWritesWhatIsStillInThePad() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(in: directory)
        let pad = QuickNoteController(store: store)

        // Typed, with the debounce not yet due: exactly the state a quit lands
        // in most often.
        pad.text = "Tell Priya the mockups are ready."

        #expect(pad.saveForTermination() == nil)
        #expect(
            store.notes.first?.summary == "Tell Priya the mockups are ready."
        )
    }

    @Test
    func quittingIsBlockedWhenThePadsWordsCouldNotBeWritten() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(in: directory)
        let pad = QuickNoteController(store: store)

        pad.text = "First thought."
        #expect(pad.saveIfNeeded() != nil)
        let fileURL = try #require(store.notes.first?.fileURL)
        try markChangedElsewhere(fileURL)

        pad.text = "First thought. Second thought."

        // A reason, not nil: the caller quits only when this is nil.
        #expect(pad.saveForTermination() != nil)
        #expect(pad.hasUnsavedFailure)
        #expect(pad.text == "First thought. Second thought.")
    }

    @Test
    func aPadThatCouldNotSaveRefusesToClose() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(in: directory)
        let pad = QuickNoteController(store: store)

        pad.text = "Half of an idea."
        #expect(pad.saveIfNeeded() != nil)
        let fileURL = try #require(store.notes.first?.fileURL)
        try markChangedElsewhere(fileURL)

        pad.text = "Half of an idea, and the other half."

        #expect(!pad.canClose())
        pad.close()

        // The words are still on screen, with a reason beside them, rather
        // than gone with the window.
        #expect(pad.text == "Half of an idea, and the other half.")
        #expect(pad.message != nil)
        #expect(!pad.messageIsAdvisory)
    }

    @Test
    func aPadWithNothingInItClosesWithoutComplaint() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(in: directory)
        let pad = QuickNoteController(store: store)

        #expect(pad.canClose())
        #expect(pad.saveForTermination() == nil)
        #expect(store.notes.isEmpty)
    }

    @Test
    func aPadThatSavesOnTheSecondTryStopsBlockingTheClose() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(in: directory)
        let pad = QuickNoteController(store: store)

        pad.text = "One line."
        #expect(pad.saveIfNeeded() != nil)
        let saved = try #require(store.notes.first)
        let fileURL = try #require(saved.fileURL)
        let lastSeen = try #require(saved.fileModified)
        try markChangedElsewhere(fileURL)

        pad.text = "One line, then another."
        #expect(!pad.canClose())

        // Whatever the file was doing has settled and it agrees with what Nook
        // last read, so the same words go through and the objection lifts.
        try FileManager.default.setAttributes(
            [.modificationDate: lastSeen],
            ofItemAtPath: fileURL.path
        )
        #expect(pad.canClose())
        #expect(!pad.hasUnsavedFailure)
        #expect(store.notes.first?.summary == "One line, then another.")
    }

    // MARK: Model output that reaches the note

    @Test
    func anActionListTheNoteCannotAccountForLeavesTheNoteAlone() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(in: directory)
        let pad = QuickNoteController(store: store)

        pad.text = "Remember to send Priya the revised pricing mockups."
        pad.applyForTesting(
            """
            - Migrate the billing service to Stripe
            - Cancel the Braintree contract
            """,
            for: .actionItems
        )

        #expect(
            pad.text == "Remember to send Priya the revised pricing mockups."
        )
        #expect(pad.message == QuickNoteController.keptYourOwnWordsNotice)
        #expect(pad.messageIsAdvisory)
    }

    @Test
    func actionsDrawnFromTheNoteAreAppendedUnderTheirHeading() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(in: directory)
        let pad = QuickNoteController(store: store)

        pad.text = "Remember to send Priya the revised pricing mockups."
        pad.applyForTesting(
            "- Send Priya the revised pricing mockups",
            for: .actionItems
        )

        #expect(pad.text.contains("## Find actions"))
        #expect(pad.text.contains("- Send Priya the revised pricing mockups"))
        #expect(pad.message == nil)
    }
}
