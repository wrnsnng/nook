import Foundation

/// What leaving a note has to do about edits that exist only in the window.
enum UnsavedEditDecision: Equatable {
    /// Nothing is at risk; change the selection now.
    case leave
    /// Write the edit, then change the selection. Used where the edit has one
    /// obvious destination and no discard vocabulary of its own.
    case saveFirst
    /// Stop and ask. Used only for the Markdown source editor, which is an
    /// explicit editor with its own Save and Discard.
    case askAboutMarkdown
}

/// Decides what a selection change owes the edits already in the window.
///
/// A pure function so the rule can be tested without driving SwiftUI, and so
/// the answer is the same wherever the question is asked. The library used to
/// consider only the Markdown editor, and the My notes field was thrown away
/// whenever anything moved the selection, including a meeting starting by
/// itself while somebody was mid sentence.
enum LibraryLeaveGuard {
    static func decide(
        hasMarkdownChanges: Bool,
        hasPersonalNotesChanges: Bool
    ) -> UnsavedEditDecision {
        // The Markdown editor comes first when both are dirty: it is the one
        // holding a decision the user has to make, and its alert leaves the
        // selection where it is, so the notes save gets its turn afterwards.
        if hasMarkdownChanges { return .askAboutMarkdown }
        if hasPersonalNotesChanges { return .saveFirst }
        return .leave
    }
}

/// The My notes field's text, held outside the view that draws it.
///
/// It used to be `@State` in `MeetingDetailView`, which meant it existed only
/// as long as that view did. The view is rebuilt whenever the selection
/// changes, and the selection changes on its own when a meeting starts, so
/// anything typed and not explicitly saved was destroyed without a word.
/// Holding it here gives the two places that can end its life, a selection
/// change and a quit, something to ask.
@MainActor
final class PersonalNotesDraftController: ObservableObject {
    /// Words a save refused, held against the note they were typed in.
    ///
    /// A refused save used to leave the field bound to the note it could not
    /// write. Everything typed from then on, about whatever note was on screen
    /// by then, accumulated under that first note's identifier, and the next
    /// flush that succeeded wrote all of it into that note's file. Parking
    /// keeps refused words attached to their own note and retries them only
    /// there, so the live field can belong to what is on screen immediately.
    struct ParkedDraft: Identifiable, Equatable {
        let noteID: MeetingNote.ID
        let noteTitle: String
        let text: String
        /// What My notes contained when these words were first edited. A
        /// refreshed library value must never replace this conflict baseline.
        let savedText: String
        let owner: EditorDraftOwner
        let recoveryID: UUID
        let createdAt: Date
        let baselineRevision: Data?
        /// Why the last attempt did not write, refreshed on every retry.
        var reason: String

        var id: UUID { recoveryID }
    }

    @Published private(set) var noteID: MeetingNote.ID?
    @Published var text = "" {
        didSet {
            guard !text.utf8.elementsEqual(oldValue.utf8) else { return }
            // "Saved" describes the words that were written, so it must not
            // keep standing over words that have changed since.
            if statusMessage == "Saved" { statusMessage = nil }
            checkpointIfNeeded()
        }
    }
    @Published private(set) var savedText = ""
    /// The last save's outcome, shown under the field. "Saved" is a fact; any
    /// other value is the reason a save did not happen.
    @Published var statusMessage: String?
    /// Refused words waiting on their own note, at most one entry per note.
    ///
    /// An array rather than a single slot because a second refusal, for a
    /// different note, must not overwrite the first one's words.
    @Published private(set) var parkedDrafts: [ParkedDraft] = []

    private let recovery: DraftJournal?
    private var owner: EditorDraftOwner?
    private var recoveryID = UUID()
    private var draftCreatedAt = Date()
    private var baselineRevision: Data?
    private var isChangingContext = false

    init(recovery: DraftJournal? = nil) {
        self.recovery = recovery
    }

    var hasExactChanges: Bool {
        noteID != nil && !text.utf8.elementsEqual(savedText.utf8)
    }

    var hasChanges: Bool {
        noteID != nil && Self.normalized(text) != Self.normalized(savedText)
    }

    /// Whether any words exist anywhere that have not reached disk: the live
    /// field, or a draft parked against a note that a save already refused.
    ///
    /// `hasChanges` alone answers only for the note on screen. A leave-guard
    /// that asked just that would say "nothing to do" while a parked draft
    /// for a *different* note sat waiting, which is exactly the silent loss
    /// parking exists to prevent: leaving should give a parked draft the same
    /// chance to be written, or to fail loudly, that a live edit gets.
    var hasUnwrittenNotes: Bool {
        hasExactChanges || !parkedDrafts.isEmpty
    }

