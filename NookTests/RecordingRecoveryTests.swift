import Foundation
import Testing
@testable import Nook

/// The pane that lists recordings with no note has to be right about two
/// things: it must never offer to delete a meeting that is still happening,
/// and deleting must stay reversible, because the audio it lists is the only
/// copy of that conversation.
@MainActor
struct RecordingRecoveryTests {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "NookRecordingRecovery-\(UUID().uuidString)",
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

    @discardableResult
    private func writeRecording(
        _ id: UUID,
        extensionName: String,
        in directory: URL
    ) throws -> URL {
        let url = directory
            .appendingPathComponent("\(id.uuidString).\(extensionName)")
        try Data("captured audio".utf8).write(to: url)
        return url
    }

    @Test
    func aRecordingThatIsStillBeingMadeIsNotListedAsStranded() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(in: directory)
        let recovery = RecordingRecovery(store: store)

        let stranded = UUID()
        let live = UUID()
        try writeRecording(stranded, extensionName: "mp4", in: store.recordingsDirectory())
        try writeRecording(live, extensionName: "mp4", in: store.recordingsDirectory())

        recovery.activeRecording = .inFlight(live)

        #expect(recovery.orphans.map(\.id) == [stranded])
    }

    @Test
    func nothingIsListedWhileAMeetingIsRunningAndItsIdentifierIsUnknown() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(in: directory)
        let recovery = RecordingRecovery(store: store)

        try writeRecording(UUID(), extensionName: "mp4", in: store.recordingsDirectory())

        recovery.activeRecording = .inFlight(nil)
        #expect(recovery.orphans.isEmpty)

        recovery.activeRecording = .none
        #expect(recovery.orphans.count == 1)
    }

    @Test
    func deletingAStrandedRecordingDoesNotFailAndRemovesItFromTheList() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(in: directory)
        let recovery = RecordingRecovery(store: store)

        let id = UUID()
        let capture = try writeRecording(
            id,
            extensionName: "mp4",
            in: store.recordingsDirectory()
        )
        recovery.scan()
        let orphan = try #require(recovery.orphans.first)

        recovery.delete(orphan)

        // Trashed on a volume with a Trash, unlinked on one without: either
        // way it has left the recordings folder and nothing went wrong.
        #expect(!FileManager.default.fileExists(atPath: capture.path))
        #expect(recovery.orphans.isEmpty)
        #expect(recovery.message == nil)
    }

    @Test
    func aRecordingWithNoCaptureLeftIsLabelledAsAudioOnly() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(in: directory)
        let recovery = RecordingRecovery(store: store)

        let audioOnly = UUID()
        let interrupted = UUID()
        try writeRecording(audioOnly, extensionName: "m4a", in: store.recordingsDirectory())
        try writeRecording(interrupted, extensionName: "mp4", in: store.recordingsDirectory())
        recovery.scan()

        let listed = Dictionary(
            uniqueKeysWithValues: recovery.orphans.map { ($0.id, $0) }
        )
        #expect(try #require(listed[audioOnly]).isAudioOnly)
        #expect(try #require(listed[interrupted]).isAudioOnly == false)
    }

    @Test
    func audioBelongingToASavedNoteIsLeftAlone() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(in: directory)
        let recovery = RecordingRecovery(store: store)

        let saved = try store.save(
            MeetingNote(
                title: "Kept",
                startedAt: Date(timeIntervalSince1970: 1_000_000),
                endedAt: Date(timeIntervalSince1970: 1_000_600),
                sourceApp: "Manual",
                summary: "Finished."
            )
        )
        try writeRecording(saved.id, extensionName: "m4a", in: store.recordingsDirectory())
        recovery.scan()

        #expect(recovery.orphans.isEmpty)
    }

    // MARK: Notes typed during a meeting

    @Test
    func notesTypedDuringAMeetingAreOnDiskForRecoveryToFind() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(in: directory)
        let recordings = store.recordingsDirectory()
        let id = UUID()

        MeetingCoordinator.writeLiveNotes(
            "Ask Ana about the beta list.",
            to: MeetingCoordinator.liveNotesURL(for: id, in: recordings)
        )

        #expect(
            MeetingCoordinator.recoverableLiveNotes(for: id, in: recordings)
                == "Ask Ana about the beta list."
        )
    }

    @Test
    func clearingTheNotesFieldDoesNotLeaveTheOldWordsToBeRecovered() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(in: directory)
        let recordings = store.recordingsDirectory()
        let id = UUID()
        let url = MeetingCoordinator.liveNotesURL(for: id, in: recordings)

        MeetingCoordinator.writeLiveNotes("A first thought.", to: url)
        MeetingCoordinator.writeLiveNotes("   ", to: url)

        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(
            MeetingCoordinator.recoverableLiveNotes(for: id, in: recordings)
                .isEmpty
        )
    }

    @Test
    func aMeetingThatFinishesTakesItsNotesFileWithIt() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(in: directory)
        let recordings = store.recordingsDirectory()
        let id = UUID()
        let draft = MeetingDraft(
            id: id,
            title: "Weekly review",
            sourceApp: "Zoom",
            startedAt: Date(timeIntervalSince1970: 1_780_000_000),
            recordingURL: recordings
                .appendingPathComponent("\(id.uuidString).mp4")
        )
        let notesURL = MeetingCoordinator.liveNotesURL(for: id, in: recordings)
        MeetingCoordinator.writeLiveNotes("Inside the note now.", to: notesURL)
        try writeRecording(id, extensionName: "mp4", in: recordings)

        // The notes are in the saved note by this point, so a second copy in
        // the recordings folder is litter nothing else would ever remove.
        #expect(
            RecordingArtifactCleanup.removeArtifacts(for: draft).isEmpty
        )
        #expect(!FileManager.default.fileExists(atPath: notesURL.path))
    }

    // MARK: What a recovery leaves behind

    private func recoveryCleanup(
        keepAudio: Bool,
        in recordings: URL,
        id: UUID
    ) -> Set<URL> {
        RecordingRecovery.filesToRemoveAfterRecovery(
            sources: [
                recordings.appendingPathComponent("\(id.uuidString).mp4"),
                recordings.appendingPathComponent("\(id.uuidString).m4a")
            ],
            extractedAudio: recordings
                .appendingPathComponent("\(id.uuidString).m4a"),
            liveNotes: MeetingCoordinator.liveNotesURL(
                for: id,
                in: recordings
            ),
            keepAudio: keepAudio
        )
    }

    @Test
    func recoveringAMeetingKeepsItsAudioWhenRetentionIsOn() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(in: directory)
        let recordings = store.recordingsDirectory()
        let id = UUID()
        let audio = recordings
            .appendingPathComponent("\(id.uuidString).m4a")
            .standardizedFileURL

        let removable = recoveryCleanup(
            keepAudio: true,
            in: recordings,
            id: id
        )

        #expect(!removable.contains(audio))
        #expect(
            removable.contains(
                recordings
                    .appendingPathComponent("\(id.uuidString).mp4")
                    .standardizedFileURL
            )
        )
        #expect(
            removable.contains(
                MeetingCoordinator.liveNotesURL(for: id, in: recordings)
                    .standardizedFileURL
            )
        )
    }

    @Test
    func recoveringAMeetingRemovesItsAudioWhenRetentionIsOff() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(in: directory)
        let recordings = store.recordingsDirectory()
        let id = UUID()

        let removable = recoveryCleanup(
            keepAudio: false,
            in: recordings,
            id: id
        )

        #expect(
            removable.contains(
                recordings
                    .appendingPathComponent("\(id.uuidString).m4a")
                    .standardizedFileURL
            )
        )
    }
}
