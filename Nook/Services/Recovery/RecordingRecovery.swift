import AppKit
import Combine
import Foundation

/// A recording left in the recordings folder with no note to show for it.
///
/// These accumulate whenever processing cannot finish: the audio is kept
/// deliberately, because when transcription or saving fails the recording is
/// the only copy of the conversation that exists. Without somewhere to see
/// them, "kept" means "hidden", which is its own kind of loss and sits badly
/// with an app that promises audio does not linger.
struct OrphanedRecording: Identifiable, Hashable, Sendable {
    let id: UUID
    /// Every file belonging to this recording, including paused segments.
    let urls: [URL]
    let recordedAt: Date
    let byteSize: Int64

    var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file)
    }

    var dateLabel: String {
        recordedAt.formatted(date: .abbreviated, time: .shortened)
    }

    /// Audio already extracted from the capture, if a previous attempt got
    /// that far. Reusing it skips the slowest part of recovering the note.
    var extractedAudio: URL? {
        urls.first { $0.pathExtension.lowercased() == "m4a" }
    }

    var captures: [URL] {
        urls.filter { $0.pathExtension.lowercased() == "mp4" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// True when extracted audio is all that is left, with no capture beside
    /// it.
    ///
    /// Two different histories end up looking like this: a recording whose
    /// write-up failed after extraction, and audio kept for a note the user
    /// has since deleted. Nothing in the folder tells them apart, so the pane
    /// says as much rather than claiming the recording failed.
    var isAudioOnly: Bool {
        captures.isEmpty && extractedAudio != nil
    }
}

/// Files that could not be removed after their note was saved.
///
/// A saved note's identifier normally keeps its audio out of the orphan scan.
/// Keeping this separate lets a failed cleanup remain visible without treating
/// a successfully retained `.m4a` as stranded audio.
struct RecoveryCleanupFailure: Identifiable, Hashable, Sendable {
    let id: UUID
    let noteTitle: String
    let urls: [URL]
    let recordedAt: Date
    let byteSize: Int64

    var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file)
    }

    var dateLabel: String {
        recordedAt.formatted(date: .abbreviated, time: .shortened)
    }
}

/// Finds, recovers, and removes recordings that never became notes.
@MainActor
final class RecordingRecovery: ObservableObject {
    @Published private(set) var orphans: [OrphanedRecording] = []
    @Published private(set) var cleanupFailures: [RecoveryCleanupFailure] = []
    @Published private(set) var isWorking = false
    @Published private(set) var message: String?

    /// A recording something else is still using.
    ///
    /// A meeting being recorded right now looks exactly like a stranded one:
    /// audio in the folder with no note beside it. Offering a Delete button
    /// for the meeting the user is still in is the worst thing this pane could
    /// do, so whoever owns the live recording says so here. `.inFlight(nil)`
    /// is the honest answer when the identifier is not known: the list stays
    /// empty for the length of the meeting rather than being wrong about it.
    enum ActiveRecording: Equatable, Sendable {
        case none
        case inFlight(UUID?)
    }

    var activeRecording: ActiveRecording = .none {
        didSet {
            guard oldValue != activeRecording else { return }
            scan()
        }
    }

    private let store: MarkdownStore
    private let trashItem: (URL) throws -> Void
    private var reloadCancellable: AnyCancellable?
    private let transcriber = TranscriptionService()
    private let summarizer = SummaryService()

    init(
        store: MarkdownStore,
        trashItem: @escaping (URL) throws -> Void = { url in
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
    ) {
        self.store = store
        self.trashItem = trashItem
        // MarkdownStore publishes notes before it clears isLoading. Scanning
        // from that transition is the one place that cannot observe the old
        // note set after an asynchronous reload.
        reloadCancellable = store.$isLoading
            .removeDuplicates()
            .filter { !$0 }
            .sink { [weak self] _ in
                self?.scan()
            }
    }

    var totalSizeLabel: String {
        ByteCountFormatter.string(
            fromByteCount: orphans.reduce(0) { $0 + $1.byteSize }
                + cleanupFailures.reduce(0) { $0 + $1.byteSize },
            countStyle: .file
        )
    }

    /// Lists recordings whose meeting never produced a note.
    ///
    /// A recording is named for the note it was going to become, so anything
    /// whose identifier matches a saved note has already served its purpose and
    /// is left alone: it belongs to the user's audio-retention choice, not
    /// here. A recording still being made or still being written up is not
    /// stranded either, and is excluded by `activeRecording`.
    func scan() {
        let manager = FileManager.default
        reconcileCleanupFailures(using: manager)
        if case .inFlight(let activeID) = activeRecording, activeID == nil {
            orphans = []
            return
        }
        var inFlightIDs: Set<UUID> = []
        if case .inFlight(let activeID) = activeRecording, let activeID {
            inFlightIDs.insert(activeID)
        }
        let directory = store.recordingsDirectory()
        guard let entries = try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        ) else {
            orphans = []
            return
        }

        let savedIDs = Set(store.notes.map(\.id))
        var grouped: [UUID: [URL]] = [:]
        for url in entries {
            let extensionName = url.pathExtension.lowercased()
            guard extensionName == "mp4" || extensionName == "m4a" else {
                continue
            }
            // "<uuid>.mp4" and "<uuid>.part-2.mp4" belong to the same meeting.
            let stem = url.deletingPathExtension().lastPathComponent
                .components(separatedBy: ".part-").first ?? ""
            guard let id = UUID(uuidString: stem),
                  !savedIDs.contains(id),
                  !inFlightIDs.contains(id)
            else {
                continue
            }
            grouped[id, default: []].append(url)
        }

        orphans = grouped.map { id, urls in
            let values = urls.compactMap {
                try? $0.resourceValues(
                    forKeys: [.contentModificationDateKey, .fileSizeKey]
                )
            }
            return OrphanedRecording(
                id: id,
                urls: urls,
                recordedAt: values.compactMap(\.contentModificationDate).min()
                    ?? .distantPast,
                byteSize: values.reduce(0) { $0 + Int64($1.fileSize ?? 0) }
            )
        }
        .sorted { $0.recordedAt > $1.recordedAt }
    }

