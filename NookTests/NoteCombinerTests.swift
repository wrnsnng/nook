import Foundation
import Testing
@testable import Nook

/// Merging two saved notes folds one meeting into the other without losing
/// anything the user cannot get back: the file that survives is the one whose
/// identity the merge kept, the note that goes is the other one, kept audio is
/// only ever moved after the text is safe, and typed titles and tracked
/// follow-ups come through.
/// Stands in for the on-device model, which is never available in a test run
/// and would otherwise leave every merge looking like a failed one.
private struct FixedSummarizer: NoteSummarizing {
    var insights = MeetingInsights(
        title: "Combined conversation",
        summary: "Both sittings, summarized.",
        keyPoints: ["Shipping on Friday"],
        decisions: ["Ship on Friday"],
        actionItems: ["Book the room"]
    )

    func summarize(
        transcript: [TranscriptSegment],
        fallbackTitle: String
    ) async -> MeetingInsights {
        insights
    }
}

@MainActor
struct NoteCombinerTests {
    // MARK: Building blocks

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "NookNoteCombiner-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    /// A store pointed at a scratch folder, with the folder loader stubbed so
    /// the user's real notes are never read.
    private func store(in directory: URL) -> MarkdownStore {
        let store = MarkdownStore(noteLoader: { _, _ in
            .success((notes: [], issues: []))
        })
        store.storageURL = directory
        return store
    }

    private func note(
        title: String,
        startedAt: TimeInterval,
        text: String,
        actionItems: [String] = []
    ) -> MeetingNote {
        MeetingNote(
            title: title,
            startedAt: Date(timeIntervalSince1970: startedAt),
            endedAt: Date(timeIntervalSince1970: startedAt + 300),
            sourceApp: "Manual",
            summary: "Written by hand.",
            actionItems: actionItems,
            transcript: [
                TranscriptSegment(
                    startTime: 0,
                    duration: 4,
                    text: text,
                    source: .mixed
                )
            ]
        )
    }

    /// Runs the three steps the library performs around a merge, in order.
    private func applyMerge(
        _ result: NoteCombiner.Result,
        in store: MarkdownStore
    ) async throws -> MeetingNote {
        let saved = try store.save(result.merged)
        try await result.commitAudio()
        store.delete(result.absorbed)
        return saved
    }

    // MARK: Which note survives

    @Test
    func mergingAnOlderNoteIntoANewerOneLeavesOneFileHoldingBothSittings() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(in: directory)

        let older = try store.save(
            note(title: "Kickoff", startedAt: 1_000_000, text: "First sitting.")
        )
        let newer = try store.save(
            note(title: "Kickoff again", startedAt: 1_100_000, text: "Second sitting.")
        )

        let result = try await NoteCombiner.merge(
            older,
            into: newer,
            recordingsDirectory: store.recordingsDirectory(),
            summarizer: FixedSummarizer()
        )
        #expect(result.merged.id == older.id)
        #expect(result.absorbed.id == newer.id)

        let saved = try await applyMerge(result, in: store)
        let survivingURL = try #require(saved.fileURL)
        let goneURL = try #require(newer.fileURL)

