import AVFoundation
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

    /// Writes a short, real recording.
    ///
    /// Arbitrary bytes with an `.m4a` name are not a stand-in any more: the
    /// merge asks how long a recording is before it will adopt or join it, and
    /// a file it cannot measure is a different case with different correct
    /// behaviour. Tests that mean "an unreadable recording" still write bytes.
    private func writeRecording(seconds: Double, to url: URL) throws {
        struct CouldNotWriteAudio: Error {}
        guard
            let format = AVAudioFormat(
                standardFormatWithSampleRate: 44_100,
                channels: 1
            ),
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(44_100 * seconds)
            )
        else {
            throw CouldNotWriteAudio()
        }
        buffer.frameLength = buffer.frameCapacity
        // Silence: nothing here listens, it only measures.
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1
            ]
        )
        try file.write(from: buffer)
    }

    /// The recordings whose names carry `fragment`, so an assertion about one
    /// can require it rather than skip itself when there is none.
    private func recordingsMatching(
        _ fragment: String,
        in directory: URL
    ) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains(fragment) }
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
        try writeRecording(seconds: 1, to: incomingAudio)
        let incomingBytes = try Data(contentsOf: incomingAudio)

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
        #expect(try Data(contentsOf: adopted) == incomingBytes)
    }

    @Test
    func aRecordingTheMergeCannotReadIsNeverAdoptedAsTheNotesAudio() async throws {
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
        // The surviving note has no audio at all, and what the other one has
        // cannot be measured, so there is nothing worth adopting.
        let incomingAudio = recordings
            .appendingPathComponent("\(newer.id.uuidString).m4a")
        try Data("truncated".utf8).write(to: incomingAudio)

        let result = try await NoteCombiner.merge(
            newer,
            into: older,
            recordingsDirectory: recordings,
            summarizer: FixedSummarizer(),
            unusableAudioDestination: .renameBeside
        )
        #expect(result.audioOutcome == .none)
        _ = try await applyMerge(result, in: store)

        let adopted = recordings
            .appendingPathComponent("\(older.id.uuidString).m4a")
        #expect(!FileManager.default.fileExists(atPath: adopted.path))
        // Its note is in the Trash now, so leaving it under an identifier no
        // note claims would strand it in the recordings folder forever. It is
        // set aside the same way an unreadable recording on the other side is,
        // and the bytes come through that move intact.
        #expect(!FileManager.default.fileExists(atPath: incomingAudio.path))
        let movedAside = try #require(
            recordingsMatching("unreadable-", in: recordings).first
        )
        #expect(try String(contentsOf: movedAside, encoding: .utf8) == "truncated")
    }

    @Test
    func anUnreadableRecordingLeavesItsOldNameOnAnOrdinaryVolumeToo() async throws {
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
        try Data("truncated".utf8).write(to: incomingAudio)

        // The shipping default, so the branch the user actually gets is
        // covered as well as the fallback. The assertion is the one that holds
        // whichever way it goes: the recording does not stay under an
        // identifier no note claims.
        let result = try await NoteCombiner.merge(
            newer,
            into: older,
            recordingsDirectory: recordings,
            summarizer: FixedSummarizer()
        )
        _ = try await applyMerge(result, in: store)

        #expect(!FileManager.default.fileExists(atPath: incomingAudio.path))
    }

    @Test
    func joiningBothRecordingsDoesNotLeaveTheOtherCopyBehind() async throws {
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
        let baseAudio = recordings
            .appendingPathComponent("\(older.id.uuidString).m4a")
        let incomingAudio = recordings
            .appendingPathComponent("\(newer.id.uuidString).m4a")
        try writeRecording(seconds: 1, to: baseAudio)
        try writeRecording(seconds: 1, to: incomingAudio)

        let result = try await NoteCombiner.merge(
            newer,
            into: older,
            recordingsDirectory: recordings,
            summarizer: FixedSummarizer()
        )
        #expect(result.audioOutcome == .concatenated)
        _ = try await applyMerge(result, in: store)

        // Every second of it is in the joined file and the note it came from
        // is in the Trash, so a copy left here is a whole duplicate recording
        // nothing will ever offer back or clean up.
        #expect(FileManager.default.fileExists(atPath: baseAudio.path))
        #expect(!FileManager.default.fileExists(atPath: incomingAudio.path))
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
        // The base recording is not real audio, so it cannot be measured and
        // the merge has to decide what to do with it.
        let baseAudio = recordings
            .appendingPathComponent("\(older.id.uuidString).m4a")
        let incomingAudio = recordings
            .appendingPathComponent("\(newer.id.uuidString).m4a")
        try Data("truncated".utf8).write(to: baseAudio)
        try writeRecording(seconds: 1, to: incomingAudio)
        let incomingBytes = try Data(contentsOf: incomingAudio)

        // The rename fallback is asked for by name. Trashing is what happens
        // on an ordinary volume, and the Finder holds the original then, so a
        // test that let it trash could never reach the branch that has to
        // carry the bytes itself. Guarding the assertion behind "if a renamed
        // file turned up" is how that guarantee went unproven.
        let result = try await NoteCombiner.merge(
            newer,
            into: older,
            recordingsDirectory: recordings,
            summarizer: FixedSummarizer(),
            unusableAudioDestination: .renameBeside
        )
        #expect(result.audioOutcome == .adoptedFromAbsorbed)
        _ = try await applyMerge(result, in: store)

        #expect(try Data(contentsOf: baseAudio) == incomingBytes)
        let movedAside = try #require(
            recordingsMatching("unreadable-", in: recordings).first
        )
        #expect(try String(contentsOf: movedAside, encoding: .utf8) == "truncated")
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