    /// Points the draft at a note, keeping unsaved words for a different one.
    ///
    /// Refusing to lose an unsaved edit is what makes a lost selection
    /// survivable: the words stay until something has written them.
    func prepare(for note: MeetingNote, store: MarkdownStore) {
        let incoming = EditorDraftOwner(note: note, libraryURL: store.storageURL)
        guard owner != incoming else { return }
        recovery?.flushSynchronously()
        // A draft belonging to another note is written before this one takes
        // the field over, so no keystroke depends on the window that typed it
        // still being on screen.
        let refusal = hasExactChanges ? saveLiveDraft(store: store) : nil
        if let refusal {
            // Staying bound to the old note here is what made a refused save
            // dangerous. Every keystroke typed against the note now on screen
            // went on accumulating under the old identifier, and the next
            // flush that succeeded wrote them into the old note's file. The
            // refused words are parked against their own note instead, and the
            // field is handed to what is on screen.
            parkLiveDraft(reason: refusal, store: store)
        }
        // Nothing parked a moment ago can succeed now, so only retry when this
        // selection change did not just add to the pile.
        let rescued = refusal == nil ? flushParkedDrafts(store: store) : []

        if let waiting = parkedDrafts.first(where: { $0.owner == incoming }) {
            // Back on the note whose words are still unwritten. They belong in
            // the field they were typed in; the file's copy is the older one.
            restore(waiting, into: note)
            return
        }
        load(from: rescued.first { incoming.matches($0) } ?? note, owner: incoming)
        if let parked = parkedDrafts.first {
            statusMessage = Self.parkedWarning(for: parked)
        }
    }

    /// Adopts the note's stored notes when nothing in the window is newer.
    func refresh(for note: MeetingNote) {
        guard let owner, owner.matches(note) else { return }
        guard !hasExactChanges else { return }
        load(from: note, owner: owner)
    }

    private func load(from note: MeetingNote, owner: EditorDraftOwner) {
        isChangingContext = true
        defer { isChangingContext = false }
        self.owner = owner
        noteID = note.id
        text = note.personalNotes
        savedText = note.personalNotes
        baselineRevision = note.fileRevision
        recoveryID = UUID()
        draftCreatedAt = Date()
        statusMessage = nil
    }

    /// Writes the draft into its note's Markdown file.
    ///
    /// Returns the saved note so the caller can refresh anything reading the
    /// same file. Throws whatever the store refused with, which is the point:
    /// a file changed elsewhere must stop the save rather than overwrite it.
    @discardableResult
    func save(note: MeetingNote, store: MarkdownStore) throws -> MeetingNote {
        guard let owner else { throw EditorDraftOwnershipError.wrongOwner }
        try owner.validate(note: note, store: store)
        let normalized = Self.normalized(text)
        recordSaveIntent(
            owner: owner, id: recoveryID, text: text, baseline: savedText,
            baselineRevision: baselineRevision, createdAt: draftCreatedAt,
            proposed: normalized, store: store
        )
        let saved = try store.updatePersonalNotes(
            normalized,
            for: note,
            expectedPersonalNotes: savedText
        )
        try owner.verifySaved(saved, personalNotes: normalized)
        recovery?.resolve(recoveryID)
        isChangingContext = true
        text = normalized
        savedText = normalized
        noteID = saved.id
        baselineRevision = saved.fileRevision
        recoveryID = UUID()
        draftCreatedAt = Date()
        isChangingContext = false
        statusMessage = "Saved"
        return saved
    }

    /// Saves whatever is pending, finding the note by identifier.
    ///
    /// For callers with no note in hand, such as the quit path. Returns the
    /// reason it could not save, or nil when the words are safe. Parked words
    /// count: they are still somebody's writing, and a quit that reported
    /// nothing while holding them would lose them.
    func saveIfNeeded(store: MarkdownStore) -> String? {
        flushParkedDrafts(store: store)
        let liveReason = saveLiveDraft(store: store)
        guard let parked = parkedDrafts.first else { return liveReason }
        // The field on screen is the more actionable of the two, so it keeps
        // the status line when both have something to say.
        if liveReason == nil {
            statusMessage = Self.parkedWarning(for: parked)
        }
        return liveReason ?? parked.reason
    }

    /// Writes the field that is on screen, if it has anything to write.
    private func saveLiveDraft(store: MarkdownStore) -> String? {
        guard hasExactChanges, let owner else { return nil }
        guard let note = owner.currentNote(in: store) else {
            let reason = Self.missingNoteReason
            statusMessage = reason
            return reason
        }
        do {
            _ = try save(note: note, store: store)
            return nil
        } catch {
            statusMessage = error.localizedDescription
            return error.localizedDescription
        }
    }

