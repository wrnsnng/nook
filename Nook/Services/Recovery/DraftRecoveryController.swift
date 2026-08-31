import AppKit
import Darwin
import Foundation

/// A recovered checkpoint is evidence of unfinished writing, never authority
/// to overwrite its former note. Every library write below creates a new file.
@MainActor
final class DraftRecoveryController: ObservableObject {
    typealias WriteNew = @Sendable (URL, Data) async throws -> Void
    typealias ReadFile = @Sendable (URL) async throws -> Data

    @Published private(set) var isWorking = false
    @Published private(set) var message: String?

    let journal: DraftJournal
    let store: MarkdownStore
    private let writeNew: WriteNew
    private let readFile: ReadFile

    init(
        journal: DraftJournal,
        store: MarkdownStore,
        writeNew: @escaping WriteNew = { url, data in
            try await Task.detached(priority: .userInitiated) {
                try DraftRecoveryFiles.writeNew(data, to: url)
            }.value
        },
        readFile: @escaping ReadFile = { url in
            try await Task.detached(priority: .userInitiated) {
                try DraftRecoveryFiles.readRegularFile(at: url)
            }.value
        }
    ) {
        self.journal = journal
        self.store = store
        self.writeNew = writeNew
        self.readFile = readFile
    }

    var destinationDirectory: URL {
        store.storageURL.standardizedFileURL.resolvingSymlinksInPath()
    }

    func draft(id: UUID) -> DraftCheckpoint? {
        journal.recoveredDrafts.first { $0.id == id }
    }

