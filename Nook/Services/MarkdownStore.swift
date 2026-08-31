import AppKit
import Darwin
import Foundation

struct MarkdownLoadIssue: Identifiable, Hashable, Sendable {
    let fileURL: URL
    let message: String

    var id: URL { fileURL }
}

@MainActor
final class MarkdownStore: ObservableObject {
    typealias LoadPayload = (
        notes: [MeetingNote],
        issues: [MarkdownLoadIssue]
    )
    typealias NoteLoader = @Sendable (
        URL,
        NoteDecodeCache?
    ) -> Result<LoadPayload, Error>

    @Published private(set) var notes: [MeetingNote] = [] {
        didSet {
            // Derived alongside the library publication, not recalculated for
            // every sidebar row or meter-driven render.
            let counts = Dictionary(grouping: notes, by: \.id)
            duplicateNoteIDs = Set(counts.compactMap { $0.value.count > 1 ? $0.key : nil })
        }
    }
    private(set) var duplicateNoteIDs: Set<UUID> = []

    func note(matching identity: LibraryNoteIdentity) -> MeetingNote? {
        // Most rows have a different UUID. Avoid normalizing every unrelated
        // path while retaining the full file check for copied identities.
        notes.first { $0.id == identity.noteID && $0.libraryIdentity == identity }
    }

    func uniqueNote(id: UUID) -> MeetingNote? {
        guard !duplicateNoteIDs.contains(id) else { return nil }
        return notes.first { $0.id == id }
    }
    @Published private(set) var loadIssues: [MarkdownLoadIssue] = []
    @Published private(set) var isLoading = false
    /// A folder can change away and back while an operation awaits a model.
    /// Its URL alone cannot authorize that old operation when it returns.
    /// Ordinary reloads and saves deliberately do not advance this identity.
    private(set) var storageGeneration = 0
    @Published var storageURL: URL {
        willSet {
            if newValue.standardizedFileURL != storageURL.standardizedFileURL {
                storageGeneration &+= 1
                onStorageDirectoryWillChange?()
            }
        }
        didSet {
            // Cached decodes belong to the directory they came from.
            decodeCache.clear()
        }
    }
    @Published var lastError: String?

    /// Editors keep their captured owner when a folder changes. These hooks
    /// run at the mutation boundary, including changes made outside Settings.
    var onStorageDirectoryWillChange: (@MainActor () -> Void)?
    var onNoteDeleted: (@MainActor (MeetingNote) -> Void)?

    private let fileManager: FileManager
    private let noteLoader: NoteLoader
    private let beforeWriteCommit: @MainActor (URL) throws -> Void
    private let readCommittedBytes: @MainActor (URL) throws -> Data
    private let decodeCache = NoteDecodeCache()
    private var reloadGeneration = 0

    init(
        fileManager: FileManager = .default,
        noteLoader: @escaping NoteLoader = MarkdownStore.loadNotes,
        readCommittedBytes: @escaping @MainActor (URL) throws -> Data = { try Data(contentsOf: $0) },
        beforeWriteCommit: @escaping @MainActor (URL) throws -> Void = { _ in }
    ) {
        self.fileManager = fileManager
        self.noteLoader = noteLoader
        self.beforeWriteCommit = beforeWriteCommit
        self.readCommittedBytes = readCommittedBytes
        let configured = UserDefaults.standard.string(forKey: "storageDirectory")
        self.storageURL = configured.map(URL.init(fileURLWithPath:))
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents", isDirectory: true)
                .appendingPathComponent("Nook", isDirectory: true)
        ensureDirectory()
        reload()
    }

    func reload() {
        ensureDirectory()
        reloadGeneration += 1
        let generation = reloadGeneration
        let directory = storageURL
        let noteLoader = noteLoader
        let cache = decodeCache
        isLoading = true

        Task {
            let result = await Task.detached(priority: .userInitiated) {
                noteLoader(directory, cache)
            }.value

            guard generation == reloadGeneration, directory == storageURL else { return }
            // Notes land before the loading flag clears. Observers that wait
            // for the end of loading must never see an empty library that is
            // merely mid-publish.
            switch result {
            case .success(let payload):
                notes = payload.notes
                loadIssues = payload.issues
                lastError = payload.issues.isEmpty
                    ? nil
                    : "\(payload.issues.count) Markdown file\(payload.issues.count == 1 ? "" : "s") couldn’t be loaded."
            case .failure(let error):
                lastError = error.localizedDescription
                loadIssues = []
            }
            isLoading = false
        }
    }

