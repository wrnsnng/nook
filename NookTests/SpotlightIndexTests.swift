import CoreSpotlight
import Foundation
import Synchronization
import Testing
@testable import Nook

/// Spotlight holds a second copy of the library outside the notes folder, so
/// it must say only what the note says, forget a note when the note goes,
/// and empty itself when the user turns it off. A fake index stands in for
/// Spotlight; nothing here touches the real one.
@MainActor
struct SpotlightIndexTests {
    /// Every request the indexer makes, in order.
    final class FakeSpotlight: Sendable {
        enum Call: Equatable {
            case index([String])
            case remove([String])
            case removeAll
        }

        private struct State {
            var calls: [Call] = []
            var failingIndexRequests = 0
        }

        private let state = Mutex(State())

        var calls: [Call] { state.withLock { $0.calls } }

        func takeCalls() -> [Call] {
            state.withLock { state in
                defer { state.calls = [] }
                return state.calls
            }
        }

        func failNextIndexRequest() {
            state.withLock { $0.failingIndexRequests += 1 }
        }

        var client: SpotlightIndexClient {
            SpotlightIndexClient(
                index: { entries in
                    let shouldFail = self.state.withLock { state in
                        guard state.failingIndexRequests == 0 else {
                            state.failingIndexRequests -= 1
                            return true
                        }
                        state.calls.append(.index(entries.map(\.identifier)))
                        return false
                    }
                    if shouldFail { throw CocoaError(.fileWriteUnknown) }
                },
                remove: { identifiers in
                    self.state.withLock { $0.calls.append(.remove(identifiers)) }
                },
                removeAll: {
                    self.state.withLock { $0.calls.append(.removeAll) }
                }
            )
        }
    }

    private func recordURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("NookSpotlight-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("indexed-notes.json")
    }

    private func note(
        _ title: String,
        kind: NoteKind = .meeting,
        id: UUID = UUID(),
        summary: String = "Agreed to ship on Friday.",
        keyPoints: [String] = ["The notch stays dark."],
        decisions: [String] = ["Ship on Friday."],
        saved: Bool = true
    ) -> MeetingNote {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        return MeetingNote(
            id: id,
            kind: kind,
            title: title,
            startedAt: start,
            endedAt: start.addingTimeInterval(1_800),
            sourceApp: "Zoom",
            summary: summary,
            keyPoints: keyPoints,
            decisions: decisions,
            personalNotes: "Private aside.",
            transcript: [
                TranscriptSegment(startTime: 0, duration: 4, text: "Something said.", source: .system)
            ],
            fileURL: saved ? URL(fileURLWithPath: "/synthetic/\(id.uuidString).md") : nil
        )
    }

    // MARK: - What Spotlight is told