        #expect(FileManager.default.fileExists(atPath: survivingURL.path))
        #expect(!FileManager.default.fileExists(atPath: goneURL.path))
        let markdown = try String(contentsOf: survivingURL, encoding: .utf8)
        let decoded = try #require(MarkdownCodec.decode(markdown, fileURL: survivingURL))
        // Neighbouring speech is coalesced into one run, so the assertion is
        // about the text being there, not about how many lines carry it.
        let spoken = decoded.transcript.map(\.text).joined(separator: " ")
        #expect(spoken.contains("First sitting."))
        #expect(spoken.contains("Second sitting."))
        #expect(store.notes.count == 1)
    }

    @Test
    func mergingANewerNoteIntoAnOlderOneKeepsTheOlderNotesFile() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(in: directory)

        let older = try store.save(
            note(title: "Kickoff", startedAt: 1_000_000, text: "First sitting.")
        )
        let newer = try store.save(
            note(title: "Kickoff again", startedAt: 1_100_000, text: "Second sitting.")
        )

        let result = try await NoteCombiner.merge(
            newer,
            into: older,
            recordingsDirectory: store.recordingsDirectory(),
            summarizer: FixedSummarizer()
        )
        #expect(result.merged.id == older.id)
        #expect(result.absorbed.id == newer.id)

        let saved = try await applyMerge(result, in: store)
        let survivingURL = try #require(saved.fileURL)

        #expect(survivingURL == older.fileURL)
        #expect(FileManager.default.fileExists(atPath: survivingURL.path))
        #expect(!FileManager.default.fileExists(atPath: try #require(newer.fileURL).path))
        let markdown = try String(contentsOf: survivingURL, encoding: .utf8)
        let decoded = try #require(MarkdownCodec.decode(markdown, fileURL: survivingURL))
        let spoken = decoded.transcript.map(\.text).joined(separator: " ")
        #expect(spoken.contains("First sitting."))
        #expect(spoken.contains("Second sitting."))
    }

    // MARK: Audio

    @Test
    func mergingIntoANoteWithoutKeptAudioAdoptsTheOtherRecording() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(in: directory)

        let older = try store.save(
            note(title: "Kickoff", startedAt: 1_000_000, text: "First sitting.")
        )
        let newer = try store.save(
            note(title: "Kickoff again", startedAt: 1_100_000, text: "Second sitting.")
        )
        let recordings = store.recordingsDirectory()
        let incomingAudio = recordings
            .appendingPathComponent("\(newer.id.uuidString).m4a")
        try Data("second sitting audio".utf8).write(to: incomingAudio)

        let result = try await NoteCombiner.merge(
            newer,
            into: older,
            recordingsDirectory: recordings,
            summarizer: FixedSummarizer()
        )
        #expect(result.audioOutcome == .adoptedFromAbsorbed)
        _ = try await applyMerge(result, in: store)

        let adopted = recordings.appendingPathComponent("\(older.id.uuidString).m4a")
        #expect(FileManager.default.fileExists(atPath: adopted.path))
        #expect(!FileManager.default.fileExists(atPath: incomingAudio.path))
        #expect(
            try String(contentsOf: adopted, encoding: .utf8) == "second sitting audio"
        )
    }

    @Test
    func aRecordingTheMergeCannotReadIsMovedAsideRatherThanDeleted() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(in: directory)

        let older = try store.save(
            note(title: "Kickoff", startedAt: 1_000_000, text: "First sitting.")
        )
        let newer = try store.save(
            note(title: "Kickoff again", startedAt: 1_100_000, text: "Second sitting.")
        )
        let recordings = store.recordingsDirectory()
        // Neither file is real audio, so the base recording cannot be measured
        // and the merge has to decide what to do with it.
        let baseAudio = recordings
            .appendingPathComponent("\(older.id.uuidString).m4a")
        let incomingAudio = recordings
            .appendingPathComponent("\(newer.id.uuidString).m4a")
        try Data("truncated".utf8).write(to: baseAudio)
        try Data("second sitting audio".utf8).write(to: incomingAudio)

        let result = try await NoteCombiner.merge(
            newer,
            into: older,
            recordingsDirectory: recordings,
            summarizer: FixedSummarizer()
        )
        #expect(result.audioOutcome == .adoptedFromAbsorbed)
        _ = try await applyMerge(result, in: store)

        #expect(
            try String(contentsOf: baseAudio, encoding: .utf8) == "second sitting audio"
        )
        // Trashing is what usually happens, and the Finder holds the original
        // then. A volume without a Trash gets the rename instead, and the
        // original bytes have to still be there under it.
        let leftovers = try FileManager.default.contentsOfDirectory(
            at: recordings,
            includingPropertiesForKeys: nil
        )
        if let movedAside = leftovers.first(
            where: { $0.lastPathComponent.contains("unreadable-") }
        ) {
            #expect(try String(contentsOf: movedAside, encoding: .utf8) == "truncated")
        }
    }

    @Test
    func aMergeChangesNoAudioUntilTheMergedNoteIsSaved() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(in: directory)

        let older = try store.save(
            note(title: "Kickoff", startedAt: 1_000_000, text: "First sitting.")
        )
        let newer = try store.save(
            note(title: "Kickoff again", startedAt: 1_100_000, text: "Second sitting.")
        )
        let recordings = store.recordingsDirectory()
        let incomingAudio = recordings
            .appendingPathComponent("\(newer.id.uuidString).m4a")
        try Data("second sitting audio".utf8).write(to: incomingAudio)

        _ = try await NoteCombiner.merge(
            newer,
            into: older,
            recordingsDirectory: recordings,
            summarizer: FixedSummarizer()
        )

        // Nothing has been committed, so both notes and both recordings are
        // exactly where they were and the merge can be tried again.
        #expect(FileManager.default.fileExists(atPath: incomingAudio.path))
        #expect(
            FileManager.default.fileExists(atPath: try #require(older.fileURL).path)
        )
        #expect(
            FileManager.default.fileExists(atPath: try #require(newer.fileURL).path)
        )
    }

    // MARK: What the user wrote

    @Test
    func mergeKeepsATypedTitleAndCombinesBothNotesActionItems() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(in: directory)

        let older = try store.save(
            note(
                title: "Pricing for the spring release",
                startedAt: 1_000_000,
                text: "First sitting.",
                actionItems: ["Draft the pricing page [due: 2026-09-12]"]
            )
        )
        let newer = try store.save(
            note(
                title: "Meeting Wed 2:03 PM",
                startedAt: 1_100_000,
                text: "Second sitting.",
                actionItems: ["Send the deck"]
            )
        )

        let result = try await NoteCombiner.merge(
            newer,
            into: older,
            recordingsDirectory: store.recordingsDirectory(),
            summarizer: FixedSummarizer()
        )

        #expect(result.merged.title == "Pricing for the spring release")
        #expect(
            result.merged.actionItems == [
                "Draft the pricing page [due: 2026-09-12]",
                "Send the deck",
                "Book the room"
            ]
        )
    }

    @Test
    func aTitleTheUserTypedOnEitherNoteBeatsAGeneratedOne() {
        let placeholder = note(
            title: "Meeting Wed 2:03 PM",
            startedAt: 1_000_000,
            text: "First."
        )
        let typed = note(
            title: "Budget handover",
            startedAt: 1_100_000,
            text: "Second."
        )

        #expect(
            NoteCombiner.keptTitle(
                base: placeholder,
                incoming: typed,
                proposed: "Model title"
            ) == "Budget handover"
        )
        #expect(
            NoteCombiner.keptTitle(
                base: note(title: "Meeting", startedAt: 1, text: "a"),
                incoming: note(title: "Manual meeting", startedAt: 2, text: "b"),
                proposed: "Model title"
            ) == "Model title"
        )
    }

    @Test
    func combiningActionItemsKeepsDueDatesAndDropsRepeats() {
        let combined = NoteCombiner.unionedActionItems(
            ["Draft the pricing page [due: 2026-09-12]", "Send the deck"],
            ["send the deck", "Book the room"],
            ["Draft the pricing page", "Book the room", "Chase legal"]
        )

        #expect(
            combined == [
                "Draft the pricing page [due: 2026-09-12]",
                "Send the deck",
                "Book the room",
                "Chase legal"
            ]
        )
    }

    @Test
    func aTickedFollowUpStaysTickedAfterAMerge() {
        let items = NoteCombiner.unionedActionItems(
            ["Draft the pricing page [due: 2026-09-12]"],
            ["draft the pricing page", "Send the deck"]
        )
        let completed = NoteCombiner.unionedCompletedActionItems(
            in: items,
            completed: [],
            ["draft the pricing page"]
        )

        #expect(completed == ["Draft the pricing page [due: 2026-09-12]"])
    }

    @Test
    func aSummaryTheModelCouldNotWriteLeavesTheExistingOneAlone() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(in: directory)

        let older = try store.save(
            note(title: "Pricing", startedAt: 1_000_000, text: "First sitting.")
        )
        let newer = try store.save(
            note(title: "Pricing", startedAt: 1_100_000, text: "Second sitting.")
        )

        // The first merge is only there to learn what the combined transcript
        // looks like, so the stand-in summary can be the exact one the
        // summarizer would hand back for it.
        let rehearsal = try await NoteCombiner.merge(
            newer,
            into: older,
            recordingsDirectory: store.recordingsDirectory(),
            summarizer: FixedSummarizer()
        )
        var summarizer = FixedSummarizer()
        summarizer.insights = SummaryService.fallbackInsights(
            transcript: rehearsal.merged.transcript,
            fallbackTitle: "Pricing"
        )

        let result = try await NoteCombiner.merge(
            newer,
            into: older,
            recordingsDirectory: store.recordingsDirectory(),
            summarizer: summarizer
        )

        #expect(result.merged.summary == "Written by hand.")
    }

    // MARK: Headings nobody modelled

    @Test
    func handWrittenSectionsFromBothNotesSurviveTheMerge() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(in: directory)

        var older = note(title: "Kickoff", startedAt: 1_000_000, text: "First sitting.")
        older.extraSections = [
            ExtraSection(
                heading: "## Open questions",
                body: "- Who owns the migration?",
                anchor: "## summary"
            )
        ]
        var newer = note(title: "Kickoff again", startedAt: 1_100_000, text: "Second sitting.")
        newer.extraSections = [
            ExtraSection(
                heading: "## Risks",
                body: "- The vendor contract renews in October.",
                anchor: "## summary"
            )
        ]
        let savedOlder = try store.save(older)
        let savedNewer = try store.save(newer)

        let result = try await NoteCombiner.merge(
            savedOlder,
            into: savedNewer,
            recordingsDirectory: store.recordingsDirectory(),
            summarizer: FixedSummarizer()
        )
        let saved = try await applyMerge(result, in: store)
        let markdown = try String(
            contentsOf: try #require(saved.fileURL),
            encoding: .utf8
        )

        // Somebody typed both of these into their own file. A merge that keeps
        // only the surviving note's headings deletes half of that writing.
        #expect(markdown.contains("## Open questions"))
        #expect(markdown.contains("Who owns the migration?"))
        #expect(markdown.contains("## Risks"))
        #expect(markdown.contains("The vendor contract renews in October."))
    }

    @Test
    func theSameHandWrittenSectionOnBothNotesIsKeptOnce() {
        let shared = ExtraSection(
            heading: "## Open questions",
            body: "- Who owns the migration?",
            anchor: "## summary"
        )
        let onlyOnOne = ExtraSection(
            heading: "## Risks",
            body: "- The vendor contract renews in October.",
            anchor: "## summary"
        )

        #expect(
            NoteCombiner.unionedExtraSections(
                [shared, onlyOnOne],
                [shared]
            ) == [shared, onlyOnOne]
        )
    }

    @Test
    func digestsCannotBeMerged() async throws {
        var digest = note(title: "August", startedAt: 1_000_000, text: "Digest.")
        digest.kind = .digest
        let meeting = note(title: "Kickoff", startedAt: 1_100_000, text: "Kickoff.")

        await #expect(throws: NoteCombiner.CombineError.self) {
            _ = try await NoteCombiner.merge(
                meeting,
                into: digest,
                recordingsDirectory: FileManager.default.temporaryDirectory,
                summarizer: FixedSummarizer()
            )
        }
    }
}