    /// The one field a caller is deliberately rewriting, when it has one.
    ///
    /// The store's empty-file floor exists for a model that lost content on
    /// the way in. Saying which field is being edited on purpose is what lets
    /// that floor stay in place without also refusing an ordinary edit.
    enum DeliberateEdit {
        case personalNotes
    }

    @discardableResult
    func save(
        _ note: MeetingNote,
        deliberatelyEditing: DeliberateEdit? = nil,
        validatingBeforeCommit: @MainActor () throws -> Void = {}
    ) throws -> MeetingNote {
        ensureDirectory()
        var saved = note
        let known = try knownNote(for: note)
        // A note keeps the file it was written to. Deriving the destination
        // from the title again meant a caller that had not held on to the URL,
        // and a title that grew as words were dictated, scattered one note
        // across several files. The filename is an address, not a label: a
        // rename deliberately does not move the file.
        let destination = note.fileURL
            ?? known?.fileURL
            ?? availableDestination(for: note)
        try refuseIfChangedElsewhere(
            destination,
            revision: note.fileRevision ?? known?.fileRevision
        )

        let markdown = MarkdownCodec.encode(note)
        try refuseIfItWouldEmpty(
            destination,
            with: note,
            deliberatelyEditing: deliberatelyEditing
        )
        try commitMarkdown(
            markdown, to: destination,
            expectedRevision: note.fileRevision ?? known?.fileRevision,
            validatingBeforeCommit: validatingBeforeCommit
        )
        protectSensitiveFile(at: destination)
        saved.fileURL = destination
        saved.fileModified = Self.modificationDate(of: destination)
        saved.fileRevision = MeetingNote.contentRevision(Data(markdown.utf8))
        invalidateReloadSnapshot()
        upsert(saved)
        lastError = nil
        return saved
    }

    /// Updates personal notes from the freshest in-memory copy, checking the
    /// Markdown round-trip before anything is written and reading the file back
    /// afterwards.
    ///
    /// The order matters for what the failure can honestly say. A round-trip
    /// checked only after the write left the user reading that their file was
    /// untouched at the exact moment it had just been rewritten.
    @discardableResult
    func updatePersonalNotes(
        _ personalNotes: String,
        for note: MeetingNote,
        expectedPersonalNotes: String? = nil
    ) throws -> MeetingNote {
        var updated = try knownNote(for: note) ?? note
        let proposed = personalNotes.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let baseline = (expectedPersonalNotes ?? note.personalNotes)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // A reload may supply fresher unrelated fields, but it must not turn
        // an old personal draft into permission to overwrite new personal
        // notes. Only the field's original baseline can authorize this edit.
        // Canonically equivalent Unicode can still be somebody else's exact
        // edit, so neither the baseline nor an already-applied proposal may
        // authorize a different sequence of bytes.
        guard updated.personalNotes.utf8.elementsEqual(baseline.utf8)
            || updated.personalNotes.utf8.elementsEqual(proposed.utf8) else {
            lastError = MarkdownStoreError.personalNotesChangedElsewhere
                .errorDescription
            throw MarkdownStoreError.personalNotesChangedElsewhere
        }

        // A preflight save also settles whitespace-only drafts. Re-encoding
        // an unchanged field rewrote unrelated source formatting, including
        // the file's final newline, before a failed regeneration kept the
        // note. Verify the existing destination before accepting this no-op;
        // an unchanged field must not hide an external edit or missing file.
        if updated.personalNotes.utf8.elementsEqual(proposed.utf8),
           let destination = updated.fileURL, let revision = updated.fileRevision {
            try refuseIfChangedElsewhere(destination, revision: revision)
            let snapshot = try Self.readMarkdown(at: destination)
            guard snapshot.revision == revision else { throw changedFileError() }
            guard var persisted = MarkdownCodec.decode(snapshot.markdown, fileURL: destination),
                  persisted.id == updated.id,
                  persisted.personalNotes.utf8.elementsEqual(proposed.utf8) else {
                throw MarkdownStoreError.saveReadBackFailed
            }
            persisted.fileModified = Self.modificationDate(of: destination)
            invalidateReloadSnapshot()
            upsert(persisted)
            lastError = nil
            return persisted
        }
        updated.personalNotes = proposed

        guard
            let rehearsed = MarkdownCodec.decode(MarkdownCodec.encode(updated)),
            rehearsed.personalNotes.utf8.elementsEqual(updated.personalNotes.utf8)
        else {
            throw MarkdownStoreError.writeVerificationFailed
        }

        // Emptying My notes is a select-all-delete, not a decode that lost the
        // body, so the store's floor is told which field this save is about.
        let saved = try save(updated, deliberatelyEditing: .personalNotes)

        guard
            let destination = saved.fileURL,
            let markdown = try? String(
                contentsOf: destination,
                encoding: .utf8
            ),
            let persisted = MarkdownCodec.decode(
                markdown,
                fileURL: destination
            ),
            persisted.personalNotes.utf8.elementsEqual(saved.personalNotes.utf8)
        else {
            throw MarkdownStoreError.saveReadBackFailed
        }
        return saved
    }

