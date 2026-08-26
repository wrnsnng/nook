import Foundation
import Testing
@testable import Nook

private actor DelayedQuickNoteAssistant {
    private var continuation: CheckedContinuation<String, Never>?
    private var queuedResult: String?
    private(set) var didStart = false

    func nextResult() async -> String {
        didStart = true
        if let queuedResult {
            self.queuedResult = nil
            return queuedResult
        }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release(_ result: String) {
        if let continuation {
            self.continuation = nil
            continuation.resume(returning: result)
        } else {
            queuedResult = result
        }
    }
}

private enum DelayedQuickNoteAssistantError: Error {
    case failed
}

private actor DelayedQuickNoteFailure {
    private var continuation: CheckedContinuation<Void, Never>?
    private var releaseRequested = false
    private(set) var didStart = false

    func nextResult() async throws -> String {
        didStart = true
        if releaseRequested {
            throw DelayedQuickNoteAssistantError.failed
        }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        throw DelayedQuickNoteAssistantError.failed
    }

    func release() {
        if let continuation {
            self.continuation = nil
            continuation.resume()
        } else {
            releaseRequested = true
        }
    }
}

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
    func closingThePadEndsItsCaptureSession() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pad = QuickNoteController(store: store(in: directory))
        var dismissalCount = 0
        pad.onDismissRequested = { dismissalCount += 1 }
        pad.isContinuous = true

        pad.close()

        #expect(dismissalCount == 1)
        #expect(!pad.isContinuous)
    }

    @Test
    func aFailedDiscardKeepsTheSavedNoteAndItsWords() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(in: directory)
        let pad = QuickNoteController(
            store: store,
            deleteSavedNote: { _ in false }
        )
        pad.text = "Keep the pricing thought."
        #expect(pad.saveIfNeeded() != nil)

        pad.discard()

        #expect(pad.text == "Keep the pricing thought.")
        #expect(store.notes.count == 1)
        #expect(pad.hasUnsavedFailure)
        #expect(pad.message != nil)
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

    @Test
    func delayedAssistantOutputCannotReplaceWordsEditedWhileItWasThinking() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(in: directory)
        let assistant = DelayedQuickNoteAssistant()
        let pad = QuickNoteController(
            store: store,
            assistantRun: { _, _, _ in await assistant.nextResult() },
            availableEngines: { [.onDevice] }
        )

        pad.present()
        pad.text = "The words I just said are the source of truth."
        pad.run(.tidy)
        for _ in 0..<100 {
            if await assistant.didStart { break }
            await Task.yield()
        }
        #expect(await assistant.didStart)

        pad.text = "I edited this while the assistant was thinking."
        await assistant.release("A stale rewrite")
        for _ in 0..<20 { await Task.yield() }

        #expect(pad.text == "I edited this while the assistant was thinking.")
        #expect(!pad.hasUnsavedFailure)
        pad.close()
    }

    @Test
    func delayedAssistantOutputCannotLandAfterThePadIsClosedAndReopened() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(in: directory)
        let assistant = DelayedQuickNoteAssistant()
        let pad = QuickNoteController(
            store: store,
            assistantRun: { _, _, _ in await assistant.nextResult() },
            availableEngines: { [.onDevice] }
        )

        pad.present()
        pad.text = "The first presentation should not receive old output."
        pad.run(.tidy)
        for _ in 0..<100 {
            if await assistant.didStart { break }
            await Task.yield()
        }
        #expect(await assistant.didStart)

        pad.close()
        pad.present()
        pad.text = "This is a new presentation."
        await assistant.release("Output from the old presentation")
        for _ in 0..<20 { await Task.yield() }

        #expect(pad.text == "This is a new presentation.")
        pad.close()
    }

    @Test
    func delayedAssistantFailureCannotSurfaceAfterDiscard() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(in: directory)
        let continuation = DelayedQuickNoteFailure()
        let pad = QuickNoteController(
            store: store,
            assistantRun: { _, _, _ in try await continuation.nextResult() },
            availableEngines: { [.onDevice] }
        )

        pad.present()
        pad.text = "This thought is being discarded."
        pad.run(.tidy)
        for _ in 0..<100 {
            if await continuation.didStart { break }
            await Task.yield()
        }
        #expect(await continuation.didStart)

        pad.discard()
        await continuation.release()
        for _ in 0..<20 { await Task.yield() }

        #expect(pad.text.isEmpty)
        #expect(pad.message == nil)
        #expect(!pad.isPresenting)
    }

    @Test
    func filingIntoAMeetingTakesTheAutosavedCopyWithIt() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(in: directory)
        let meeting = try store.save(
            MeetingNote(
                title: "Launch review",
                startedAt: Date(timeIntervalSince1970: 1_780_000_000),
                endedAt: Date(timeIntervalSince1970: 1_780_003_600),
                sourceApp: "Zoom",
                summary: "The team agreed on the launch scope."
            )
        )
        let pad = QuickNoteController(store: store)

        pad.text = "Ask Ana whether the beta list is final."
        // What the debounced autosave has usually already done by the time
        // anybody reaches the filing menu.
        #expect(pad.saveIfNeeded() != nil)
        let autosaved = try #require(store.notes.first { $0.kind == .spoken })
        let autosavedFile = try #require(autosaved.fileURL)

        pad.fileIntoMeeting(meeting)

        // Filing is a move, not a copy: one thought, in one place.
        #expect(!store.notes.contains { $0.id == autosaved.id })
        #expect(!FileManager.default.fileExists(atPath: autosavedFile.path))
        #expect(
            store.notes.first { $0.id == meeting.id }?.personalNotes
                == "Ask Ana whether the beta list is final."
        )
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
