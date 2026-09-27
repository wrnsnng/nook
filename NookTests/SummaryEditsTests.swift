import Foundation
import Testing
@testable import Nook

/// The Notes tab lets a person rewrite the gist, key points, decisions,
/// action items and open questions in place, so a meeting's notes can be
/// finished in Nook instead of copied into another tool. These cover what
/// that promises: typing reaches the file, ticks survive rewording, nothing
/// untouched is rewritten, a change made elsewhere is not overwritten, and
/// Regenerate asks before replacing the person's words.
@MainActor
struct SummaryEditsTests {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NookSummaryEdits-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func store(in directory: URL) -> MarkdownStore {
        let store = MarkdownStore(noteLoader: { _, _ in .success((notes: [], issues: [])) })
        store.storageURL = directory
        return store
    }

    private func meeting(
        summary: String = "The team agreed on the launch scope. Pricing stays the same.",
        actionItems: [String] = ["Maya: send the brief [due: 2030-01-15]", "Book the venue"],
        completed: Set<String> = ["Book the venue"]
    ) -> MeetingNote {
        MeetingNote(
            title: "Synthetic launch review",
            startedAt: Date(timeIntervalSince1970: 1_780_000_000),
            endedAt: Date(timeIntervalSince1970: 1_780_003_600),
            sourceApp: "Zoom",
            summary: summary,
            keyPoints: ["Scope is final", "Beta starts in March"],
            decisions: ["Ship the smaller plan"],
            actionItems: actionItems,
            openQuestions: ["Who reviews accessibility?"],
            completedActionItems: completed,
            transcript: [
                TranscriptSegment(startTime: 0, duration: 4, text: "We agreed on the launch scope.", source: .microphone),
            ]
        )
    }

    private func decodedFile(of note: MeetingNote) throws -> MeetingNote {
        let url = try #require(note.fileURL)
        let markdown = try String(contentsOf: url, encoding: .utf8)
        return try #require(MarkdownCodec.decode(markdown, fileURL: url))
    }

    // MARK: Rows