    /// Refuses a whole-note save when the file changed after Nook last read
    /// it, and reloads so the library shows what is really there.
    ///
    /// Nook is not the only writer of these files. Encoding rebuilds the whole
    /// document from a model, so writing over an edit made elsewhere deletes it
    /// completely rather than merging it.
    private func refuseIfChangedElsewhere(
        _ destination: URL,
        revision: Data?
    ) throws {
        var info = stat()
        if lstat(destination.path, &info) != 0 {
            guard errno == ENOENT else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard revision == nil else { throw CocoaError(.fileNoSuchFile) }
            return
        }
        guard info.st_mode & S_IFMT == S_IFREG else {
            throw MarkdownStoreError.unsafeSaveDestination
        }
        let current = try Data(contentsOf: destination)
        if let revision, MeetingNote.contentRevision(current) == revision {
            return
        }
        throw changedFileError()
    }

    private func changedFileError() -> MarkdownStoreError {
        // Release the obsolete decode immediately. The reload independently
        // checks exact bytes, even when another writer preserved timestamps.
        decodeCache.clear()
        reload()
        lastError = MarkdownStoreError.fileChangedElsewhere.errorDescription
        return .fileChangedElsewhere
    }

    /// Prepare all bytes privately, then recheck the captured conflict baseline
    /// immediately before publishing. The first check alone left encoding and
    /// disk I/O between comparison and replacement. This narrows that interval;
    /// it is not a transaction with an uncooperative external writer that races
    /// the final comparison and rename. New destinations are always exclusive.
    private func commitMarkdown(
        _ markdown: String, to destination: URL, expectedRevision: Data?,
        validatingBeforeCommit: @MainActor () throws -> Void = {}
    ) throws {
        let directoryURL = destination.deletingLastPathComponent()
        let directory = open(directoryURL.path, O_RDONLY | O_DIRECTORY)
        guard directory >= 0 else { throw writeError() }
        defer { close(directory) }
        let temporary = ".nook-write-\(UUID().uuidString).tmp"
        let descriptor = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw writeError() }
        defer {
            close(descriptor)
            unlinkat(directory, temporary, 0)
        }
        let bytes = Data(markdown.utf8)
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw writeError() }
                offset += written
            }
        }
        guard fsync(descriptor) == 0 else { throw writeError() }
        // A deterministic filesystem boundary for failure and concurrent-writer
        // tests. Production supplies a no-op and never exposes the staging path.
        try beforeWriteCommit(destination)
        // A merge consumes two files. Rechecking only this destination would
        // still allow an edit to its other source during staging to be lost.
        try validatingBeforeCommit()
        var openedDirectory = stat()
        var currentDirectory = stat()
        guard fstat(directory, &openedDirectory) == 0,
              fstatat(AT_FDCWD, directoryURL.path, &currentDirectory, 0) == 0,
              openedDirectory.st_dev == currentDirectory.st_dev,
              openedDirectory.st_ino == currentDirectory.st_ino else {
            throw changedFileError()
        }
        if expectedRevision != nil {
            try refuseIfChangedElsewhere(destination, revision: expectedRevision)
        }
        let flags: UInt32 = expectedRevision == nil ? UInt32(RENAME_EXCL) : 0
        guard renameatx_np(directory, temporary, directory, destination.lastPathComponent, flags) == 0 else {
            if errno == EEXIST { throw changedFileError() }
            if errno == ENOTSUP || errno == EOPNOTSUPP {
                throw MarkdownStoreError.safeCreationUnsupported
            }
            throw writeError()
        }
        // This requests persistence of the directory entry. It is not a
        // promise about device caches or survival of a sudden power loss.
        _ = fsync(directory)
        guard (try? readCommittedBytes(destination)) == bytes else {
            throw MarkdownStoreError.saveReadBackFailed
        }
    }

    private func writeError() -> Error {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    /// Refuses a save that would replace a file's contents with nothing.
    ///
    /// A note with no content is a legitimate thing to create, but rarely a
    /// legitimate thing to turn a written file into: usually the cause is a
    /// decode that failed to find the body, so the file wins.
    ///
    /// The exception is the field the caller says it is rewriting. A note
    /// whose only writing lives in My notes, which is every template note
    /// somebody typed into, could otherwise never be cleared: select all,
    /// delete, and the save was refused forever with a message about a file
    /// nobody had touched. When everything the file still holds is in that one
    /// field, emptying it is an edit and it goes through.
    private func refuseIfItWouldEmpty(
        _ destination: URL,
        with note: MeetingNote,
        deliberatelyEditing: DeliberateEdit?
    ) throws {
        guard note.hasNoContent,
              let existing = try? String(contentsOf: destination, encoding: .utf8),
              !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let decoded = MarkdownCodec.decode(existing),
              !decoded.hasNoContent
        else { return }
        if deliberatelyEditing == .personalNotes,
           decoded.hasNoContentBesidesPersonalNotes {
            return
        }
        lastError = MarkdownStoreError.wouldEmptyNote.errorDescription
        throw MarkdownStoreError.wouldEmptyNote
    }

    private static func modificationDate(of url: URL) -> Date? {
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: url.path
        ) else {
            return nil
        }
        return attributes[.modificationDate] as? Date
    }

    @discardableResult
    func createBlankNote() throws -> MeetingNote {
        try createTemplatedNote(from: .blank)
    }

    /// Creates a note pre-seeded from a template.
    ///
    /// Templates are static text on the model's own fields, so the file that
    /// lands on disk is byte-for-byte what any equivalent note would encode;
    /// nothing is generated and nothing leaves the Mac. Their checklist lines
    /// are marked complete because they are prompts for the note, not open
    /// work; the prompts remain visible and can be reopened when they become
    /// real follow-ups.
    @discardableResult
    func createTemplatedNote(from template: NoteTemplate) throws -> MeetingNote {
        let now = Date()
        return try save(
            MeetingNote(
                title: template.title,
                startedAt: now,
                endedAt: now,
                sourceApp: "Personal",
                summary: template.summary,
                actionItems: template.actionItems,
                completedActionItems: Set(template.actionItems),
                personalNotes: ""
            )
        )
    }

    /// Reads the file as it exists right now, or fails visibly.
    ///
    /// This deliberately does not fall back to an in-memory reconstruction
    /// when the read fails. A fallback handed stale text to the Markdown
    /// source editor, and saving from it replaced whatever was really on disk
    /// with content Nook had merely remembered. Clipboard copies may fall
    /// back; anything that can be saved back must not.
    func rawMarkdown(for note: MeetingNote) throws -> String {
        try markdownSnapshot(for: note).markdown
    }

    struct FileSnapshot: Sendable {
        let markdown: String
        let revision: Data
    }

    /// The source editor and its revision must come from the same read. A
    /// second read for a timestamp or digest could observe a different edit.
    func markdownSnapshot(for note: MeetingNote) throws -> FileSnapshot {
        guard let url = note.fileURL else {
            let markdown = MarkdownCodec.encode(note)
            return FileSnapshot(
                markdown: markdown,
                revision: MeetingNote.contentRevision(Data(markdown.utf8))
            )
        }
        return try Self.readMarkdown(at: url)
    }

    nonisolated private static func readMarkdown(at url: URL) throws -> FileSnapshot {
        let contents = try Data(contentsOf: url)
        guard let markdown = String(data: contents, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return FileSnapshot(
            markdown: markdown,
            revision: MeetingNote.contentRevision(contents)
        )
    }

    func saveRawMarkdown(
        _ markdown: String,
        for note: MeetingNote,
        expectedRevision: Data? = nil
    ) throws {
        guard let url = note.fileURL else {
            throw CocoaError(.fileNoSuchFile)
        }
        guard var decoded = MarkdownCodec.decode(markdown, fileURL: url) else {
            throw MarkdownStoreError.invalidDocument
        }
        // Source editing can change content, but cannot redirect the library's
        // stable identity or replace another note's in-memory entry.
        guard decoded.id == note.id else {
            throw MarkdownStoreError.noteIdentityChanged
        }
        try refuseIfChangedElsewhere(
            url,
            revision: expectedRevision ?? note.fileRevision
                ?? knownNote(for: note)?.fileRevision
        )
        try commitMarkdown(
            markdown, to: url,
            expectedRevision: expectedRevision ?? note.fileRevision
                ?? knownNote(for: note)?.fileRevision
        )
        protectSensitiveFile(at: url)
        decoded.fileURL = url
        // Our own write is not an external change, so the whole-note save path
        // must see this timestamp as the one it last read.
        decoded.fileModified = Self.modificationDate(of: url)
        decoded.fileRevision = MeetingNote.contentRevision(Data(markdown.utf8))
        invalidateReloadSnapshot()
        upsert(decoded)
        loadIssues.removeAll { $0.fileURL == url }
        lastError = loadIssues.isEmpty
            ? nil
            : "\(loadIssues.count) Markdown file\(loadIssues.count == 1 ? "" : "s") couldn’t be loaded."
    }

    /// Explicitly renames a saved note's Markdown file to match its current
    /// display title. Saving a title deliberately does not call this: a file's
    /// path is an address, and callers may want to change that address only
    /// when they ask for it.
    ///
    /// The move preserves every byte in the file. The destination follows the
    /// same date-and-sanitized-title convention as a new note, including the
    /// existing collision suffixes. The source timestamp is checked first so
    /// an edit made outside Nook is never moved away from the path a person
    /// may still be using.
    @discardableResult
    func renameManagedFile(for note: MeetingNote) throws -> MeetingNote {
        let known = try knownNote(for: note)
        guard let source = note.fileURL ?? known?.fileURL else {
            lastError = MarkdownStoreError.renameRequiresSavedNote.errorDescription
            throw MarkdownStoreError.renameRequiresSavedNote
        }

        let sourceURL = source.standardizedFileURL
        let managedDirectory = storageURL.standardizedFileURL
        guard sourceURL.deletingLastPathComponent() == managedDirectory else {
            lastError = MarkdownStoreError.renameRequiresManagedFile.errorDescription
            throw MarkdownStoreError.renameRequiresManagedFile
        }
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            lastError = MarkdownStoreError.renameSourceMissing.errorDescription
            throw MarkdownStoreError.renameSourceMissing
        }

        try refuseIfChangedElsewhere(
            sourceURL,
            revision: note.fileRevision ?? known?.fileRevision
        )

        let destination = availableDestination(
            for: note,
            excluding: sourceURL
        )
        let destinationURL = destination.standardizedFileURL

        // The path already matches. It is still a successful explicit request,
        // but there is no filesystem mutation to perform.
        if destinationURL == sourceURL {
            var unchanged = note
            unchanged.fileURL = sourceURL
            unchanged.fileModified = Self.modificationDate(of: sourceURL)
            unchanged.fileRevision = note.fileRevision ?? known?.fileRevision
            upsert(unchanged)
            lastError = nil
            return unchanged
        }

        do {
            // moveItem refuses an existing destination; availableDestination
            // has already selected a free collision-safe path, so this never
            // overwrites another note.
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
        } catch {
            lastError = MarkdownStoreError.renameFailed.errorDescription
            throw MarkdownStoreError.renameFailed
        }

        protectSensitiveFile(at: destinationURL)
        var renamed = note
        renamed.fileURL = destinationURL
        renamed.fileModified = Self.modificationDate(of: destinationURL)
        renamed.fileRevision = note.fileRevision ?? known?.fileRevision
        invalidateReloadSnapshot()
        upsert(renamed, replacingFileURL: sourceURL)
        lastError = nil
        return renamed
    }

    /// Moves a note's Markdown file to the Trash.
    ///
    /// Trashing rather than unlinking keeps the deletion reversible from the
    /// Finder, which matters for the only destructive action in the library.
    /// Kept audio in the recordings folder is left where it is; the existing
    /// recovery controls let the user remove it explicitly. Returns false and sets
    /// `lastError` when nothing was deleted, leaving every list untouched.
    @discardableResult
    func delete(
        _ note: MeetingNote,
        validatingBeforeTrash: @MainActor () throws -> Void = {}
    ) -> Bool {
        do {
            try validatingBeforeTrash()
        } catch {
            lastError = error.localizedDescription
            return false
        }
        guard let url = note.fileURL else {
            // A note that has never been saved has no file to protect.
            notes.removeAll { $0.id == note.id && $0.fileURL == nil }
            onNoteDeleted?(note)
            return true
        }
        do {
            guard fileManager.fileExists(atPath: url.path) else {
                lastError = "The original note is no longer available. Unfinished edits and recovery copies were kept."
                return false
            }
            try fileManager.trashItem(at: url, resultingItemURL: nil)
        } catch {
            // A missing Trash is a safety boundary, not an invitation to
            // unlink the only copy. Keep both the file and the in-memory note
            // so the user can make the Trash available and try again.
            lastError = "Couldn’t move \(url.lastPathComponent) to the Trash: "
                + error.localizedDescription
            return false
        }
        // Copied Markdown can carry the same UUID at two different paths.
        // Only the file actually moved to Trash has been deleted.
        notes.removeAll {
            $0.id == note.id && $0.fileURL?.standardizedFileURL == url.standardizedFileURL
        }
        invalidateReloadSnapshot()
        lastError = nil
        onNoteDeleted?(note)
        return true
    }

    /// A merge owns two saved snapshots. Checking only its surviving file
    /// would still allow a newer absorbed file to be moved to Trash.
    /// Recheck both at the write boundary and again before cleanup. This
    /// narrows filesystem races; it is not a transaction with other writers.
    func validateMergeSource(
        _ note: MeetingNote, directory: URL, generation: Int
    ) throws {
        guard storageGeneration == generation,
              storageURL.standardizedFileURL == directory.standardizedFileURL
        else { throw NoteMergeError.libraryChanged }
        guard !isLoading else { throw NoteMergeError.libraryLoading }
        guard !duplicateNoteIDs.contains(note.id) else {
            throw NoteMergeError.ambiguousSource
        }
        guard let url = note.fileURL,
              url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL,
              let revision = note.fileRevision,
              let current = uniqueNote(id: note.id),
              current.libraryIdentity == note.libraryIdentity,
              current.fileRevision == revision
        else { throw NoteMergeError.sourceChanged }
        do {
            try refuseIfChangedElsewhere(url, revision: revision)
        } catch {
            throw NoteMergeError.sourceChanged
        }
    }

    /// A new pad checkpoints this destination before its first save so a
    /// restart can distinguish an unfinished edit from a completed save whose
    /// recovery cleanup was interrupted. The save still checks for conflicts.
    func destinationForNewNote(_ note: MeetingNote) -> URL {
        availableDestination(for: note)
    }

    func selectStorageDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = storageURL
        panel.prompt = "Choose Folder"
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    func switchStorageDirectory(to url: URL, copyExistingMarkdown: Bool) throws {
        let oldDirectory = storageURL.standardizedFileURL
        let newDirectory = url.standardizedFileURL
        guard oldDirectory != newDirectory else { return }

        try fileManager.createDirectory(
            at: newDirectory,
            withIntermediateDirectories: true
        )
        if copyExistingMarkdown {
            let sourceFiles = try markdownFiles(in: oldDirectory)
            for source in sourceFiles {
                let destination = availableCopyDestination(
                    named: source.lastPathComponent,
                    in: newDirectory
                )
                try fileManager.copyItem(at: source, to: destination)
            }
        }

        storageURL = newDirectory
        UserDefaults.standard.set(newDirectory.path, forKey: "storageDirectory")
        reload()
    }

    var markdownFileCount: Int {
        (try? markdownFiles(in: storageURL).count) ?? notes.count
    }

    func reveal(_ note: MeetingNote) {
        guard let url = note.fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func reveal(_ issue: MarkdownLoadIssue) {
        NSWorkspace.shared.activateFileViewerSelecting([issue.fileURL])
    }

    func openStorageDirectory() {
        NSWorkspace.shared.open(storageURL)
    }

    func recordingsDirectory() -> URL {
        let url = storageURL.appendingPathComponent(".recordings", isDirectory: true)
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            lastError = "Couldn’t prepare the recordings folder: \(error.localizedDescription)"
            return url
        }
        // User-selected non-POSIX volumes may not support this attribute.
        try? fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.path
        )
        return url
    }

    private func protectSensitiveFile(at url: URL) {
        // Some user-selected volumes do not implement POSIX permissions. The
        // note is already saved in that case, so do not turn a successful save
        // into data loss; use the strictest permissions the volume supports.
        try? fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    private func ensureDirectory() {
        do {
            try fileManager.createDirectory(at: storageURL, withIntermediateDirectories: true)
        } catch {
            lastError = "Couldn’t open the notes folder: \(error.localizedDescription)"
        }
    }

    /// Finder copies can retain the same UUID. A file path disambiguates an
    /// existing note; without one, choosing an arbitrary copy could overwrite
    /// or hide another document.
    private func knownNote(for note: MeetingNote) throws -> MeetingNote? {
        let candidates = notes.filter { $0.id == note.id }
        if let path = note.fileURL?.standardizedFileURL {
            return candidates.first { $0.fileURL?.standardizedFileURL == path }
        }
        guard candidates.count <= 1 else {
            throw MarkdownStoreError.ambiguousNoteIdentity
        }
        return candidates.first
    }

    private func upsert(_ note: MeetingNote, replacingFileURL: URL? = nil) {
        let previousPath = (replacingFileURL ?? note.fileURL)?.standardizedFileURL
        var updated = notes
        if let index = updated.firstIndex(where: {
            $0.id == note.id && $0.fileURL?.standardizedFileURL == previousPath
        }) {
            updated[index] = note
        } else {
            updated.append(note)
        }
        updated.sort { $0.startedAt > $1.startedAt }
        // A published append exposed an unsorted library before a second
        // publication sorted it. Recent-note and prep subscribers must see
        // the complete, correctly ordered snapshot once for this mutation.
        notes = updated
    }

    /// A detached reload is a snapshot of the directory before this mutation.
    /// Advancing the generation prevents that older snapshot from replacing the
    /// note that was just saved, and clears a spinner whose task is now stale.
    private func invalidateReloadSnapshot() {
        reloadGeneration += 1
        isLoading = false
    }

    private func filename(for note: MeetingNote) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmm"
        let safeTitle = note.title
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let compactTitle = String((safeTitle.isEmpty ? "meeting" : safeTitle).prefix(72))
        return "\(formatter.string(from: note.startedAt))-\(compactTitle).md"
    }

    private func availableDestination(
        for note: MeetingNote,
        excluding source: URL? = nil
    ) -> URL {
        let preferred = storageURL.appendingPathComponent(filename(for: note))
        let sourceURL = source?.standardizedFileURL
        guard fileManager.fileExists(atPath: preferred.path),
              preferred.standardizedFileURL != sourceURL else {
            return preferred
        }

        if source == nil,
            let markdown = try? String(contentsOf: preferred, encoding: .utf8),
            MarkdownCodec.decode(markdown)?.id == note.id
        {
            return preferred
        }

        let stem = preferred.deletingPathExtension().lastPathComponent
        let shortID = note.id.uuidString.prefix(8).lowercased()
        let unique = storageURL
            .appendingPathComponent("\(stem)-\(shortID)")
            .appendingPathExtension("md")
        guard fileManager.fileExists(atPath: unique.path) else {
            return unique
        }

        let fullID = storageURL
            .appendingPathComponent("\(stem)-\(note.id.uuidString.lowercased())")
            .appendingPathExtension("md")
        guard fileManager.fileExists(atPath: fullID.path) else {
            return fullID
        }

        var suffix = 2
        while true {
            let candidate = storageURL
                .appendingPathComponent("\(stem)-\(note.id.uuidString.lowercased()) \(suffix)")
                .appendingPathExtension("md")
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            suffix += 1
        }
    }

    private func markdownFiles(in directory: URL) throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension.lowercased() == "md" }
    }

    private func availableCopyDestination(named filename: String, in directory: URL) -> URL {
        let preferred = directory.appendingPathComponent(filename)
        guard fileManager.fileExists(atPath: preferred.path) else { return preferred }
        let stem = preferred.deletingPathExtension().lastPathComponent
        let ext = preferred.pathExtension
        var suffix = 2
        while true {
            let candidate = directory
                .appendingPathComponent("\(stem) \(suffix)")
                .appendingPathExtension(ext)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            suffix += 1
        }
    }

    nonisolated static func loadNotes(
        in directory: URL,
        cache: NoteDecodeCache? = nil
    ) -> Result<LoadPayload, Error> {
        do {
            let urls = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ).filter { $0.pathExtension.lowercased() == "md" }
            var notes: [MeetingNote] = []
            var issues: [MarkdownLoadIssue] = []

            for url in urls {
                let modified = try? url.resourceValues(forKeys: [
                    .contentModificationDateKey
                ]).contentModificationDate
                do {
                    let snapshot = try readMarkdown(at: url)
                    if var cached = cache?.note(for: url, revision: snapshot.revision) {
                        // The decoded content is identical, but its path
                        // spelling or modification date may have changed.
                        cached.fileURL = url
                        cached.fileModified = modified
                        cached.fileRevision = snapshot.revision
                        notes.append(cached)
                        continue
                    }
                    let markdown = snapshot.markdown
                    guard var note = MarkdownCodec.decode(
                        markdown,
                        fileURL: url
                    ) else {
                        issues.append(
                            MarkdownLoadIssue(
                                fileURL: url,
                                message: "The frontmatter is missing required meeting fields."
                            )
                        )
                        continue
                    }
                    // Remembering what the file looked like when it was read is
                    // what lets a later whole-note save notice somebody else
                    // edited it in between.
                    note.fileModified = modified
                    note.fileRevision = snapshot.revision
                    cache?.store(note, for: url, revision: snapshot.revision)
                    notes.append(note)
                } catch {
                    issues.append(
                        MarkdownLoadIssue(
                            fileURL: url,
                            message: error.localizedDescription
                        )
                    )
                }
            }
            cache?.prune(keeping: urls)
            return .success(
                (
                    notes: notes.sorted { $0.startedAt > $1.startedAt },
                    issues: issues.sorted { $0.fileURL.lastPathComponent < $1.fileURL.lastPathComponent }
                )
            )
        } catch {
            return .failure(error)
        }
    }
}

