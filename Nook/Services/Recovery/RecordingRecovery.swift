import AppKit
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

/// Finds, recovers, and removes recordings that never became notes.
@MainActor
final class RecordingRecovery: ObservableObject {
    @Published private(set) var orphans: [OrphanedRecording] = []
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
    private let transcriber = TranscriptionService()
    private let summarizer = SummaryService()

    init(store: MarkdownStore) {
        self.store = store
    }

    var totalSizeLabel: String {
        ByteCountFormatter.string(
            fromByteCount: orphans.reduce(0) { $0 + $1.byteSize },
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
        if case .inFlight(let activeID) = activeRecording, activeID == nil {
            orphans = []
            return
        }
        var inFlightIDs: Set<UUID> = []
        if case .inFlight(let activeID) = activeRecording, let activeID {
            inFlightIDs.insert(activeID)
        }
        let directory = store.recordingsDirectory()
        let manager = FileManager.default
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

    func reveal(_ orphan: OrphanedRecording) {
        guard let first = orphan.urls.first else { return }
        NSWorkspace.shared.activateFileViewerSelecting([first])
    }

    /// Moves a stranded recording to the Trash.
    ///
    /// This pane exists because the audio was kept so nothing was lost, and
    /// unlinking it here would be the one place Nook takes that back. Trashing
    /// keeps the deletion reversible from the Finder, exactly as deleting a
    /// note does. Volumes without a Trash still deserve a working delete.
    func delete(_ orphan: OrphanedRecording) {
        let manager = FileManager.default
        var failure: String?
        for url in orphan.urls where manager.fileExists(atPath: url.path) {
            do {
                try manager.trashItem(at: url, resultingItemURL: nil)
            } catch {
                do {
                    try manager.removeItem(at: url)
                } catch {
                    failure = failure
                        ?? "Couldn’t remove \(url.lastPathComponent): "
                            + error.localizedDescription
                }
            }
        }
        message = failure
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
                    let destination = orphan.captures[0]
                        .deletingPathExtension()
                        .appendingPathExtension("m4a")
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
                    transcript: transcript
                )
                _ = try self.store.save(note)

                for url in orphan.urls {
                    try? FileManager.default.removeItem(at: url)
                }
                self.message = "Saved “\(note.title)”."
                self.scan()
            } catch {
                self.message = error.localizedDescription
            }
        }
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
