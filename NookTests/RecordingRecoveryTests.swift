import Combine
import Foundation
import Testing
@testable import Nook

/// The pane that lists recordings with no note has to be right about two
/// things: it must never offer to delete a meeting that is still happening,
/// and deleting must stay reversible, because the audio it lists is the only
/// copy of that conversation.
@MainActor
struct RecordingRecoveryTests {
    @Test
    func recoveringManyPausedSegmentsPreservesConversationOrder() {
        let id = UUID()
        let directory = URL(fileURLWithPath: "/synthetic/recordings")
        let first = directory.appendingPathComponent("\(id.uuidString).mp4")
        let parts = (1...12).map {
            directory.appendingPathComponent("\(id.uuidString).part-\($0).mp4")
        }
        let recording = OrphanedRecording(
            id: id,
            urls: Array(parts.reversed()) + [first],
            recordedAt: .distantPast,
            byteSize: 0
        )

        #expect(recording.captures == [first] + parts)
    }

    @Test
    func recoveryKeepsNumericOrderWhenTheFirstCaptureIsMissing() {
        let id = UUID()
        let directory = URL(fileURLWithPath: "/synthetic/recordings")
        let parts = [2, 3, 10, 12].map {
            directory.appendingPathComponent("\(id.uuidString).part-\($0).mp4")
        }
        let recording = OrphanedRecording(
            id: id,
            urls: Array(parts.reversed()),
            recordedAt: .distantPast,
            byteSize: 0
        )

        #expect(recording.captures == parts)
    }

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

    private func reloadAndWait(_ store: MarkdownStore) async {
        var observation: AnyCancellable?
        await withCheckedContinuation { continuation in
            observation = store.$isLoading
                .dropFirst()
                .filter { !$0 }
                .prefix(1)
                .sink { _ in continuation.resume() }
            store.reload()
        }
        observation?.cancel()
    }