    /// Moves the field's refused words into the parked slot for their note.
    private func parkLiveDraft(reason: String, store: MarkdownStore) {
        guard let noteID, let owner else { return }
        let title = owner.currentNote(in: store)?.title ?? owner.title
        parkedDrafts.removeAll { $0.owner == owner }
        parkedDrafts.append(
            ParkedDraft(
                noteID: noteID,
                noteTitle: title,
                text: text,
                savedText: savedText,
                owner: owner,
                recoveryID: recoveryID,
                createdAt: draftCreatedAt,
                baselineRevision: baselineRevision,
                reason: reason
            )
        )
    }

    /// Retries every parked draft against its own note, and only its own note.
    ///
    /// Returns the notes that were rescued, so a caller about to display one
    /// shows the copy that was just written rather than the older one it holds.
    @discardableResult
    private func flushParkedDrafts(store: MarkdownStore) -> [MeetingNote] {
        guard !parkedDrafts.isEmpty else { return [] }
        var rescued: [MeetingNote] = []
        var stillParked: [ParkedDraft] = []
        for var draft in parkedDrafts {
            guard let note = draft.owner.currentNote(in: store)
            else {
                draft.reason = Self.missingNoteReason
                stillParked.append(draft)
                continue
            }
            do {
                try draft.owner.validate(note: note, store: store)
                recordSaveIntent(
                    owner: draft.owner, id: draft.recoveryID, text: draft.text,
                    baseline: draft.savedText, baselineRevision: draft.baselineRevision,
                    createdAt: draft.createdAt, proposed: Self.normalized(draft.text),
                    store: store
                )
                let saved = try store.updatePersonalNotes(
                    draft.text,
                    for: note,
                    expectedPersonalNotes: draft.savedText
                )
                try draft.owner.verifySaved(saved, personalNotes: Self.normalized(draft.text))
                recovery?.resolve(draft.recoveryID)
                rescued.append(saved)
            } catch {
                draft.reason = error.localizedDescription
                stillParked.append(draft)
            }
        }
        parkedDrafts = stillParked
        return rescued
    }

    /// Puts a parked draft back in the field, on the note it was typed in.
    private func restore(_ parked: ParkedDraft, into note: MeetingNote) {
        isChangingContext = true
        defer { isChangingContext = false }
        parkedDrafts.removeAll { $0.id == parked.id }
        owner = parked.owner
        recoveryID = parked.recoveryID
        draftCreatedAt = parked.createdAt
        baselineRevision = parked.baselineRevision
        noteID = note.id
        savedText = parked.savedText
        text = parked.text
        statusMessage = parked.reason
    }

    /// Says whose words are still unwritten, so a refusal is never silent even
    /// once the note it belongs to has left the screen.
    private static func parkedWarning(for parked: ParkedDraft) -> String {
        let subject = parked.noteTitle.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let owner = subject.isEmpty ? "another note" : "“\(subject)”"
        return "Notes you typed on \(owner) still aren’t written. \(parked.reason)"
    }

    private static let missingNoteReason =
        "The note these belong to is no longer in this folder."

    func discardChanges() {
        recovery?.resolve(recoveryID)
        isChangingContext = true
        text = savedText
        isChangingContext = false
        recoveryID = UUID()
        draftCreatedAt = Date()
        statusMessage = nil
    }

    /// A folder change cannot change the owner captured by an earlier edit.
    func libraryWillChange() {
        checkpointIfNeeded()
        recovery?.flushSynchronously()
    }

    /// Called only after the original file was successfully moved to Trash.
    func noteWasDeleted(_ note: MeetingNote) {
        for parked in parkedDrafts where parked.owner.matches(note) {
            recovery?.resolve(parked.recoveryID)
        }
        parkedDrafts.removeAll { $0.owner.matches(note) }
        guard owner?.matches(note) == true else { return }
        recovery?.resolve(recoveryID)
        isChangingContext = true
        owner = nil
        noteID = nil
        text = ""
        savedText = ""
        baselineRevision = nil
        isChangingContext = false
        recoveryID = UUID()
        draftCreatedAt = Date()
        statusMessage = nil
    }