    @Test
    func aSavedMeetingIsFoundByItsTitleSummaryKeyPointsAndDecisions() throws {
        let meeting = note(
            "Launch review",
            keyPoints: ["The notch stays dark.", "  ", "Captions are optional."],
            decisions: ["Ship on Friday.", "the notch stays dark."]
        )
        let entry = try #require(MeetingSearchEntry(note: meeting))
        let item = entry.searchableItem
        let attributes = item.attributeSet

        #expect(item.uniqueIdentifier == meeting.id.uuidString)
        #expect(item.domainIdentifier == "meetings")
        #expect(attributes.title == "Launch review")
        #expect(attributes.displayName == "Launch review")
        #expect(attributes.contentDescription == "Agreed to ship on Friday.")
        #expect(attributes.keywords == [
            "The notch stays dark.", "Captions are optional.", "Ship on Friday.",
        ])
        #expect(attributes.contentCreationDate == meeting.startedAt)
        // Untouched notes are never sent again, so they must not expire.
        #expect(item.expirationDate == .distantFuture)
    }

    @Test
    func transcriptsAndMyNotesNeverReachSpotlight() throws {
        let entry = try #require(MeetingSearchEntry(note: note("Launch review")))
        let attributes = entry.attributes
        let indexedText = [
            attributes.title, attributes.displayName, attributes.contentDescription,
        ].compactMap { $0 } + (attributes.keywords ?? [])
        #expect(!indexedText.contains { $0.contains("Something said") })
        #expect(!indexedText.contains { $0.contains("Private aside") })
    }

    @Test
    func quickNotesAreIndexedButDigestsAndUnsavedNotesAreNot() {
        #expect(MeetingSearchEntry(note: note("Groceries", kind: .spoken)) != nil)
        #expect(MeetingSearchEntry(note: note("This week", kind: .digest)) == nil)
        #expect(MeetingSearchEntry(note: note("Draft", saved: false)) == nil)
    }

    @Test
    func copiesSharingAnIDStayOutOfSpotlightUntilReviewed() {
        let shared = UUID()
        let unique = note("Planning")
        let entries = MeetingSearchEntry.entries(for: [
            note("Copy one", id: shared), note("Copy two", id: shared), unique,
        ])
        #expect(entries.map(\.identifier) == [unique.id.uuidString])
    }

    @Test
    func onlyChangesToIndexedTextSendANoteAgain() throws {
        let original = note("Launch review")
        let indexed = try #require(MeetingSearchEntry(note: original))
        let record = [indexed.identifier: indexed.fingerprint]

        var transcriptEdited = original
        transcriptEdited.transcript.append(
            TranscriptSegment(startTime: 5, duration: 3, text: "More words.", source: .microphone)
        )
        transcriptEdited.personalNotes = "Another aside."
        #expect(SpotlightIndexPlan(
            desired: MeetingSearchEntry.entries(for: [transcriptEdited]), indexed: record
        ).isEmpty)

        var renamed = original
        renamed.title = "Launch retro"
        let plan = SpotlightIndexPlan(desired: MeetingSearchEntry.entries(for: [renamed]), indexed: record)
        #expect(plan.upserts.map(\.title) == ["Launch retro"])
        #expect(plan.removals.isEmpty)
    }

    // MARK: - Keeping Spotlight in step

    @Test
    func aFirstSyncClearsWhateverAnEarlierRunLeftThenIndexesTheLibrary() async {
        let spotlight = FakeSpotlight()
        let indexer = MeetingSpotlightIndexer(client: spotlight.client, recordURL: recordURL())
        let first = note("First")
        let second = note("Second")

        await indexer.apply(notes: [first, second], enabled: true)

        #expect(spotlight.takeCalls() == [
            .removeAll, .index([first.id.uuidString, second.id.uuidString]),
        ])
    }

    @Test
    func anUnchangedLibrarySendsNothingEvenAfterARelaunch() async {
        let spotlight = FakeSpotlight()
        let url = recordURL()
        let notes = [note("First"), note("Second")]
        let indexer = MeetingSpotlightIndexer(client: spotlight.client, recordURL: url)
        await indexer.apply(notes: notes, enabled: true)
        _ = spotlight.takeCalls()

        await indexer.apply(notes: notes, enabled: true)
        let relaunched = MeetingSpotlightIndexer(client: spotlight.client, recordURL: url)
        await relaunched.apply(notes: notes, enabled: true)

        #expect(spotlight.calls.isEmpty)
    }

    @Test
    func aRenamedNoteIsSentAgainAndATrashedOneIsRemoved() async {
        let spotlight = FakeSpotlight()
        let indexer = MeetingSpotlightIndexer(client: spotlight.client, recordURL: recordURL())
        var kept = note("Kept")
        let trashed = note("Trashed")
        await indexer.apply(notes: [kept, trashed], enabled: true)
        _ = spotlight.takeCalls()

        kept.title = "Kept, renamed"
        await indexer.apply(notes: [kept], enabled: true)

        #expect(spotlight.takeCalls() == [
            .remove([trashed.id.uuidString]), .index([kept.id.uuidString]),
        ])
    }

    @Test
    func aNoteTrashedWhileNookWasClosedIsRemovedAtLaunch() async {
        let spotlight = FakeSpotlight()
        let url = recordURL()
        let kept = note("Kept")
        let trashed = note("Trashed")
        await MeetingSpotlightIndexer(client: spotlight.client, recordURL: url)
            .apply(notes: [kept, trashed], enabled: true)
        _ = spotlight.takeCalls()

        await MeetingSpotlightIndexer(client: spotlight.client, recordURL: url)
            .apply(notes: [kept], enabled: true)

        #expect(spotlight.takeCalls() == [.remove([trashed.id.uuidString])])
    }

    @Test
    func turningSpotlightOffRemovesEverythingAndStopsIndexing() async {
        let spotlight = FakeSpotlight()
        let url = recordURL()
        let indexer = MeetingSpotlightIndexer(client: spotlight.client, recordURL: url)
        let first = note("First")
        await indexer.apply(notes: [first], enabled: true)
        _ = spotlight.takeCalls()
        #expect(FileManager.default.fileExists(atPath: url.path))

        await indexer.apply(notes: [first], enabled: false)
        #expect(spotlight.takeCalls() == [.removeAll])
        #expect(!FileManager.default.fileExists(atPath: url.path))

        await indexer.apply(notes: [first, note("Added while off")], enabled: false)
        #expect(spotlight.takeCalls().isEmpty)

        let second = note("Second")
        await indexer.apply(notes: [first, second], enabled: true)
        #expect(spotlight.takeCalls() == [
            .removeAll, .index([first.id.uuidString, second.id.uuidString]),
        ])
    }

    @Test
    func aRefusedSyncIsRetriedOnTheNextChange() async {
        let spotlight = FakeSpotlight()
        let indexer = MeetingSpotlightIndexer(client: spotlight.client, recordURL: recordURL())
        let first = note("First")
        await indexer.apply(notes: [first], enabled: true)
        _ = spotlight.takeCalls()

        let second = note("Second")
        spotlight.failNextIndexRequest()
        await indexer.apply(notes: [first, second], enabled: true)
        #expect(spotlight.takeCalls().isEmpty)

        await indexer.apply(notes: [first, second], enabled: true)
        #expect(spotlight.takeCalls() == [.index([second.id.uuidString])])
    }

    @Test
    func theSettingsSwitchEmptiesSpotlightWithoutARelaunch() async throws {
        let suite = "NookSpotlightTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let meeting = note("Launch review")
        let store = MarkdownStore(noteLoader: { _, _ in .success((notes: [meeting], issues: [])) })
        let spotlight = FakeSpotlight()
        let indexer = MeetingSpotlightIndexer(
            client: spotlight.client,
            recordURL: recordURL(),
            debounce: .milliseconds(10)
        )

        indexer.observe(store, defaults: defaults)
        try await waitUntil { spotlight.calls.contains(.index([meeting.id.uuidString])) }
        _ = spotlight.takeCalls()

        defaults.set(false, forKey: SpotlightIndexPreference.key)
        try await waitUntil { spotlight.calls == [.removeAll] }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<300 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }

    // MARK: - Preference and opening a result

    @Test
    func spotlightIsOnUntilTheUserTurnsItOff() throws {
        let suite = "NookSpotlightPreference-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        #expect(SpotlightIndexPreference.isEnabled(in: defaults))
        defaults.set(false, forKey: SpotlightIndexPreference.key)
        #expect(!SpotlightIndexPreference.isEnabled(in: defaults))
    }

    @Test
    func aSpotlightResultNamesTheNoteToOpen() {
        let id = UUID()
        let result = NSUserActivity(activityType: CSSearchableItemActionType)
        result.userInfo = [CSSearchableItemActivityIdentifier: id.uuidString]
        #expect(MeetingSpotlightContinuation.noteID(from: result) == id)

        let malformed = NSUserActivity(activityType: CSSearchableItemActionType)
        malformed.userInfo = [CSSearchableItemActivityIdentifier: "not-a-note"]
        #expect(MeetingSpotlightContinuation.noteID(from: malformed) == nil)

        let other = NSUserActivity(activityType: "com.example.browsing")
        other.userInfo = [CSSearchableItemActivityIdentifier: id.uuidString]
        #expect(MeetingSpotlightContinuation.noteID(from: other) == nil)
        #expect(!MeetingSpotlightContinuation.open(other))
    }
}
