import Foundation
import Testing
@testable import Nook

/// A digest compiles the week deterministically: real counts, real decisions,
/// no invented outcomes. The only model-written part is an optional overview,
/// and the digest is complete without it.
@MainActor
struct DigestTests {
    private func meeting(
        _ title: String,
        daysAgo: Double,
        decisions: [String] = [],
        keyPoints: [String] = [],
        moments: Int = 0
    ) -> MeetingNote {
        MeetingNote(
            title: title,
            startedAt: Date().addingTimeInterval(-daysAgo * 86_400),
            endedAt: Date().addingTimeInterval(-daysAgo * 86_400 + 3_600),
            sourceApp: "Zoom",
            summary: "\(title) happened.",
            keyPoints: keyPoints,
            decisions: decisions,
            moments: (0..<moments).map { MeetingMoment(offset: Double($0) * 60) }
        )
    }

    @Test
    func theDigestCoversOnlyTheLastSevenDays() async {
        let inside = meeting("Standup", daysAgo: 2)
        let outside = meeting("Old offsite", daysAgo: 12)

        let digest = await DigestBuilder.build(
            from: [inside, outside],
            overviewProvider: { _ in nil }
        )

        #expect(digest.kind == .digest)
        #expect(digest.summary.contains("1 meeting between"))
        // Each helper meeting runs an hour; the week's conversation time is
        // stated plainly.
        #expect(digest.summary.contains("1h of conversation"))
        #expect(!digest.summary.contains("Offsite"))
        // No model, no overview paragraph beyond the deterministic facts.
        #expect(digest.keyPoints.isEmpty)
    }