    /// A completed save may have survived a crash before checkpoint cleanup.
    /// Reconciliation reads only the recorded destination; it never writes to a
    /// path supplied by a recovery record or guesses based on identical text.
    func reconcileCompletedDrafts() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        for checkpoint in journal.recoveredDrafts where checkpoint.completion != nil {
            do {
                guard let completion = checkpoint.completion,
                      try await verifies(completion) else { continue }
                guard Self.matchesSnapshot(draft(id: checkpoint.id), checkpoint) else { continue }
                try await journal.remove(checkpoint.id, toTrash: false)
            } catch {
                message = "A saved recovery could not be verified or its recovery copy could not be removed. The copy has been kept."
            }
        }
    }

    func retry() async {
        guard !isWorking else { return }
        isWorking = true
        message = nil
        journal.retry()
        await journal.flush()
        await journal.scan()
        isWorking = false
        await reconcileCompletedDrafts()
    }

    @discardableResult
    func saveAsNewNote(
        draftID: UUID,
        destinationDirectory displayedDirectory: URL,
        expectedCheckpoint: DraftCheckpoint? = nil
    ) async throws -> URL {
        guard !isWorking else { throw DraftRecoveryError.busy }
        guard var checkpoint = draft(id: draftID) else {
            throw DraftRecoveryError.noLongerAvailable
        }
        try Self.checkPreview(expectedCheckpoint, matches: checkpoint)
        let directory = displayedDirectory.standardizedFileURL
            .resolvingSymlinksInPath()
        guard directory == destinationDirectory else {
            throw DraftRecoveryError.libraryChanged
        }
        isWorking = true
        message = nil
        defer { isWorking = false }

        // A retry after cleanup failure completes the previous transaction.
        // A changed or unreadable result is not proof of completion, and must
        // not silently produce a duplicate under another identity.
        if let completion = checkpoint.completion {
            let wasOriginalEdit = completion.targetPath == checkpoint.originalFilePath
                && completion.noteID == checkpoint.noteID
            // An inaccessible original must not prevent keeping its unfinished
            // edit elsewhere. A previously created recovered note remains
            // strict because another new file could duplicate that result.
            let completed: Bool
            if wasOriginalEdit {
                completed = (try? await verifies(completion)) == true
            } else {
                completed = try await verifies(completion)
            }
            if completed {
                try await removeAfterSave(checkpoint)
                return URL(fileURLWithPath: completion.targetPath)
            }
            let oldDestination = URL(fileURLWithPath: completion.targetPath)
            // An ordinary editor may checkpoint intent and then refuse to
            // save because its original changed. That is still unfinished
            // writing, not a previously created recovered note. Its recovery
            // can create a new identity while leaving the original intact.
            guard wasOriginalEdit || DraftRecoveryFiles.isMissing(oldDestination) else {
                throw DraftRecoveryError.previousSaveChanged
            }
        }

        let newID = UUID()
        let sourceCheckpoint = checkpoint
        let prepared = try await Task.detached(priority: .userInitiated) {
            let source = try Self.newNoteSource(from: sourceCheckpoint, id: newID)
            guard MarkdownCodec.decode(source)?.id == newID else {
                throw DraftRecoveryError.readBackFailed
            }
            let bytes = Data(source.utf8)
            return (bytes: bytes, revision: MeetingNote.contentRevision(bytes))
        }.value
        let bytes = prepared.bytes
        let destination = directory.appendingPathComponent(
            "Recovered-\(newID.uuidString).md"
        )
        let completion = DraftCompletion(
            targetPath: destination.path,
            noteID: newID,
            revision: prepared.revision
        )
        guard Self.matchesSnapshot(draft(id: draftID), checkpoint),
              directory == destinationDirectory else {
            throw DraftRecoveryError.libraryChanged
        }
        checkpoint.completion = completion
        // Persist intent first. If the process stops after publishing the
        // note, its exact identity and bytes can settle cleanup on restart.
        try await journal.persistNow(checkpoint)
        guard let persistedCheckpoint = draft(id: draftID) else {
            throw DraftRecoveryError.noLongerAvailable
        }
        // The journal stamps the completed disk write, rather than the time
        // the request was queued. Every other field must still match intent.
        var comparableCheckpoint = persistedCheckpoint
        comparableCheckpoint.checkpointedAt = checkpoint.checkpointedAt
        guard Self.matchesSnapshot(comparableCheckpoint, checkpoint),
              directory == destinationDirectory else {
            throw DraftRecoveryError.libraryChanged
        }
        checkpoint = persistedCheckpoint
        try await writeNew(destination, bytes)
        let readBack = try await readFile(destination)
        guard readBack == bytes else {
            throw DraftRecoveryError.readBackFailed
        }
        // The selected folder may have changed while disk I/O was underway.
        // The write still belongs to the displayed, captured destination.
        if directory == destinationDirectory { store.reload() }
        try await removeAfterSave(checkpoint)
        return destination
    }

    func exportSource(
        draftID: UUID,
        to destination: URL,
        expectedCheckpoint: DraftCheckpoint? = nil
    ) async throws {
        guard !isWorking else { throw DraftRecoveryError.busy }
        guard let checkpoint = draft(id: draftID) else {
            throw DraftRecoveryError.noLongerAvailable
        }
        try Self.checkPreview(expectedCheckpoint, matches: checkpoint)
        isWorking = true
        message = nil
        defer { isWorking = false }
        let bytes = Data(checkpoint.text.utf8)
        // Export deliberately does not replace an existing file, even after a
        // native dialog's replacement confirmation. Choosing a fresh name is
        // preferable to risking the sole source while offering a recovery.
        try await writeNew(destination, bytes)
        guard try await readFile(destination) == bytes else {
            throw DraftRecoveryError.readBackFailed
        }
        message = "Source exported. The recovery copy has been kept."
    }

    func discard(draftID: UUID, expectedCheckpoint: DraftCheckpoint? = nil) async throws {
        guard !isWorking else { throw DraftRecoveryError.busy }
        guard let checkpoint = draft(id: draftID) else {
            throw DraftRecoveryError.noLongerAvailable
        }
        try Self.checkPreview(expectedCheckpoint, matches: checkpoint)
        isWorking = true
        message = nil
        defer { isWorking = false }
        try await journal.remove(draftID, toTrash: true)
    }

    func revealRecoveryDirectory() {
        NSWorkspace.shared.activateFileViewerSelecting([journal.directoryURL])
    }

    func revealIssue(_ issue: DraftRecoveryIssue) {
        NSWorkspace.shared.activateFileViewerSelecting([issue.fileURL])
    }

    func copy(draftID: UUID, expectedCheckpoint: DraftCheckpoint? = nil) throws {
        guard let checkpoint = draft(id: draftID) else {
            throw DraftRecoveryError.noLongerAvailable
        }
        try Self.checkPreview(expectedCheckpoint, matches: checkpoint)
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(checkpoint.text, forType: .string) else {
            throw DraftRecoveryError.clipboardUnavailable
        }
        message = "Recovered text copied. The recovery copy has been kept."
    }

    private func removeAfterSave(_ checkpoint: DraftCheckpoint) async throws {
        guard Self.matchesSnapshot(draft(id: checkpoint.id), checkpoint) else {
            throw DraftRecoveryError.noLongerAvailable
        }
        do {
            try await journal.remove(checkpoint.id, toTrash: false)
            message = "Recovered writing saved as a new note."
        } catch {
            message = "The new note was saved, but its recovery copy could not be removed. Retry to finish cleanup without creating another note."
            throw DraftRecoveryError.cleanupFailed
        }
    }

    private func verifies(_ completion: DraftCompletion) async throws -> Bool {
        let url = URL(fileURLWithPath: completion.targetPath)
        guard completion.targetPath.hasPrefix("/"),
              url.standardizedFileURL.path == completion.targetPath,
              url.pathExtension.lowercased() == "md",
              completion.revision.count == 32 else { return false }
        if DraftRecoveryFiles.isMissing(url) { return false }
        let bytes = try await readFile(url)
        return await Task.detached(priority: .userInitiated) {
            guard MeetingNote.contentRevision(bytes) == completion.revision,
                  let source = String(data: bytes, encoding: .utf8),
                  MarkdownCodec.decode(source)?.id == completion.noteID else {
                return false
            }
            return true
        }.value
    }

    /// Swift String equality treats different Unicode encodings as equal.
    /// Recovery promises the original bytes, so a rescan that changes only
    /// normalization still invalidates work performed against an older copy.
    nonisolated static func matchesSnapshot(_ current: DraftCheckpoint?, _ expected: DraftCheckpoint) -> Bool {
        guard let current else { return false }
        return current == expected
            && current.text.utf8.elementsEqual(expected.text.utf8)
            && current.baseline.utf8.elementsEqual(expected.baseline.utf8)
    }

    /// A preview may stay open while the folder is rescanned. Only completion
    /// bookkeeping may change underneath it. Content, baseline, and ownership
    /// changes require another explicit review before any action, including
    /// copying or discarding the checkpoint.
    nonisolated static func matchesPreview(_ current: DraftCheckpoint, _ preview: DraftCheckpoint) -> Bool {
        var comparable = current
        comparable.checkpointedAt = preview.checkpointedAt
        comparable.completion = preview.completion
        return matchesSnapshot(comparable, preview)
    }

    nonisolated private static func checkPreview(_ expected: DraftCheckpoint?, matches current: DraftCheckpoint) throws {
        guard let expected else { return }
        guard matchesPreview(current, expected) else { throw DraftRecoveryError.previewChanged }
    }

    nonisolated static func canSaveAsNewNote(_ checkpoint: DraftCheckpoint) -> Bool {
        (try? newNoteSource(from: checkpoint, id: UUID())) != nil
    }

    nonisolated static func newNoteSource(from checkpoint: DraftCheckpoint, id: UUID) throws -> String {
        if checkpoint.kind == .markdown {
            return try cloneMarkdown(checkpoint.text, id: id)
        }
        let note = MeetingNote(
            id: id,
            kind: .spoken,
            title: checkpoint.title.isEmpty ? "Recovered writing" : checkpoint.title,
            startedAt: checkpoint.createdAt,
            endedAt: checkpoint.checkpointedAt,
            sourceApp: "Recovered writing",
            summary: ""
        )
        // The usual encoder trims prose. Build its empty, valid envelope and
        // append the exact editor text, including leading/trailing whitespace
        // and an intentionally empty replacement. The source is authoritative.
        return MarkdownCodec.encode(note) + checkpoint.text
    }

    nonisolated static func cloneMarkdown(_ source: String, id: UUID) throws -> String {
        // Accept Nook's deliberately small frontmatter format only. In
        // particular, duplicate or indented identity keys and unsupported
        // delimiters must fall back to exact Copy/Export, not a lossy decode.
        guard source.hasPrefix("---\n"),
              let closing = source.range(of: "\n---\n", range: source.index(source.startIndex, offsetBy: 3)..<source.endIndex),
              MarkdownCodec.decode(source) != nil else {
            throw DraftRecoveryError.markdownIdentityAmbiguous
        }
        let frontmatterStart = source.index(source.startIndex, offsetBy: 4)
        guard closing.lowerBound >= frontmatterStart else {
            throw DraftRecoveryError.markdownIdentityAmbiguous
        }
        let frontmatter = source[frontmatterStart..<closing.lowerBound]
        let identityLines = frontmatter.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                guard let colon = line.firstIndex(of: ":") else { return false }
                return line[..<colon].trimmingCharacters(in: .whitespaces) == "id"
            }
        guard identityLines.count == 1,
              let line = identityLines.first, line.hasPrefix("id: ") else {
            throw DraftRecoveryError.markdownIdentityAmbiguous
        }
        let token = line.dropFirst(4)
        guard token.count == 36, UUID(uuidString: String(token)) != nil else {
            throw DraftRecoveryError.markdownIdentityAmbiguous
        }
        var result = source
        result.replaceSubrange(token.startIndex..<token.endIndex, with: id.uuidString)
        guard MarkdownCodec.decode(result)?.id == id else {
            throw DraftRecoveryError.markdownIdentityAmbiguous
        }
        return result
    }
}