    /// Removes entries whose failed files have since gone away in Finder.
    private func reconcileCleanupFailures(using manager: FileManager) {
        cleanupFailures = cleanupFailures.compactMap { failure in
            let remaining = failure.urls.filter {
                manager.fileExists(atPath: $0.path)
            }
            guard !remaining.isEmpty else { return nil }
            let byteSize = remaining.reduce(0) { total, url in
                total + Int64(
                    (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
                        ?? 0
                )
            }
            return RecoveryCleanupFailure(
                id: failure.id,
                noteTitle: failure.noteTitle,
                urls: remaining,
                recordedAt: failure.recordedAt,
                byteSize: byteSize
            )
        }
    }

    func reveal(_ orphan: OrphanedRecording) {
        NSWorkspace.shared.activateFileViewerSelecting(orphan.urls)
    }

    func reveal(_ failure: RecoveryCleanupFailure) {
        NSWorkspace.shared.activateFileViewerSelecting(failure.urls)
    }

    /// Moves a stranded recording to the Trash.
    ///
    /// This pane exists because the audio was kept so nothing was lost, and
    /// unlinking it here would be the one place Nook takes that back. Trashing
    /// keeps the deletion reversible from the Finder, exactly as deleting a
    /// note does. If a volume has no Trash, the recording stays in place.
    func delete(_ orphan: OrphanedRecording) {
        let manager = FileManager.default
        var failedURLs: [URL] = []
        for url in orphan.urls where manager.fileExists(atPath: url.path) {
            do {
                try trashItem(url)
            } catch {
                failedURLs.append(url)
            }
        }
        if failedURLs.isEmpty {
            message = nil
        } else {
            let names = failedURLs.map(\.lastPathComponent)
                .joined(separator: ", ")
            let noun = failedURLs.count == 1 ? "file was" : "files were"
            message = "Could not move \(names) to the Trash. The \(noun) "
                + "left in place. Try again after making the Trash available."
        }
        scan()
    }

    /// Turns a stranded recording into the note it was meant to be.
    ///
    /// The same pipeline a meeting goes through, run late. Files are removed
    /// only once the note is safely on disk, so a failure here leaves the
    /// recording exactly where it was.
    func recover(_ orphan: OrphanedRecording, localeIdentifier: String) {
        guard !isWorking else { return }
        isWorking = true
        message = nil

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isWorking = false }
            do {
                let audioURL: URL
                if let existing = orphan.extractedAudio {
                    audioURL = existing
                } else {
                    guard !orphan.captures.isEmpty else {
                        throw RecoveryError.nothingToRecover
                    }
                    // Named for the note rather than for whichever capture
                    // segment happened to sort first. Retention looks kept
                    // audio up by the note's identifier, so a meeting whose
                    // first segment was a resumed part would otherwise extract
                    // to a name nothing could find again.
                    let destination = self.store.recordingsDirectory()
                        .appendingPathComponent("\(orphan.id.uuidString).m4a")
                    try await AudioExtractor.extractAudio(
                        from: orphan.captures,
                        to: destination
                    )
                    audioURL = destination
                }

                let transcript = TranscriptAssembler.coalesce(
                    try await self.transcriber.transcribe(
                        audioURL: audioURL,
                        localeIdentifier: localeIdentifier
                    )
                )
                guard !transcript.isEmpty else {
                    throw RecoveryError.noSpeechFound
                }

                let fallbackTitle = "Recovered meeting \(orphan.dateLabel)"
                let insights = await self.summarizer.summarize(
                    transcript: transcript,
                    fallbackTitle: fallbackTitle
                )
                let recordingsDirectory = self.store.recordingsDirectory()
                // Anything typed into the meeting's notes while it was running
                // was written beside the recording. It is the only part of a
                // stranded meeting the user wrote themselves, and rebuilding
                // the transcript and summary without it would recover
                // everything except the part that was theirs.
                let liveNotes = MeetingCoordinator.recoverableLiveNotes(
                    for: orphan.id,
                    in: recordingsDirectory
                )
                let note = MeetingNote(
                    id: orphan.id,
                    title: insights.title,
                    startedAt: orphan.recordedAt,
                    endedAt: orphan.recordedAt,
                    sourceApp: "Recovered",
                    summary: insights.summary,
                    keyPoints: insights.keyPoints,
                    decisions: insights.decisions,
                    actionItems: insights.actionItems,
                    personalNotes: liveNotes,
                    transcript: transcript
                )
                _ = try self.store.save(note)

                // With retention on, the extracted audio is this note's kept
                // audio, exactly as it would be had the meeting finished
                // normally. Removing every source file here deleted it, so
                // recovering a meeting was also the act that threw away the
                // recording the user had asked Nook to keep.
                let cleanupURLs = Self.filesToRemoveAfterRecovery(
                    sources: orphan.urls,
                    extractedAudio: audioURL,
                    liveNotes: MeetingCoordinator.liveNotesURL(
                        for: orphan.id,
                        in: recordingsDirectory
                    ),
                    keepAudio: MeetingCoordinator.keepAudioPreference
                )
                let manager = FileManager.default
                let failedCleanupURLs = Self.cleanupFiles(
                    cleanupURLs,
                    fileExists: { manager.fileExists(atPath: $0.path) },
                    remove: { try manager.removeItem(at: $0) }
                )
                if failedCleanupURLs.isEmpty {
                    self.cleanupFailures.removeAll { $0.id == note.id }
                    self.message = "Saved “\(note.title)”."
                } else {
                    self.retainCleanupFailure(
                        for: note,
                        recordedAt: orphan.recordedAt,
                        urls: failedCleanupURLs
                    )
                }
                self.scan()
            } catch {
                self.message = error.localizedDescription
            }
        }
    }

    /// Keeps failed post-recovery cleanup visible until the files are gone.
    ///
    /// The saved note's identifier would otherwise make a second scan treat
    /// these paths as ordinary retained audio, even when cleanup was requested
    /// and failed.
    func retainCleanupFailure(
        for note: MeetingNote,
        recordedAt: Date,
        urls: [URL]
    ) {
        guard !urls.isEmpty else { return }
        let failure = Self.cleanupFailure(
            for: note,
            recordedAt: recordedAt,
            urls: urls
        )
        cleanupFailures.removeAll { $0.id == note.id }
        cleanupFailures.append(failure)
        message = Self.cleanupFailureMessage(failure)
    }

    private static func cleanupFailure(
        for note: MeetingNote,
        recordedAt: Date,
        urls: [URL]
    ) -> RecoveryCleanupFailure {
        let byteSize = urls.reduce(0) { total, url in
            total + Int64(
                (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            )
        }
        return RecoveryCleanupFailure(
            id: note.id,
            noteTitle: note.title,
            urls: urls,
            recordedAt: recordedAt,
            byteSize: byteSize
        )
    }

    /// Removes files that no longer belong in the recordings folder and keeps
    /// every failed path for the caller to surface. The closures make the
    /// failure branch deterministic without touching a user's files in tests.
    static func cleanupFiles(
        _ urls: Set<URL>,
        fileExists: (URL) -> Bool,
        remove: (URL) throws -> Void
    ) -> [URL] {
        urls.sorted { $0.path < $1.path }.filter { url in
            guard fileExists(url) else { return false }
            do {
                try remove(url)
                return false
            } catch {
                return true
            }
        }
    }

    private static func cleanupFailureMessage(
        _ failure: RecoveryCleanupFailure
    ) -> String {
        let names = failure.urls.map(\.lastPathComponent)
            .joined(separator: ", ")
        let noun = failure.urls.count == 1 ? "file remains" : "files remain"
        return "Saved “\(failure.noteTitle)”, but could not remove \(names). "
            + "The \(noun) in Nook’s recordings folder. Use Reveal to inspect them."
    }

    /// What a finished recovery no longer needs on disk.
    ///
    /// Kept audio is not on the list. With retention on, the extracted `.m4a`
    /// becomes this note's audio exactly as it would have had the meeting
    /// finished normally, and removing every source file here meant recovering
    /// a meeting was also the act that destroyed the recording the user had
    /// asked Nook to keep.
    static func filesToRemoveAfterRecovery(
        sources: [URL],
        extractedAudio: URL,
        liveNotes: URL,
        keepAudio: Bool
    ) -> Set<URL> {
        var removable = Set(sources.map(\.standardizedFileURL))
        // Extracted during this recovery, so the scan never listed it.
        removable.insert(extractedAudio.standardizedFileURL)
        // The typed notes are inside the note now.
        removable.insert(liveNotes.standardizedFileURL)
        if keepAudio {
            removable.remove(extractedAudio.standardizedFileURL)
        }
        return removable
    }

    enum RecoveryError: LocalizedError {
        case nothingToRecover
        case noSpeechFound

        var errorDescription: String? {
            switch self {
            case .nothingToRecover:
                "That recording has no audio Nook can read."
            case .noSpeechFound:
                "No speech was found in that recording, so there is nothing to write down."
            }
        }
    }
}