    @Test
    func loadingANoteAndSavingUntouchedRowsWritesNothing() throws {
        let store = store(in: try temporaryDirectory())
        let saved = try store.save(meeting())
        let before = try Data(contentsOf: try #require(saved.fileURL))
        let edits = store.summaryEdits

        edits.prepare(for: saved, store: store)

        #expect(!edits.hasChanges)
        #expect(edits.draft.summary.map(\.text) == [
            "The team agreed on the launch scope.", "Pricing stays the same.",
        ])
        #expect(edits.saveIfNeeded(store: store) == nil)
        #expect(try Data(contentsOf: try #require(saved.fileURL)) == before)
    }

    @Test
    func editingOneSentenceKeepsTheRestOfTheProseByteForByte() {
        let summary = "The team agreed on the launch scope.  Pricing stays the same.\n\nBeta opens in March."
        var rows = SummaryProseRow.rows(
            displaying: SummaryReviewItem.sentences(in: summary).map(\.text), of: summary
        )
        #expect(SummaryProseRow.summary(from: rows) == summary)

        rows[1].text = "Pricing rises in April."

        #expect(SummaryProseRow.summary(from: rows)
            == "The team agreed on the launch scope.  Pricing rises in April.\n\nBeta opens in March.")
    }

    @Test
    func returnSplitsARowAtTheCaretAndDeleteJoinsItBack() throws {
        var rows = SummaryListRow.rows(from: ["Scope is final", "Beta starts in March"])
        let first = rows[0].id

        let focus = try #require(SummaryRowEditing.split(&rows, at: first, caret: 5))

        #expect(rows.map(\.text) == ["Scope", "is final", "Beta starts in March"])
        #expect(focus == .init(rowID: rows[1].id, caret: 0))

        let joined = try #require(SummaryRowEditing.deleteBackward(&rows, at: rows[1].id))
        #expect(rows.map(\.text) == ["Scope is final", "Beta starts in March"])
        #expect(joined == .init(rowID: first, caret: 6))
    }

    @Test
    func deleteInAnEmptyRowRemovesItAndReturnAtTheEndAddsOne() throws {
        var rows = SummaryListRow.rows(from: ["Scope is final"])
        let first = rows[0].id

        let added = try #require(SummaryRowEditing.split(&rows, at: first, caret: 14))
        #expect(rows.map(\.text) == ["Scope is final", ""])
        #expect(added.rowID == rows[1].id)

        let back = try #require(SummaryRowEditing.deleteBackward(&rows, at: rows[1].id))
        #expect(rows.map(\.text) == ["Scope is final"])
        #expect(back == .init(rowID: first, caret: 14))

        // Delete at the start of the first row has nothing above to join.
        #expect(SummaryRowEditing.deleteBackward(&rows, at: first) == nil)
        #expect(rows.map(\.text) == ["Scope is final"])
    }

    @Test
    func emptyAndPlaceholderRowsAreNotWrittenAsItems() {
        let rows = [
            SummaryListRow(text: "Scope is final"),
            SummaryListRow(text: "   "),
            SummaryListRow(text: "None"),
            SummaryListRow(text: "Two\nlines"),
        ]
        #expect(SummaryListRow.items(from: rows) == ["Scope is final", "Two lines"])
    }

    // MARK: Action items

    @Test
    func rewordingAnActionItemKeepsItsTickAndItsDueDate() throws {
        let store = store(in: try temporaryDirectory())
        let saved = try store.save(meeting(completed: ["Maya: send the brief [due: 2030-01-15]"]))
        let edits = store.summaryEdits
        edits.prepare(for: saved, store: store)

        #expect(edits.draft.actions[0].text == "Maya: send the brief")
        #expect(edits.draft.actions[0].isCompleted)
        edits.draft.actions[0].text = "Maya: send the final brief"
        let written = try edits.save(note: saved, store: store)

        let file = try decodedFile(of: written)
        #expect(file.actionItems == ["Maya: send the final brief [due: 2030-01-15]", "Book the venue"])
        #expect(file.completedActionItems == ["Maya: send the final brief [due: 2030-01-15]"])
        #expect(ActionItemLine.dueDate(in: file.actionItems[0]) != nil)
        #expect(ActionItemOwner.parse(ActionItemLine.strippingDueSuffix(from: file.actionItems[0])).owner == "Maya")
    }

    @Test
    func addingAndRemovingActionItemsRoundTripsThroughMarkdown() throws {
        let store = store(in: try temporaryDirectory())
        let saved = try store.save(meeting())
        let edits = store.summaryEdits
        edits.prepare(for: saved, store: store)

        let last = edits.draft.actions[1]
        _ = SummaryRowEditing.split(&edits.draft.actions, at: last.id, caret: last.text.utf16.count)
        edits.draft.actions[2].text = "Draft the agenda"
        edits.draft.actions.remove(at: 0)
        let written = try edits.save(note: saved, store: store)

        let file = try decodedFile(of: written)
        #expect(file.actionItems == ["Book the venue", "Draft the agenda"])
        #expect(file.completedActionItems == ["Book the venue"])
        #expect(!edits.hasChanges)
    }

    // MARK: Saving

    @Test
    func savingEditedSectionsRoundTripsAndMarksTheSummaryAsEdited() throws {
        let store = store(in: try temporaryDirectory())
        let saved = try store.save(meeting())
        #expect(!saved.summaryEditedByUser)
        let edits = store.summaryEdits
        edits.prepare(for: saved, store: store)

        edits.draft.summary[1].text = "Pricing rises in April."
        edits.draft.keyPoints[0].text = "Scope is final for 1.0"
        edits.draft.openQuestions.append(SummaryListRow(text: "Who owns support?"))
        let written = try edits.save(note: saved, store: store)

        let file = try decodedFile(of: written)
        #expect(file.summary == "The team agreed on the launch scope. Pricing rises in April.")
        #expect(file.keyPoints == ["Scope is final for 1.0", "Beta starts in March"])
        #expect(file.decisions == ["Ship the smaller plan"])
        #expect(file.openQuestions == ["Who reviews accessibility?", "Who owns support?"])
        #expect(file.summaryEditedByUser)
        #expect(try String(contentsOf: try #require(written.fileURL), encoding: .utf8)
            .contains("summary_edited: true"))
    }

    @Test
    func aSectionChangedElsewhereRefusesTheSaveAndKeepsTheWords() throws {
        let store = store(in: try temporaryDirectory())
        let saved = try store.save(meeting())
        let edits = store.summaryEdits
        edits.prepare(for: saved, store: store)
        edits.draft.keyPoints[0].text = "Typed here"

        // A review correction lands in the same section first.
        var other = saved
        other.keyPoints[0] = "Corrected elsewhere"
        let otherSaved = try store.save(other)

        #expect(throws: MarkdownStoreError.summaryChangedElsewhere) {
            try edits.save(note: otherSaved, store: store)
        }
        #expect(edits.draft.keyPoints[0].text == "Typed here")
        #expect(try decodedFile(of: otherSaved).keyPoints[0] == "Corrected elsewhere")
    }

    @Test
    func aTickMadeElsewhereWhileTypingIsKept() throws {
        let store = store(in: try temporaryDirectory())
        let saved = try store.save(meeting(completed: []))
        let edits = store.summaryEdits
        edits.prepare(for: saved, store: store)
        edits.draft.decisions[0].text = "Ship the smaller plan first"

        var ticked = saved
        ticked.completedActionItems = ["Book the venue"]
        let tickedSaved = try store.save(ticked)
        let written = try edits.save(note: tickedSaved, store: store)

        let file = try decodedFile(of: written)
        #expect(file.decisions == ["Ship the smaller plan first"])
        #expect(file.completedActionItems == ["Book the venue"])
        // The rows picked up the tick too, so a later edit cannot undo it.
        #expect(edits.draft.actions[1].isCompleted)
    }

    @Test
    func editingAFallbackWriteUpNoLongerDescribesItAsASample() throws {
        let store = store(in: try temporaryDirectory())
        var fallback = meeting()
        fallback.summaryProvenance = .transcriptHighlights
        let saved = try store.save(fallback)
        let edits = store.summaryEdits
        edits.prepare(for: saved, store: store)

        edits.draft.summary[0].text = "We agreed the scope."
        let written = try edits.save(note: saved, store: store)

        #expect(try decodedFile(of: written).summaryProvenance == .editedFallback)
    }

    @Test
    func unsavedEditsForAnotherNoteAreWrittenWhenTheSelectionMoves() throws {
        let store = store(in: try temporaryDirectory())
        let first = try store.save(meeting())
        var secondNote = meeting()
        secondNote = MeetingNote(
            title: "Second synthetic meeting", startedAt: secondNote.startedAt,
            endedAt: secondNote.endedAt, sourceApp: "Zoom", summary: "Another summary."
        )
        let second = try store.save(secondNote)
        let edits = store.summaryEdits
        edits.prepare(for: first, store: store)
        edits.draft.decisions[0].text = "Ship the bigger plan"

        edits.prepare(for: second, store: store)

        #expect(edits.owner == second.libraryIdentity)
        #expect(try decodedFile(of: first).decisions == ["Ship the bigger plan"])
    }

    // MARK: Markdown

    @Test
    func theEditedFlagRoundTripsAndOlderFilesReadAsUnedited() throws {
        var note = meeting()
        note.summaryEditedByUser = true
        let encoded = MarkdownCodec.encode(note)
        #expect(encoded.contains("summary_edited: true"))
        #expect(MarkdownCodec.decode(encoded)?.summaryEditedByUser == true)

        note.summaryEditedByUser = false
        let plain = MarkdownCodec.encode(note)
        #expect(!plain.contains("summary_edited"))
        #expect(MarkdownCodec.decode(plain)?.summaryEditedByUser == false)
    }

    // MARK: Regeneration

    @Test
    func regenerateAsksOnlyWhenThereAreEditsToLose() {
        var note = meeting()
        #expect(!SummaryRegenerationGuard.needsConfirmation(note: note, hasUnsavedEdits: false))
        #expect(SummaryRegenerationGuard.needsConfirmation(note: note, hasUnsavedEdits: true))
        note.summaryEditedByUser = true
        #expect(SummaryRegenerationGuard.needsConfirmation(note: note, hasUnsavedEdits: false))
    }

    @Test
    func aConfirmedRegenerationClearsTheFlagUnlessNewerEditsSurvive() {
        var starting = meeting()
        starting.summaryEditedByUser = true
        var regenerated = starting
        regenerated.summary = "A fresh summary."
        regenerated.keyPoints = ["Fresh point"]
        regenerated.summaryEditedByUser = false

        let replaced = SummaryRegenerator.mergingGeneratedFields(
            from: regenerated, startingFrom: starting, into: starting
        )
        #expect(replaced.summary == "A fresh summary.")
        #expect(!replaced.summaryEditedByUser)

        var typedDuringRun = starting
        typedDuringRun.keyPoints = ["Typed while it ran"]
        let kept = SummaryRegenerator.mergingGeneratedFields(
            from: regenerated, startingFrom: starting, into: typedDuringRun
        )
        #expect(kept.keyPoints == ["Typed while it ran"])
        #expect(kept.summary == "A fresh summary.")
        #expect(kept.summaryEditedByUser)
    }

    @Test
    func recordingIntoAnEditedNoteKeepsTheEditsAndAddsNewActionItems() throws {
        var scaffold = meeting()
        scaffold.summaryEditedByUser = true
        let result = SummaryResult(insights: MeetingInsights(
            title: "Generated title", summary: "Generated summary.",
            keyPoints: ["Generated point"], decisions: ["Generated decision"],
            actionItems: ["Book the venue", "Order badges"], openQuestions: []
        ), failure: nil)

        let merged = try #require(MeetingCoordinator.mergingAppendedSessionSummary(
            result, scaffold: scaffold, current: scaffold
        ))

        #expect(merged.summary == scaffold.summary)
        #expect(merged.keyPoints == scaffold.keyPoints)
        #expect(merged.decisions == scaffold.decisions)
        #expect(merged.openQuestions == scaffold.openQuestions)
        #expect(merged.title == scaffold.title)
        #expect(merged.actionItems.contains("Order badges"))
        #expect(merged.completedActionItems.contains("Book the venue"))
    }
}
