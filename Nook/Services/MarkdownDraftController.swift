import Foundation

@MainActor
final class MarkdownDraftController: ObservableObject {
    @Published private(set) var noteID: MeetingNote.ID?
    @Published var rawMarkdown = "" {
        didSet {
            guard !rawMarkdown.utf8.elementsEqual(oldValue.utf8) else { return }
            if statusMessage == "Saved" { statusMessage = nil }
            checkpointIfNeeded()
        }
    }
    @Published private(set) var originalMarkdown = ""
    @Published var statusMessage: String?

    /// Comes from the same byte read as `originalMarkdown`, and stays fixed
    /// across reloads while this editor has changes.
    private var loadedFileRevision: Data?
    private let recovery: DraftJournal?
    private var owner: EditorDraftOwner?
    private var loadedLibraryIdentity: LibraryNoteIdentity?
    private var recoveryID = UUID()
    private var draftCreatedAt = Date()
    private var isChangingContext = false

    init(recovery: DraftJournal? = nil) {
        self.recovery = recovery
    }

    var libraryIdentity: LibraryNoteIdentity? { loadedLibraryIdentity }

    var hasChanges: Bool {
        noteID != nil && !rawMarkdown.utf8.elementsEqual(originalMarkdown.utf8)
    }

    func prepare(for note: MeetingNote, store: MarkdownStore) {
        let incoming = EditorDraftOwner(note: note, libraryURL: store.storageURL)
        guard owner != incoming else { return }
        recovery?.flushSynchronously()
        guard !hasChanges else {
            statusMessage = "Save or discard the other meeting’s edit before opening this Markdown source."
            return
        }
        load(for: note, store: store)
    }

    func refresh(for note: MeetingNote, store: MarkdownStore) {
        // `prepare` is the only operation allowed to switch notes. A save or
        // model callback from a view that just disappeared must not redirect
        // the shared editor underneath the newly selected note.
        guard owner == EditorDraftOwner(note: note, libraryURL: store.storageURL) else { return }
        guard !hasChanges else {
            statusMessage = "Save or revert Markdown edits before refreshing this source."
            return
        }
        load(for: note, store: store)
    }

    private func load(for note: MeetingNote, store: MarkdownStore) {
        do {
            let snapshot = try store.markdownSnapshot(for: note)
            let markdown = snapshot.markdown
            // Loading is one context transition. Observers must never pair
            // the new source with the previous note's identity or baseline.
            isChangingContext = true
            defer { isChangingContext = false }
            owner = EditorDraftOwner(note: note, libraryURL: store.storageURL)
            loadedLibraryIdentity = note.libraryIdentity
            noteID = note.id
            rawMarkdown = markdown
            originalMarkdown = markdown
            loadedFileRevision = snapshot.revision
            recoveryID = UUID()
            draftCreatedAt = Date()
            statusMessage = nil
        } catch {
            statusMessage = "Nook couldn’t read this file, so the editor shows nothing rather than something stale."
        }
    }

    func save(note: MeetingNote, store: MarkdownStore) throws {
        guard noteID == note.id, let owner, owner.matches(note) else {
            statusMessage = "This Markdown draft belongs to a different note and was not saved."
            throw MarkdownDraftError.wrongNote
        }
        // Nook is not the only writer of these files, and this editor can sit
        // open while another app changes the one on disk. Saving would then
        // overwrite edits nobody in this window has seen, so it stops and
        // asks for a refresh instead.
        do {
            try owner.validate(note: note, store: store)
            // A source edit cannot change which library entry owns this file.
            // Otherwise the store would keep the old entry and upsert this
            // file under another note's UUID while the draft kept its old owner.
            if let decoded = MarkdownCodec.decode(rawMarkdown), decoded.id != owner.noteID {
                throw MarkdownStoreError.noteIdentityChanged
            }
            if let recovery, let path = owner.filePath {
                var intent = checkpoint(owner: owner, recovery: recovery)
                intent.completion = DraftCompletion(
                    targetPath: path,
                    noteID: owner.noteID,
                    revision: MeetingNote.contentRevision(Data(rawMarkdown.utf8))
                )
                // A failed backup must not prevent an ordinary Save. The
                // journal keeps its warning and previous complete checkpoint.
                try? recovery.persistSynchronously(intent)
            }
            try store.saveRawMarkdown(
                rawMarkdown,
                for: note,
                expectedRevision: loadedFileRevision
            )
            // The store's write is not yet evidence that these exact source
            // bytes can be recovered from the intended destination.
            let persisted = try store.markdownSnapshot(for: note)
            guard persisted.markdown.utf8.elementsEqual(rawMarkdown.utf8) else {
                throw MarkdownStoreError.saveReadBackFailed
            }
            loadedFileRevision = persisted.revision
        } catch {
            statusMessage = error.localizedDescription
            // Save-and-quit treats a normal return as success. A refused
            // write must throw so quitting cannot discard this live draft.
            throw error
        }
        recovery?.resolve(recoveryID)
        originalMarkdown = rawMarkdown
        recoveryID = UUID()
        draftCreatedAt = Date()
        statusMessage = "Saved"
    }

    func discardChanges() {
        recovery?.resolve(recoveryID)
        isChangingContext = true
        rawMarkdown = originalMarkdown
        isChangingContext = false
        recoveryID = UUID()
        draftCreatedAt = Date()
        statusMessage = nil
    }

    /// Keep the live draft bound to the old folder until it is deliberately
    /// saved or discarded. A copied UUID in a new folder is not its owner.
    func libraryWillChange() {
        checkpointIfNeeded()
        recovery?.flushSynchronously()
    }

    /// Called only after the original file was successfully moved to Trash.
    func noteWasDeleted(_ note: MeetingNote) {
        guard owner?.matches(note) == true else { return }
        recovery?.resolve(recoveryID)
        isChangingContext = true
        owner = nil
        loadedLibraryIdentity = nil
        noteID = nil
        rawMarkdown = ""
        originalMarkdown = ""
        loadedFileRevision = nil
        isChangingContext = false
        recoveryID = UUID()
        draftCreatedAt = Date()
        statusMessage = nil
    }

    private func checkpointIfNeeded() {
        guard !isChangingContext, let recovery, let owner else { return }
        guard hasChanges else {
            recovery.resolve(recoveryID)
            recoveryID = UUID()
            draftCreatedAt = Date()
            return
        }
        recovery.checkpoint(checkpoint(owner: owner, recovery: recovery))
    }

    private func checkpoint(owner: EditorDraftOwner, recovery: DraftJournal) -> DraftCheckpoint {
        DraftCheckpoint(
            id: recoveryID,
            kind: .markdown,
            libraryPath: owner.libraryPath,
            originalFilePath: owner.filePath,
            noteID: owner.noteID,
            title: owner.title,
            text: rawMarkdown,
            baseline: originalMarkdown,
            baselineRevision: loadedFileRevision,
            createdAt: draftCreatedAt,
            sessionID: recovery.sessionID
        )
    }
}

enum MarkdownDraftError: LocalizedError, Equatable {
    case wrongNote

    var errorDescription: String? {
        "This Markdown draft belongs to a different note and was not saved."
    }
}