    @Test
    func conversationTimeLabelsStayHuman() {
        #expect(
            DigestBuilder.conversationTimeLabel(for: 45 * 60)
                == "45m of conversation"
        )
        #expect(
            DigestBuilder.conversationTimeLabel(for: 60 * 60)
                == "1h of conversation"
        )
        #expect(
            DigestBuilder.conversationTimeLabel(for: 3 * 3_600 + 25 * 60)
                == "3h 25m of conversation"
        )
    }

    @Test
    func decisionsAreDeduplicatedAcrossMeetings() async {
        let monday = meeting(
            "Monday",
            daysAgo: 1,
            decisions: ["Hold pricing until q4"],
            keyPoints: ["Tiers questioned"]
        )
        let tuesday = meeting(
            "Tuesday",
            daysAgo: 0.5,
            decisions: ["Hold pricing until q4", "Ship friday"],
            keyPoints: ["Tiers questioned"]
        )

        let digest = await DigestBuilder.build(
            from: [monday, tuesday],
            overviewProvider: { _ in nil }
        )

        #expect(digest.decisions == ["Hold pricing until q4", "Ship friday"])
        // A week with more than one meeting stays plural.
        #expect(digest.summary.contains("2 meetings between"))
        // Two highlights per meeting maximum, labelled with their source.
        #expect(
            digest.keyPoints == [
                "Monday: Tiers questioned",
                "Tuesday: Tiers questioned"
            ]
        )
    }

    @Test
    func flaggedMomentsAreCounted() async {
        let flagged = meeting("Review", daysAgo: 1, moments: 3)

        let digest = await DigestBuilder.build(
            from: [flagged],
            overviewProvider: { _ in nil }
        )

        #expect(digest.summary.contains("3 moments flagged"))
    }

    /// A digest round-trips like any note, and its file carries no transcript.
    @Test
    func digestSurvivesTheRoundTrip() throws {
        let digest = MeetingNote(
            kind: .digest,
            title: "Week of Aug 16",
            startedAt: Date(timeIntervalSince1970: 1_000_000),
            endedAt: Date(timeIntervalSince1970: 1_060_000),
            sourceApp: "Digest",
            summary: "2 meetings. Lots of shipping.",
            keyPoints: ["Review: Tiers questioned"],
            decisions: ["Ship friday"]
        )

        let encoded = MarkdownCodec.encode(digest)
        #expect(encoded.contains("kind: digest"))
        #expect(!encoded.contains("## Transcript"))
        #expect(!encoded.contains("## My notes"))

        let decoded = try #require(MarkdownCodec.decode(encoded))
        #expect(decoded.kind == .digest)
        #expect(MarkdownCodec.encode(decoded) == encoded)
    }

    /// `coveredMeetings` is `build`'s own 7-day filter, exposed so a caller
    /// deciding whether there is anything to compile does not need a second
    /// copy of the window logic.
    @Test
    func coveredMeetingsMatchesWhatBuildItselfCompiles() async {
        let inside = meeting("Standup", daysAgo: 2)
        let outside = meeting("Old offsite", daysAgo: 12)

        let covered = DigestBuilder.coveredMeetings(from: [inside, outside])
        #expect(covered.map(\.title) == ["Standup"])

        let digest = await DigestBuilder.build(
            from: [inside, outside],
            overviewProvider: { _ in nil }
        )
        #expect(digest.summary.contains("1 meeting between"))
    }

    @Test(arguments: ["meeting", "outside-window", "spoken"])
    func copiedUUIDsDoNotInflateCountsOrMixOutcomes(copyKind: String) async {
        let first = meeting(
            "Ambiguous meeting", daysAgo: 1, decisions: ["Unreviewed approval"],
            keyPoints: ["Unreviewed claim"], moments: 5
        )
        var second = first
        second.title = "Conflicting copy"
        second.decisions = ["Unreviewed rejection"]
        second.fileURL = URL(fileURLWithPath: "/synthetic/copy.md")
        if copyKind == "outside-window" {
            second.startedAt = Date().addingTimeInterval(-20 * 86_400)
            second.endedAt = second.startedAt.addingTimeInterval(3_600)
        } else if copyKind == "spoken" {
            second.kind = .spoken
        }
        let unique = meeting(
            "Verified meeting", daysAgo: 2, decisions: ["Keep the plan"],
            keyPoints: ["One verified outcome"], moments: 1
        )
        let notes = [first, second, unique]

        let digest = await DigestBuilder.build(from: notes, overviewProvider: { included in
            #expect(included.map(\.id) == [unique.id])
            return nil
        })

        #expect(DigestBuilder.coveredMeetings(from: notes).map(\.id) == [unique.id])
        #expect(digest.summary.contains("1 meeting between"))
        #expect(digest.summary.contains("1h of conversation"))
        #expect(digest.summary.contains("1 moment flagged"))
        #expect(digest.summary.contains(LibraryNoteAggregation.omissionMessage))
        #expect(digest.decisions == unique.decisions)
        #expect(digest.keyPoints == ["Verified meeting: One verified outcome"])
        #expect(DigestBuilder.omittedMeetingCount(from: notes) == (copyKind == "meeting" ? 2 : 1))
    }

    @Test
    func duplicateDigestTargetsAreRefusedEvenWhenOneCopyIsOutsideTheCurrentWindow() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        var first = meeting("Weekly digest", daysAgo: 1)
        first.kind = .digest
        first.startedAt = now.addingTimeInterval(-86_400)
        first.fileURL = URL(fileURLWithPath: "/synthetic/digest.md")
        var second = first
        second.startedAt = now.addingTimeInterval(-20 * 86_400)
        second.fileURL = URL(fileURLWithPath: "/synthetic/digest-copy.md")

        for notes in [[first, second], [second, first]] {
            #expect(throws: DigestBuildError.ambiguousReplacement) {
                try DigestBuilder.replacement(in: notes, now: now)
            }
            #expect(throws: DigestBuildError.ambiguousReplacement) {
                try DigestBuilder.validateReplacement(first, in: notes, now: now)
            }
        }
    }

    @Test(arguments: ["copy", "move", "revision", "new-digest"])
    func aDigestTargetMustStillIdentifyTheCapturedFileAfterCompilation(change: String) async throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        var first = meeting("Weekly digest", daysAgo: 1)
        first.kind = .digest
        first.startedAt = now.addingTimeInterval(-86_400)
        first.fileURL = URL(fileURLWithPath: "/synthetic/digest.md")
        first.fileRevision = MeetingNote.contentRevision(Data("original bytes".utf8))
        let original = change == "new-digest" ? nil : first
        let captured = try DigestBuilder.replacement(in: original.map { [$0] } ?? [], now: now)
        _ = await DigestBuilder.build(from: [], now: now, replacing: captured)
        var changed = first
        if change == "move" || change == "copy" {
            changed.fileURL = URL(fileURLWithPath: "/synthetic/different-file.md")
        } else if change == "revision" {
            changed.fileRevision = MeetingNote.contentRevision(Data("newer bytes".utf8))
        }
        let current = change == "copy" ? [first, changed] : [changed]

        #expect(throws: change == "copy"
            ? DigestBuildError.ambiguousReplacement : DigestBuildError.changedReplacement) {
            try DigestBuilder.validateReplacement(captured, in: current, now: now)
        }
        try DigestBuilder.validateReplacement(first, in: [first], now: now)
    }

    /// Creating a digest twice for the same week must update the existing
    /// file rather than leave a second, near-duplicate one behind.
    @Test
    func buildReusesTheGivenIdAndFileURLWhenProvided() async {
        let existingID = UUID()
        let existingURL = URL(fileURLWithPath: "/tmp/week-of-test.md")
        let meetingNote = meeting("Standup", daysAgo: 1)

        let digest = await DigestBuilder.build(
            from: [meetingNote],
            id: existingID,
            fileURL: existingURL,
            overviewProvider: { _ in nil }
        )

        #expect(digest.id == existingID)
        #expect(digest.fileURL == existingURL)
    }

    /// Without an explicit id or URL, `build` behaves exactly as before:
    /// a fresh identity for a fresh file.
    @Test
    func buildDefaultsToAFreshIdentityWhenNoneIsGiven() async {
        let meetingNote = meeting("Standup", daysAgo: 1)

        let digest = await DigestBuilder.build(
            from: [meetingNote],
            overviewProvider: { _ in nil }
        )

        #expect(digest.fileURL == nil)
    }

    @Test
    func rebuiltDigestsKeepUserAnnotationsAndTheirOriginalMetadata() async throws {
        let source = meeting("Standup", daysAgo: 1, decisions: ["Ship on Friday"])
        var original = await DigestBuilder.build(from: [source])
        original.title = "My weekly review"
        original.personalNotes = "Ask about the rollout before sharing."
        original.actionItems = ["Review the follow-up"]
        original.completedActionItems = Set(original.actionItems)
        original.extraSections = [ExtraSection(
            heading: "## Questions", body: "What should next week change?", anchor: "## action items"
        )]
        original.fileURL = URL(fileURLWithPath: "/tmp/nook-digest-metadata-fixture.md")
        original.fileModified = Date(timeIntervalSince1970: 1_780_000_000)
        original.fileRevision = MeetingNote.contentRevision(Data(MarkdownCodec.encode(original).utf8))
        let rebuilt = await DigestBuilder.build(from: [source], replacing: original)
        #expect(rebuilt.id == original.id)
        #expect(rebuilt.fileURL == original.fileURL)
        #expect(rebuilt.fileModified == original.fileModified)
        #expect(rebuilt.fileRevision == original.fileRevision)
        #expect(rebuilt.extraSections == original.extraSections)
        let decoded = try #require(MarkdownCodec.decode(MarkdownCodec.encode(rebuilt)))
        #expect(decoded.title == original.title)
        #expect(decoded.personalNotes == original.personalNotes)
        #expect(decoded.actionItems == original.actionItems)
        #expect(decoded.completedActionItems == original.completedActionItems)
        let extra = try #require(decoded.extraSections.first)
        #expect(extra.heading == "## Questions")
        #expect(extra.anchor == "## action items")
        #expect(extra.body.trimmingCharacters(in: .whitespacesAndNewlines)
            == "What should next week change?")
        #expect(decoded.decisions == ["Ship on Friday"])
    }

    @Test
    func aRebuiltDigestCannotOverwriteAnExternalEditAfterReload() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NookDigestRevision-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MarkdownStore(noteLoader: { _, _ in MarkdownStore.loadNotes(in: directory) })
        store.storageURL = directory
        let source = meeting("Standup", daysAgo: 1)
        let initial = await DigestBuilder.build(from: [source])
        let saved = try store.save(initial)
        let pending = await DigestBuilder.build(from: [source], replacing: saved)
        let file = try #require(saved.fileURL)
        let modified = try #require(saved.fileModified)
        var external = saved
        external.personalNotes = "The external annotation must survive."
        let externalMarkdown = MarkdownCodec.encode(external)
        try externalMarkdown.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
        store.reload()
        for _ in 0..<100 where store.isLoading { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!store.isLoading)
        #expect(store.notes.first { $0.id == saved.id }?.personalNotes == external.personalNotes)
        #expect(throws: MarkdownStoreError.fileChangedElsewhere) { try store.save(pending) }
        #expect(try String(contentsOf: file, encoding: .utf8) == externalMarkdown)
    }
}