enum DraftRecoveryError: LocalizedError, Equatable {
    case busy, noLongerAvailable, libraryChanged, previousSaveChanged, previewChanged
    case markdownIdentityAmbiguous, readBackFailed, cleanupFailed
    case clipboardUnavailable, unsafeFile, fileTooLarge, safeCreationUnsupported

    var errorDescription: String? {
        switch self {
        case .busy: "Another recovery action is still finishing."
        case .noLongerAvailable: "This recovery copy is no longer available. Close this preview and check the recovered drafts list."
        case .libraryChanged: "The notes folder changed. Review the destination and try again."
        case .previewChanged: "This recovery copy changed after its preview opened. Close this window and review the latest copy before continuing."
        case .previousSaveChanged: "An earlier recovered note exists but could not be verified. Its recovery copy is kept. Use Copy or Export Source to preserve the text separately."
        case .markdownIdentityAmbiguous: "This Markdown source cannot safely receive a new note identity. Use Copy or Export Source to keep every character."
        case .readBackFailed: "The saved file could not be verified. The recovery copy has been kept."
        case .cleanupFailed: "The new note was saved, but its recovery copy could not be removed. Retry to finish cleanup without creating another note."
        case .clipboardUnavailable: "The clipboard could not accept the recovered text. The recovery copy has been kept."
        case .unsafeFile: "This location is not a regular file or folder. Choose a different location."
        case .fileTooLarge: "This file is too large to verify safely. The recovery copy has been kept."
        case .safeCreationUnsupported: "This location does not support safe file creation. The recovery copy has been kept. Choose a folder on your Mac to save or export the writing."
        }
    }
}