    @Test
    func recoveryScanFollowsTheNotesPublishedByAnAsyncReload() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        let note = MeetingNote(
            id: id,
            title: "Reloaded note",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_060),
            sourceApp: "Manual",
            summary: "The note arrives after the folder scan."
        )
        let store = MarkdownStore(noteLoader: { url, _ in
            let notes = url.standardizedFileURL
                == directory.standardizedFileURL ? [note] : []
            return .success((notes: notes, issues: []))
        })
        store.storageURL = directory
        let recovery = RecordingRecovery(store: store)
        try writeRecording(id, extensionName: "mp4", in: store.recordingsDirectory())

        recovery.scan()
        #expect(recovery.orphans.map(\.id) == [id])

        store.reload()
        for _ in 0..<100 where store.isLoading {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(store.notes.map(\.id) == [id])
        #expect(recovery.orphans.isEmpty)
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
        var trashedURLs: [URL] = []
        let recovery = RecordingRecovery(store: store, trashItem: { url in
            trashedURLs.append(url)
            try FileManager.default.removeItem(at: url)
        })

        let id = UUID()
        let capture = try writeRecording(
            id,
            extensionName: "mp4",
            in: store.recordingsDirectory()
        )
        recovery.scan()
        let orphan = try #require(recovery.orphans.first)

        recovery.delete(orphan)

        // This injected Trash receipt represents a successful reversible
        // move. Compare the unique filename because the file is already gone
        // when macOS exposes the temp root as `/var` or `/private/var`.
        #expect(trashedURLs.count == 1)
        #expect(trashedURLs.first?.lastPathComponent == capture.lastPathComponent)
        #expect(!FileManager.default.fileExists(atPath: capture.path))
        #expect(recovery.orphans.isEmpty)
        #expect(recovery.message == nil)
    }

    @Test
    func deletionRefusesToUnlinkWhenTrashIsUnavailable() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(in: directory)
        struct TrashUnavailable: Error {}
        let recovery = RecordingRecovery(store: store, trashItem: { _ in
            throw TrashUnavailable()
        })

        let id = UUID()
        let capture = try writeRecording(
            id,
            extensionName: "mp4",
            in: store.recordingsDirectory()
        )
        recovery.scan()
        let orphan = try #require(recovery.orphans.first)

        recovery.delete(orphan)

        #expect(FileManager.default.fileExists(atPath: capture.path))
        #expect(recovery.orphans.map(\.id) == [id])
        #expect(recovery.message?.contains("Trash") == true)
        #expect(recovery.message?.contains("left in place") == true)
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

    @Test(arguments: [false, true])
    func liveNotesStayBesideCapturedAudioAfterChangingLibraries(isPaused: Bool) async throws {
        let directory = try temporaryDirectory()
        let otherLibrary = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: otherLibrary)
        }
        let store = store(in: directory)
        let coordinator = MeetingCoordinator(store: store, detector: MeetingDetector())
        let id = coordinator.startDraftForTesting()
        let recordings = directory.appendingPathComponent(".recordings", isDirectory: true)
        let audio = try writeRecording(id, extensionName: "mp4", in: recordings)
        let draft = MeetingDraft(
            id: id, title: "Synthetic review", sourceApp: "Manual",
            startedAt: .now, recordingURL: audio
        )
        coordinator.liveNotes = "Before the folder change."
        let previousWrite = try #require(coordinator.liveNotesSaveForTesting)
        store.storageURL = otherLibrary
        coordinator.setPreviewState(
            phase: .recording(title: draft.title, startedAt: draft.startedAt),
            elapsed: 10, liveTranscript: .empty, audioLevel: 0, isPaused: isPaused
        )
        let exactNotes = " \nCafe\u{301} review.\n\n  Preserve this indentation.\t\n"
        coordinator.liveNotes = exactNotes
        await previousWrite.value
        await coordinator.liveNotesSaveForTesting?.value

        let notesURL = MeetingCoordinator.liveNotesURL(for: draft)
        #expect(try Data(contentsOf: notesURL) == Data(exactNotes.utf8))
        #expect(MeetingCoordinator.recoverableLiveNotes(for: id, in: recordings)
            .utf8.elementsEqual(exactNotes.utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: otherLibrary.path).isEmpty)

        // Cleanup must use the same captured owner, even if another folder
        // happens to contain a file with that UUID. No actual Trash is used.
        let otherNotes = MeetingCoordinator.liveNotesURL(for: id, in: store.recordingsDirectory())
        let unrelated = Data("Other library's independent copy.".utf8)
        try unrelated.write(to: otherNotes)
        coordinator.liveNotes = "Queued just before this session ends."
        let pendingWrite = try #require(coordinator.liveNotesSaveForTesting)
        coordinator.clearDraftForTesting()
        #expect(RecordingArtifactCleanup.removeArtifacts(for: draft).isEmpty)
        await pendingWrite.value

        #expect(!FileManager.default.fileExists(atPath: notesURL.path))
        #expect(!FileManager.default.fileExists(atPath: audio.path))
        #expect(try Data(contentsOf: otherNotes) == unrelated)
    }

    @Test
    func aNewSessionUsesItsOwnFolderWithoutRevivingThePreviousSidecar() async throws {
        let directory = try temporaryDirectory()
        let otherLibrary = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: otherLibrary)
        }
        let store = store(in: directory)
        let coordinator = MeetingCoordinator(store: store, detector: MeetingDetector())
        let previousID = coordinator.startDraftForTesting()
        coordinator.liveNotes = "Previous pending session."
        let previousWrite = try #require(coordinator.liveNotesSaveForTesting)
        coordinator.clearDraftForTesting()
        store.storageURL = otherLibrary
        let nextID = coordinator.startDraftForTesting()
        coordinator.liveNotes = "This session belongs to the new folder."
        await previousWrite.value
        await coordinator.liveNotesSaveForTesting?.value

        #expect(previousID != nextID)
        let previousDirectory = directory.appendingPathComponent(".recordings", isDirectory: true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: previousDirectory.path).isEmpty)
        #expect(MeetingCoordinator.recoverableLiveNotes(
            for: nextID, in: otherLibrary.appendingPathComponent(".recordings", isDirectory: true)
        ) == coordinator.liveNotes)
        coordinator.clearDraftForTesting()
    }

    @Test
    func canonicallyEquivalentLiveNotesStillCheckpointTheirChangedBytes() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(in: directory)
        let coordinator = MeetingCoordinator(store: store, detector: MeetingDetector())
        let id = coordinator.startDraftForTesting()
        coordinator.liveNotes = "Caf\u{e9} planning"
        await coordinator.liveNotesSaveForTesting?.value
        coordinator.liveNotes = "Cafe\u{301} planning"
        await coordinator.liveNotesSaveForTesting?.value

        let recovered = MeetingCoordinator.recoverableLiveNotes(
            for: id, in: directory.appendingPathComponent(".recordings", isDirectory: true)
        )
        #expect(recovered.utf8.elementsEqual(coordinator.liveNotes.utf8))
        coordinator.clearDraftForTesting()
    }

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

    @Test(arguments: [false, true])
    func recoveredWordsAreReadableBeforeSummaryAndCancellationNeverDiscardsThem(
        switchLibrary: Bool
    ) async throws {
        let directory = try temporaryDirectory()
        let other = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: other)
        }
        let store = store(in: directory)
        let id = UUID()
        let audio = try writeRecording(id, extensionName: "m4a", in: store.recordingsDirectory())
        let gate = RecordingRecoveryGate()
        defer { gate.release() }
        let source: [TranscriptSegment] = [
            .init(startTime: 0, duration: 3, text: "My synthetic words.", source: .microphone),
            .init(startTime: 4, duration: 3, text: "Their synthetic response.", source: .system),
            .init(startTime: 8, duration: 3, text: "Unattributed synthetic audio.", source: .mixed),
        ]
        let recovery = RecordingRecovery(store: store, transcribeAudio: { _, _ in source }, summarizeTranscript: { _, title in
            await gate.hold()
            return MeetingInsights(title: title, summary: "A late model result", keyPoints: [], decisions: [], actionItems: [])
        })
        recovery.scan()
        let orphan = try #require(recovery.orphans.first)
        recovery.recover(orphan, localeIdentifier: "en-AU")
        let recoveryWork = try #require(recovery.recoveryTaskForTesting)
        await gate.waitUntilHeld()
        await recoveryWork.value
        #expect(!recovery.isWorking)
        #expect(recovery.orphans.isEmpty)
        let saved = try #require(store.uniqueNote(id: id))
        let file = try #require(saved.fileURL)
        let bytes = try Data(contentsOf: file)
        let decoded = try #require(MarkdownCodec.decode(String(decoding: bytes, as: UTF8.self), fileURL: file))
        #expect(decoded.summaryPending == .initial)
        #expect(decoded.transcript.map(\.source) == [.microphone, .system, .mixed])
        #expect(decoded.transcript.map(\.text) == source.map(\.text))
        #expect(FileManager.default.fileExists(atPath: audio.path) == MeetingCoordinator.keepAudioPreference)
        let session = store.summarySessions.session(for: saved)
        #expect(session.isRunning)
        // Repeated recovery cannot duplicate the scaffold while its model is
        // still working. It is already a regular note, not an orphan.
        recovery.recover(orphan, localeIdentifier: "en-AU")
        #expect(recovery.recoveryTaskForTesting == nil)
        #expect(store.notes.filter { $0.id == id }.count == 1)
        if switchLibrary {
            store.storageURL = other
            store.storageURL = directory
        } else {
            session.cancel()
        }
        #expect(!session.isRunning)
        gate.release()
        await session.waitForCompletion()
        #expect(try Data(contentsOf: file) == bytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: other.path).isEmpty)
    }

    @Test
    func externalReplacementDuringRecoverySummaryWinsWithoutAnotherNoteOrCleanupPass() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(in: directory)
        let id = UUID()
        _ = try writeRecording(id, extensionName: "m4a", in: store.recordingsDirectory())
        let gate = RecordingRecoveryGate()
        defer { gate.release() }
        let recovery = RecordingRecovery(store: store, transcribeAudio: { _, _ in
            [.init(startTime: 0, duration: 3, text: "Original synthetic recovery words.")]
        }, summarizeTranscript: { _, title in
            await gate.hold()
            return MeetingInsights(title: title, summary: "Stale generated words", keyPoints: [], decisions: [], actionItems: [])
        })
        recovery.scan()
        recovery.recover(try #require(recovery.orphans.first), localeIdentifier: "en-AU")
        await gate.waitUntilHeld()
        let saved = try #require(store.uniqueNote(id: id))
        let session = store.summarySessions.session(for: saved)
        let file = try #require(saved.fileURL)
        var external = saved
        external.summary = "The user's externally restored summary."
        external.personalNotes = "Keep this exact Cafe\u{301} writing."
        let bytes = Data(MarkdownCodec.encode(external).utf8)
        try bytes.write(to: file)
        gate.release()
        await session.waitForCompletion()
        #expect(try Data(contentsOf: file) == bytes)
        #expect(store.notes.filter { $0.id == id }.count == 1)
        #expect(session.statusMessage(summaryPending: true) != nil)
        #expect(recovery.cleanupFailures.isEmpty)
    }

    @Test(arguments: RecordingRecoveryPausePoint.beforeSave, [false, true])
    func changingLibrariesDuringRecoveryKeepsEverySourceInItsOriginalFolder(
        pausePoint: RecordingRecoveryPausePoint, switchBack: Bool
    ) async throws {
        let directory = try temporaryDirectory()
        let otherLibrary = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: otherLibrary)
        }
        let store = store(in: directory)
        let recordings = store.recordingsDirectory()
        let id = UUID()
        let capture = try writeRecording(id, extensionName: "mp4", in: recordings)
        let originalCapture = try Data(contentsOf: capture)
        let sidecar = MeetingCoordinator.liveNotesURL(for: id, in: recordings)
        let exactNotes = " \nCafe\u{301} discussion.\n  Keep my own words.\n"
        MeetingCoordinator.writeLiveNotes(exactNotes, to: sidecar)
        let extracted = recordings.appendingPathComponent("\(id.uuidString).m4a")
        let gate = RecordingRecoveryGate()
        var calls: [RecordingRecoveryPausePoint] = []
        let recovery = RecordingRecovery(
            store: store,
            extractAudio: { sources, destination in
                calls.append(.extraction)
                #expect(sources.map { $0.resolvingSymlinksInPath() } == [capture.resolvingSymlinksInPath()])
                #expect(destination.standardizedFileURL == extracted.standardizedFileURL)
                try Data("Synthetic extracted audio".utf8).write(to: destination)
                if pausePoint == .extraction { await gate.hold() }
            },
            transcribeAudio: { url, locale in
                calls.append(.transcription)
                #expect(url.standardizedFileURL == extracted.standardizedFileURL)
                #expect(locale == "en-AU")
                if pausePoint == .transcription { await gate.hold() }
                return [TranscriptSegment(startTime: 0, duration: 3, text: "Synthetic review content.")]
            },
            summarizeTranscript: { _, title in
                calls.append(.summary)
                if pausePoint == .summary { await gate.hold() }
                return MeetingInsights(
                    title: title, summary: "Synthetic summary.",
                    keyPoints: [], decisions: [], actionItems: []
                )
            }
        )
        recovery.scan()
        let orphan = try #require(recovery.orphans.first { $0.id == id })
        recovery.recover(orphan, localeIdentifier: "en-AU")
        let work = try #require(recovery.recoveryTaskForTesting)
        await gate.waitUntilHeld()
        store.storageURL = otherLibrary
        if switchBack { store.storageURL = directory }
        gate.release()
        await work.value

        #expect(!recovery.isWorking)
        #expect(recovery.message == RecordingRecovery.RecoveryError.recordingLocationChanged.localizedDescription)
        #expect(calls == Array(RecordingRecoveryPausePoint.allCases.prefix(pausePoint.rawValue + 1)))
        #expect(store.notes.isEmpty)
        #expect(try Data(contentsOf: capture) == originalCapture)
        #expect(try Data(contentsOf: sidecar) == Data(exactNotes.utf8))
        #expect(try Data(contentsOf: extracted) == Data("Synthetic extracted audio".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [".recordings"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: otherLibrary.path).isEmpty)
    }

    @Test(arguments: RecordingRecoveryPausePoint.beforeSave)
    func restoringANoteDuringRecoveryKeepsItsExactWritingAndEveryRecordingSource(
        pausePoint: RecordingRecoveryPausePoint
    ) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MarkdownStore(noteLoader: { url, cache in
            guard url.standardizedFileURL == directory.standardizedFileURL else {
                return .success((notes: [], issues: []))
            }
            return MarkdownStore.loadNotes(in: url, cache: cache)
        })
        store.storageURL = directory
        let recordings = store.recordingsDirectory()
        let id = UUID()
        let capture = try writeRecording(id, extensionName: "mp4", in: recordings)
        let originalCapture = try Data(contentsOf: capture)
        let sidecar = MeetingCoordinator.liveNotesURL(for: id, in: recordings)
        let strandedNotes = " \nCafe\u{301} discussion.\n  These are still recoverable.\n"
        MeetingCoordinator.writeLiveNotes(strandedNotes, to: sidecar)
        let extracted = recordings.appendingPathComponent("\(id.uuidString).m4a")
        let extractedBytes = Data("Synthetic extracted audio".utf8)
        let gate = RecordingRecoveryGate()
        var calls: [RecordingRecoveryPausePoint] = []
        let recovery = RecordingRecovery(
            store: store,
            extractAudio: { _, destination in
                calls.append(.extraction)
                try extractedBytes.write(to: destination)
                if pausePoint == .extraction { await gate.hold() }
            },
            transcribeAudio: { _, _ in
                calls.append(.transcription)
                if pausePoint == .transcription { await gate.hold() }
                return [TranscriptSegment(startTime: 0, duration: 3, text: "Synthetic review content.")]
            },
            summarizeTranscript: { _, _ in
                calls.append(.summary)
                if pausePoint == .summary { await gate.hold() }
                return MeetingInsights(
                    title: "Recovery must not replace this note", summary: "Synthetic replacement summary.",
                    keyPoints: [], decisions: [], actionItems: []
                )
            }
        )
        recovery.scan()
        recovery.recover(try #require(recovery.orphans.first { $0.id == id }), localeIdentifier: "en-AU")
        let work = try #require(recovery.recoveryTaskForTesting)
        await gate.waitUntilHeld()
        defer { gate.release() }

        // Simulate restoring the original file in Finder, then the normal
        // async reload making its URL and exact revision available to save.
        let restored = MeetingNote(
            id: id, title: "Restored original",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_060), sourceApp: "Manual",
            summary: "The restored summary belongs to the user.",
            personalNotes: "My restored Cafe\u{301} notes.\n\n  Preserve this indentation."
        )
        let restoredURL = directory.appendingPathComponent("Restored original.md")
        let restoredBytes = Data(MarkdownCodec.encode(restored).utf8)
        try restoredBytes.write(to: restoredURL)
        await reloadAndWait(store)
        let loaded = try #require(store.notes.first { $0.id == id })
        #expect(loaded.fileRevision == MeetingNote.contentRevision(restoredBytes))

        gate.release()
        await work.value

        #expect(!recovery.isWorking)
        #expect(recovery.message == RecordingRecovery.RecoveryError.noteAlreadySaved.localizedDescription)
        #expect(calls == Array(RecordingRecoveryPausePoint.allCases.prefix(pausePoint.rawValue + 1)))
        #expect(store.notes == [loaded])
        #expect(store.notes.first?.personalNotes.utf8.elementsEqual(restored.personalNotes.utf8) == true)
        #expect(try Data(contentsOf: restoredURL) == restoredBytes)
        #expect(try Data(contentsOf: capture) == originalCapture)
        #expect(try Data(contentsOf: extracted) == extractedBytes)
        #expect(try Data(contentsOf: sidecar) == Data(strandedNotes.utf8))
        #expect(recovery.cleanupFailures.isEmpty)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
            == [".recordings", "Restored original.md"])
    }

    @Test(arguments: [false, true])
    func aSavedNoteStopsAStaleRecoveryBeforeAnyProcessing(saveBeforeInvocation: Bool) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(in: directory)
        let capture = try writeRecording(UUID(), extensionName: "mp4", in: store.recordingsDirectory())
        let originalCapture = try Data(contentsOf: capture)
        let recovery = RecordingRecovery(
            store: store,
            extractAudio: { _, _ in Issue.record("A saved note must stop recovery before extraction.") },
            transcribeAudio: { _, _ in
                Issue.record("A saved note must stop recovery before transcription.")
                return []
            },
            summarizeTranscript: { _, title in
                Issue.record("A saved note must stop recovery before summarization.")
                return MeetingInsights(title: title, summary: "", keyPoints: [], decisions: [], actionItems: [])
            }
        )
        recovery.scan()
        let orphan = try #require(recovery.orphans.first)
        let restored = MeetingNote(
            id: orphan.id, title: "Already restored",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_060),
            sourceApp: "Manual", summary: "User's original summary.",
            personalNotes: "My own notes."
        )
        if saveBeforeInvocation { _ = try store.save(restored) }
        recovery.recover(orphan, localeIdentifier: "en-AU")
        let work = recovery.recoveryTaskForTesting
        if !saveBeforeInvocation { _ = try store.save(restored) }
        let saved = try #require(store.notes.first { $0.id == orphan.id })
        let savedBytes = try Data(contentsOf: #require(saved.fileURL))
        await work?.value

        #expect(!recovery.isWorking)
        #expect(recovery.recoveryTaskForTesting == nil)
        #expect(recovery.message == RecordingRecovery.RecoveryError.noteAlreadySaved.localizedDescription)
        #expect(store.notes == [saved])
        #expect(try Data(contentsOf: #require(saved.fileURL)) == savedBytes)
        #expect(try Data(contentsOf: capture) == originalCapture)
        #expect(recovery.cleanupFailures.isEmpty)
    }

    @Test(arguments: [false, true])
    func aStaleRecoverySelectionCannotStartInAnotherLibrary(switchBeforeInvocation: Bool) async throws {
        let directory = try temporaryDirectory()
        let otherLibrary = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: otherLibrary)
        }
        let store = store(in: directory)
        let capture = try writeRecording(UUID(), extensionName: "mp4", in: store.recordingsDirectory())
        let recovery = RecordingRecovery(
            store: store,
            extractAudio: { _, _ in Issue.record("A stale selection must not reach extraction.") },
            transcribeAudio: { _, _ in
                Issue.record("A stale selection must not reach transcription.")
                return []
            },
            summarizeTranscript: { _, title in
                Issue.record("A stale selection must not reach the model.")
                return MeetingInsights(title: title, summary: "", keyPoints: [], decisions: [], actionItems: [])
            }
        )
        recovery.scan()
        let orphan = try #require(recovery.orphans.first)
        if switchBeforeInvocation { store.storageURL = otherLibrary }
        recovery.recover(orphan, localeIdentifier: "en-AU")
        let work = recovery.recoveryTaskForTesting
        if !switchBeforeInvocation { store.storageURL = otherLibrary }
        await work?.value

        #expect(recovery.recoveryTaskForTesting == nil)
        #expect(!recovery.isWorking)
        #expect(recovery.message == RecordingRecovery.RecoveryError.recordingLocationChanged.localizedDescription)
        #expect(FileManager.default.fileExists(atPath: capture.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: otherLibrary.path).isEmpty)
    }

    @Test
    func reassigningTheSameLibraryStillRecoversTypedNotesAndCleansTheirSidecar() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(in: directory)
        let recordings = store.recordingsDirectory()
        let id = UUID()
        let capture = try writeRecording(id, extensionName: "mp4", in: recordings)
        let audio = try writeRecording(id, extensionName: "m4a", in: recordings)
        let sidecar = MeetingCoordinator.liveNotesURL(for: id, in: recordings)
        let exactNotes = "Cafe\u{301} discussion.\n\n  Keep my indentation."
        MeetingCoordinator.writeLiveNotes(exactNotes, to: sidecar)
        let gate = RecordingRecoveryGate()
        let recovery = RecordingRecovery(
            store: store,
            extractAudio: { _, _ in Issue.record("Existing extracted audio must be reused.") },
            transcribeAudio: { url, _ in
                #expect(url.standardizedFileURL == audio.standardizedFileURL)
                return [TranscriptSegment(startTime: 0, duration: 3, text: "Synthetic review content.")]
            },
            summarizeTranscript: { _, _ in
                await gate.hold()
                return MeetingInsights(
                    title: "Synthetic recovery", summary: "Synthetic summary.",
                    keyPoints: [], decisions: [], actionItems: []
                )
            }
        )
        recovery.scan()
        recovery.recover(try #require(recovery.orphans.first { $0.id == id }), localeIdentifier: "en-AU")
        let work = try #require(recovery.recoveryTaskForTesting)
        await gate.waitUntilHeld()
        store.storageURL = directory
        gate.release()
        await work.value
        if let saved = store.uniqueNote(id: id) {
            await store.summarySessions.session(for: saved).waitForCompletion()
        }

        let saved = try #require(store.notes.first { $0.id == id })
        let noteURL = try #require(saved.fileURL)
        #expect(noteURL.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL)
        #expect(saved.personalNotes.utf8.elementsEqual(exactNotes.utf8))
        let markdown = try String(contentsOf: noteURL, encoding: .utf8)
        let persisted = try #require(MarkdownCodec.decode(markdown, fileURL: noteURL))
        #expect(persisted.personalNotes.utf8.elementsEqual(exactNotes.utf8))
        #expect(!FileManager.default.fileExists(atPath: sidecar.path))
        #expect(!FileManager.default.fileExists(atPath: capture.path))
        #expect(recovery.orphans.isEmpty)
    }

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

    @Test
    func aSavedNoteDoesNotHideAFileWhoseRecoveryCleanupFailed() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(in: directory)
        let recovery = RecordingRecovery(store: store)
        let id = UUID()
        let note = MeetingNote(
            id: id,
            title: "Recovered note",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_060),
            sourceApp: "Recovered",
            summary: "The note was saved, but cleanup failed."
        )
        _ = try store.save(note)
        let leftover = try writeRecording(
            id,
            extensionName: "mp4",
            in: store.recordingsDirectory()
        )

        recovery.retainCleanupFailure(
            for: note,
            recordedAt: note.startedAt,
            urls: [leftover]
        )
        recovery.scan()

        #expect(recovery.orphans.isEmpty)
        #expect(recovery.cleanupFailures.map(\.urls) == [[leftover]])
        #expect(recovery.message?.contains("could not remove") == true)
    }

    @Test
    func failedRecoveryCleanupReturnsTheFilesThatMustRemainVisible() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("first.mp4")
        let second = directory.appendingPathComponent("second.mp4")
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)
        struct CleanupFailed: Error {}

        let failures = RecordingRecovery.cleanupFiles(
            [first, second],
            fileExists: { FileManager.default.fileExists(atPath: $0.path) },
            remove: { url in
                if url == second {
                    throw CleanupFailed()
                }
                try FileManager.default.removeItem(at: url)
            }
        )

        #expect(failures == [second])
        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.path))
    }

    // MARK: Automatic retention must not consume recovery input

    private var retentionNow: Date {
        Date(timeIntervalSince1970: 1_800_000_000)
    }

    private func completedNote(in store: MarkdownStore) throws -> MeetingNote {
        try store.save(MeetingNote(
            title: "Finished meeting \(UUID().uuidString)",
            startedAt: retentionNow.addingTimeInterval(-3_600),
            endedAt: retentionNow,
            sourceApp: "Synthetic",
            summary: "A safely saved conversation."
        ))
    }

    private func expire(_ urls: [URL]) throws {
        for url in urls {
            try FileManager.default.setAttributes(
                [.modificationDate: retentionNow.addingTimeInterval(-100 * 86_400)],
                ofItemAtPath: url.path
            )
        }
    }

    @Test
    func retentionExpiresCompletedAudioButPreservesRecoverySources() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(in: directory)
        let saved = try completedNote(in: store)
        let recordings = store.recordingsDirectory()
        let keptAudio = try writeRecording(saved.id, extensionName: "m4a", in: recordings)
        let orphanID = UUID()
        let sources = try ["m4a", "mp4", "part-2.mp4", "part-12.mp4"].map {
            try writeRecording(orphanID, extensionName: $0, in: recordings)
        }
        let unknown = recordings.appendingPathComponent("unrecognized.m4a")
        try Data("unclassified audio".utf8).write(to: unknown)
        try expire([keptAudio, unknown] + sources)
        var trashed: [URL] = []

        let removed = AudioRetention.sweep(
            store: store, now: retentionNow, enabled: true, retentionDays: 90
        ) { url in
            trashed.append(url)
            try FileManager.default.removeItem(at: url)
        }

        #expect(removed == [keptAudio.lastPathComponent])
        #expect(trashed.map(\.lastPathComponent) == removed)
        #expect(!FileManager.default.fileExists(atPath: keptAudio.path))
        #expect(([unknown] + sources).allSatisfy {
            FileManager.default.fileExists(atPath: $0.path)
        })
        #expect(FileManager.default.fileExists(atPath: try #require(saved.fileURL).path))
        let recovery = RecordingRecovery(store: store)
        recovery.scan()
        #expect(recovery.orphans.map(\.id) == [orphanID])
        #expect(recovery.orphans.first?.urls.count == sources.count)
    }

    @Test
    func anUnfinishedSittingProtectsAudioEvenWhenItsNoteWasAlreadySaved() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(in: directory)
        let saved = try completedNote(in: store)
        let recordings = store.recordingsDirectory()
        let audio = try writeRecording(saved.id, extensionName: "m4a", in: recordings)
        let capture = try writeRecording(saved.id, extensionName: "part-12.mp4", in: recordings)
        let partialAudio = try writeRecording(saved.id, extensionName: "part-12.m4a", in: recordings)
        try expire([audio, capture, partialAudio])
        var attempts: [URL] = []

        let removed = AudioRetention.sweep(
            store: store, now: retentionNow, enabled: true, retentionDays: 90
        ) { attempts.append($0) }

        #expect(removed.isEmpty)
        #expect(attempts.isEmpty)
        #expect([audio, capture, partialAudio].allSatisfy {
            FileManager.default.fileExists(atPath: $0.path)
        })
    }

    @Test
    func retentionLeavesAudioAloneWhenTheSavedDocumentDisappearsOrChanges() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(in: directory)
        let missing = try completedNote(in: store)
        let changed = try completedNote(in: store)
        let recordings = store.recordingsDirectory()
        let audio = try [missing, changed].map {
            try writeRecording($0.id, extensionName: "m4a", in: recordings)
        }
        try expire(audio)
        try FileManager.default.removeItem(at: try #require(missing.fileURL))
        try Data("An unfinished external replacement.".utf8)
            .write(to: try #require(changed.fileURL))
        var attempts: [URL] = []

        let removed = AudioRetention.sweep(
            store: store, now: retentionNow, enabled: true, retentionDays: 90
        ) { attempts.append($0) }

        #expect(removed.isEmpty)
        #expect(attempts.isEmpty)
        #expect(audio.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    @Test
    func retentionDoesNotUseNotesFromThePreviousLibrary() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(in: directory)
        let saved = try completedNote(in: store)
        let otherLibrary = directory.appendingPathComponent("other", isDirectory: true)
        store.storageURL = otherLibrary
        let audio = try writeRecording(
            saved.id, extensionName: "m4a", in: store.recordingsDirectory()
        )
        try expire([audio])
        var attempts: [URL] = []

        let removed = AudioRetention.sweep(
            store: store, now: retentionNow, enabled: true, retentionDays: 90
        ) { attempts.append($0) }

        #expect(removed.isEmpty)
        #expect(attempts.isEmpty)
        #expect(FileManager.default.fileExists(atPath: audio.path))
    }

    @Test
    func disabledRetentionAndAudioInsideItsWindowAreUntouched() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(in: directory)
        let saved = try completedNote(in: store)
        let audio = try writeRecording(
            saved.id, extensionName: "m4a", in: store.recordingsDirectory()
        )
        try expire([audio])
        var attempts: [URL] = []

        #expect(AudioRetention.sweep(
            store: store, now: retentionNow, enabled: false, retentionDays: 90,
            trashItem: { attempts.append($0) }
        ).isEmpty)
        try FileManager.default.setAttributes(
            [.modificationDate: retentionNow.addingTimeInterval(-30 * 86_400)],
            ofItemAtPath: audio.path
        )
        #expect(AudioRetention.sweep(
            store: store, now: retentionNow, enabled: true, retentionDays: 90,
            trashItem: { attempts.append($0) }
        ).isEmpty)

        #expect(attempts.isEmpty)
        #expect(FileManager.default.fileExists(atPath: audio.path))
    }

    @Test
    func retentionWaitsForLibraryLoadingAndNeverUnlinksAfterATrashFailure() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(in: directory)
        let saved = try completedNote(in: store)
        let audio = try writeRecording(
            saved.id, extensionName: "m4a", in: store.recordingsDirectory()
        )
        try expire([audio])
        struct TrashUnavailable: Error {}
        var attempts: [URL] = []
        #expect(AudioRetention.sweep(
            store: store, now: retentionNow, enabled: true, retentionDays: 90,
            trashItem: { url in
                attempts.append(url)
                throw TrashUnavailable()
            }
        ).isEmpty)
        #expect(attempts.count == 1)
        #expect(FileManager.default.fileExists(atPath: audio.path))

        store.reload()
        #expect(store.isLoading)
        #expect(AudioRetention.sweep(
            store: store, now: retentionNow, enabled: true, retentionDays: 90,
            trashItem: { attempts.append($0) }
        ).isEmpty)
        #expect(attempts.count == 1)
    }

    @Test
    func explicitlyDeletingExpiredRecoveryAudioStillMovesEverySourceToTrash() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(in: directory)
        _ = try completedNote(in: store)
        let id = UUID()
        let recordings = store.recordingsDirectory()
        let sources = try ["m4a", "mp4", "part-2.mp4"].map {
            try writeRecording(id, extensionName: $0, in: recordings)
        }
        try expire(sources)
        #expect(AudioRetention.sweep(
            store: store, now: retentionNow, enabled: true, retentionDays: 90,
            trashItem: { _ in Issue.record("Recovery input must not expire.") }
        ).isEmpty)
        var trashed: [String] = []
        let recovery = RecordingRecovery(store: store, trashItem: { url in
            trashed.append(url.lastPathComponent)
            try FileManager.default.removeItem(at: url)
        })
        recovery.scan()

        recovery.delete(try #require(recovery.orphans.first))

        #expect(Set(trashed) == Set(sources.map(\.lastPathComponent)))
        #expect(recovery.orphans.isEmpty)
        #expect(recovery.message == nil)
    }
}

enum RecordingRecoveryPausePoint: Int, CaseIterable, Sendable {
    case extraction, transcription, summary

    // Summarization is now after the durable save and artifact handoff.
    // Its cancellation and ownership tests exercise the saved note below.
    static let beforeSave: [Self] = [.extraction, .transcription]
}

/// Gates synthetic recovery work without a provider, polling or a timing race.
@MainActor
private final class RecordingRecoveryGate {
    private var held: CheckedContinuation<Void, Never>?
    private var waiting: CheckedContinuation<Void, Never>?

    func hold() async {
        await withCheckedContinuation { continuation in
            held = continuation
            waiting?.resume()
            waiting = nil
        }
    }

    func waitUntilHeld() async {
        guard held == nil else { return }
        await withCheckedContinuation { waiting = $0 }
    }

    func release() {
        held?.resume()
        held = nil
    }
}