enum MarkdownStoreError: LocalizedError {
    case invalidDocument
    case noteIdentityChanged
    case ambiguousNoteIdentity
    case writeVerificationFailed
    case saveReadBackFailed
    case fileChangedElsewhere
    case personalNotesChangedElsewhere
    case wouldEmptyNote
    case renameRequiresSavedNote
    case renameRequiresManagedFile
    case renameSourceMissing
    case renameFailed
    case unsafeSaveDestination
    case safeCreationUnsupported

    var errorDescription: String? {
        switch self {
        case .invalidDocument:
            "The Markdown frontmatter is missing or invalid. Your changes haven’t been written."
        case .ambiguousNoteIdentity:
            "More than one file has this note’s ID. Open the specific file before saving. No files were changed."
        case .noteIdentityChanged:
            "A note’s ID cannot be changed in this editor. Keep the original ID to save. Your draft and the saved files were kept."
        case .writeVerificationFailed:
            "Nook couldn’t verify these changes would survive the Markdown round-trip, so your file was left untouched."
        case .saveReadBackFailed:
            "Nook saved this note but couldn’t read it back. Check the file before making more changes."
        case .fileChangedElsewhere:
            "This file changed outside Nook. Nothing was written. Review the current file before applying your changes."
        case .personalNotesChangedElsewhere:
            "My notes changed since this edit began. Nothing was written. Compare your draft with the current file before continuing."
        case .wouldEmptyNote:
            "Saving would have emptied this note, so nothing was written. Open the file to check it."
        case .renameRequiresSavedNote:
            "This note has no saved Markdown file to rename."
        case .renameRequiresManagedFile:
            "This file is outside Nook’s notes folder, so it was not renamed."
        case .renameSourceMissing:
            "This note’s Markdown file is missing, so it was not renamed."
        case .renameFailed:
            "Nook couldn’t rename this note file, so the original was left unchanged."
        case .unsafeSaveDestination:
            "This note’s location is not a regular file. Nothing was written. Choose a different location."
        case .safeCreationUnsupported:
            "This notes folder does not support safe file creation. Nothing was written. Choose a folder on your Mac."
        }
    }
}

/// Starting points for a new note in the library.
///
/// Deliberately tiny: three skeletons whose value is the checklist they save
/// the user from retyping, not content. Their seed lines are visible prompts,
/// not open work, when a note is first created from the template.
enum NoteTemplate: String, CaseIterable, Identifiable {
    case blank
    case oneOnOne
    case standup
    case interview

    var id: Self { self }

    var title: String {
        switch self {
        case .blank: "Untitled note"
        case .oneOnOne: "1:1"
        case .standup: "Standup"
        case .interview: "Interview"
        }
    }

    /// Menu label; the blank case keeps its existing verb.
    var menuTitle: String {
        switch self {
        case .blank: "Blank note"
        default: title
        }
    }

    var summary: String { "" }

    var actionItems: [String] {
        switch self {
        case .blank: []
        case .oneOnOne: ["Follow up from last time", "Topics to cover"]
        case .standup: ["Yesterday", "Today", "Blockers"]
        case .interview: ["Questions", "Impressions", "Next steps"]
        }
    }
}