    private func checkpointIfNeeded() {
        guard !isChangingContext, let recovery, let owner else { return }
        guard hasExactChanges else {
            recovery.resolve(recoveryID)
            recoveryID = UUID()
            draftCreatedAt = Date()
            return
        }
        recovery.checkpoint(DraftCheckpoint(
            id: recoveryID,
            kind: .personalNotes,
            libraryPath: owner.libraryPath,
            originalFilePath: owner.filePath,
            noteID: owner.noteID,
            title: owner.title,
            text: text,
            baseline: savedText,
            baselineRevision: baselineRevision,
            createdAt: draftCreatedAt,
            sessionID: recovery.sessionID
        ))
    }

    private func recordSaveIntent(
        owner: EditorDraftOwner, id: UUID, text: String, baseline: String,
        baselineRevision: Data?, createdAt: Date, proposed: String,
        store: MarkdownStore
    ) {
        guard let recovery, let path = owner.filePath,
              var candidate = owner.currentNote(in: store)
        else { return }
        let alreadyMatches = candidate.personalNotes.utf8.elementsEqual(proposed.utf8)
        guard candidate.personalNotes.utf8.elementsEqual(Self.normalized(baseline).utf8)
                || alreadyMatches else { return }
        // An already-applied edit keeps the original Markdown bytes. Its
        // completion must describe those bytes, not a hypothetical re-encode,
        // so recovery can reconcile a crash before checkpoint cleanup.
        let existingRevision = alreadyMatches ? candidate.fileRevision : nil
        candidate.personalNotes = proposed
        let completion = DraftCompletion(
            targetPath: path,
            noteID: owner.noteID,
            revision: existingRevision
                ?? MeetingNote.contentRevision(Data(MarkdownCodec.encode(candidate).utf8))
        )
        // Ordinary Save stays available if the recovery disk is unavailable.
        // The journal retains its failure state, and only verified saved bytes
        // allow this copy to be resolved afterwards.
        try? recovery.persistSynchronously(DraftCheckpoint(
            id: id,
            kind: .personalNotes,
            libraryPath: owner.libraryPath,
            originalFilePath: path,
            noteID: owner.noteID,
            title: owner.title,
            text: text,
            baseline: baseline,
            baselineRevision: baselineRevision,
            createdAt: createdAt,
            sessionID: recovery.sessionID,
            completion: completion
        ))
    }

    /// The store trims what it writes, so a draft that differs only in
    /// surrounding whitespace is not an edit anybody would miss.
    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A note UUID is copied along with its library. The captured directory and
/// original path keep such a copy from becoming an old draft's destination.
struct EditorDraftOwner: Equatable {
    let libraryPath: String
    let filePath: String?
    let noteID: UUID
    let title: String

    init(note: MeetingNote, libraryURL: URL) {
        libraryPath = Self.canonicalPath(libraryURL)
        filePath = note.fileURL.map(Self.canonicalPath)
        noteID = note.id
        title = note.title
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.libraryPath == rhs.libraryPath && lhs.filePath == rhs.filePath
            && lhs.noteID == rhs.noteID
    }

    func matches(_ note: MeetingNote) -> Bool {
        noteID == note.id && filePath == note.fileURL.map(Self.canonicalPath)
    }

    @MainActor
    func currentNote(in store: MarkdownStore) -> MeetingNote? {
        guard Self.canonicalPath(store.storageURL) == libraryPath else { return nil }
        let candidates = store.notes.filter { $0.id == noteID }
        guard candidates.count == 1, let note = candidates.first, matches(note) else { return nil }
        return note
    }

    @MainActor
    func validate(note: MeetingNote, store: MarkdownStore) throws {
        guard matches(note), currentNote(in: store) != nil,
              let filePath,
              Self.canonicalPath(URL(fileURLWithPath: filePath).deletingLastPathComponent()) == libraryPath
        else { throw EditorDraftOwnershipError.wrongOwner }
        // Even an older model with no revision cannot recreate a missing file.
        guard FileManager.default.fileExists(atPath: filePath) else {
            throw CocoaError(.fileNoSuchFile)
        }
    }

    func verifySaved(_ saved: MeetingNote, personalNotes: String? = nil) throws {
        guard matches(saved), let filePath, let revision = saved.fileRevision,
              let bytes = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
              MeetingNote.contentRevision(bytes) == revision
        else { throw MarkdownStoreError.saveReadBackFailed }
        if let personalNotes {
            guard let source = String(data: bytes, encoding: .utf8),
                  MarkdownCodec.decode(source)?.personalNotes == personalNotes
            else { throw MarkdownStoreError.saveReadBackFailed }
        }
    }

    private static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

enum EditorDraftOwnershipError: LocalizedError {
    case wrongOwner

    var errorDescription: String? {
        "This draft belongs to its original note and folder. It was not saved into another location."
    }
}