/// Blocking filesystem calls run away from the main actor. A private temporary
/// inode is renamed to the final name only after writing finishes. RENAME_EXCL
/// never replaces an existing file, including a symlink introduced after the
/// dialog, and does not require a destination that supports hard links. Some
/// filesystems, including ExFAT, cannot honor this operation. They fail closed
/// instead of falling back to a replacement that could erase another file.
enum DraftRecoveryFiles {
    typealias ExclusiveRename = @Sendable (Int32, String, Int32, String) throws -> Void
    static let maximumReadBytes = 32 * 1_024 * 1_024

    static func isMissing(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) != 0 && errno == ENOENT
    }

    static func writeNew(
        _ bytes: Data,
        to url: URL,
        renameExclusive: ExclusiveRename = { sourceFD, source, destinationFD, destination in
            guard renameatx_np(sourceFD, source, destinationFD, destination, UInt32(RENAME_EXCL)) == 0 else {
                throw posixError()
            }
        }
    ) throws {
        let directory = url.deletingLastPathComponent()
        let directoryFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directoryFD >= 0 else { throw posixError() }
        defer { close(directoryFD) }
        let temporaryName = ".nook-recovery-\(UUID().uuidString).tmp"
        let fd = openat(directoryFD, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw posixError() }
        defer {
            close(fd)
            unlinkat(directoryFD, temporaryName, 0)
        }
        try bytes.withUnsafeBytes { buffer in
            var written = 0
            while written < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: written), buffer.count - written)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw posixError() }
                written += count
            }
        }
        guard fsync(fd) == 0 else { throw posixError() }
        do {
            try renameExclusive(directoryFD, temporaryName, directoryFD, url.lastPathComponent)
        } catch let error as POSIXError where error.code == .ENOTSUP || error.code == .EOPNOTSUPP {
            throw DraftRecoveryError.safeCreationUnsupported
        }
    }

    static func readRegularFile(at url: URL) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw posixError() }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG else {
            throw DraftRecoveryError.unsafeFile
        }
        guard info.st_size >= 0, info.st_size <= maximumReadBytes else {
            throw DraftRecoveryError.fileTooLarge
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw posixError() }
            if count == 0 { break }
            guard data.count + count <= maximumReadBytes else {
                throw DraftRecoveryError.fileTooLarge
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }

    private static func posixError() -> Error {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
