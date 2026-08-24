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
        /// Why the last attempt did not write, refreshed on every retry.
        var reason: String

        var id: MeetingNote.ID { noteID }
    }

    @Published private(set) var noteID: MeetingNote.ID?
    @Published var text = "" {
        didSet {
            guard text != oldValue else { return }
            // "Saved" describes the words that were written, so it must not
            // keep standing over words that have changed since.
            if statusMessage == "Saved" { statusMessage = nil }
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
        hasChanges || !parkedDrafts.isEmpty
    }

    /// Points the draft at a note, keeping unsaved words for a different one.
    ///
    /// Refusing to lose an unsaved edit is what makes a lost selection
    /// survivable: the words stay until something has written them.
    func prepare(for note: MeetingNote, store: MarkdownStore) {
        guard noteID != note.id else { return }
        // A draft belonging to another note is written before this one takes
        // the field over, so no keystroke depends on the window that typed it
        // still being on screen.
        let refusal = hasChanges ? saveLiveDraft(store: store) : nil
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

        if let waiting = parkedDrafts.first(where: { $0.noteID == note.id }) {
            // Back on the note whose words are still unwritten. They belong in
            // the field they were typed in; the file's copy is the older one.
            restore(waiting, into: note)
            return
        }
        load(from: rescued.first { $0.id == note.id } ?? note)
        if let parked = parkedDrafts.first {
            statusMessage = Self.parkedWarning(for: parked)
        }
    }

    /// Adopts the note's stored notes when nothing in the window is newer.
    func refresh(for note: MeetingNote) {
        guard noteID == note.id else { return }
        guard !hasChanges else { return }
        load(from: note)
    }

    private func load(from note: MeetingNote) {
        noteID = note.id
        text = note.personalNotes
        savedText = note.personalNotes
        statusMessage = nil
    }

    /// Writes the draft into its note's Markdown file.
    ///
    /// Returns the saved note so the caller can refresh anything reading the
    /// same file. Throws whatever the store refused with, which is the point:
    /// a file changed elsewhere must stop the save rather than overwrite it.
    @discardableResult
    func save(note: MeetingNote, store: MarkdownStore) throws -> MeetingNote {
        let normalized = Self.normalized(text)
        let saved = try store.updatePersonalNotes(normalized, for: note)
        text = normalized
        savedText = normalized
        noteID = saved.id
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
        guard hasChanges, let noteID else { return nil }
        guard let note = store.notes.first(where: { $0.id == noteID }) else {
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
        guard let noteID else { return }
        let title = store.notes.first { $0.id == noteID }?.title ?? ""
        parkedDrafts.removeAll { $0.noteID == noteID }
        parkedDrafts.append(
            ParkedDraft(
                noteID: noteID,
                noteTitle: title,
                text: Self.normalized(text),
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
            guard let note = store.notes.first(where: { $0.id == draft.noteID })
            else {
                draft.reason = Self.missingNoteReason
                stillParked.append(draft)
                continue
            }
            do {
                rescued.append(
                    try store.updatePersonalNotes(draft.text, for: note)
                )
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
        parkedDrafts.removeAll { $0.noteID == parked.noteID }
        noteID = note.id
        savedText = note.personalNotes
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
        text = savedText
        statusMessage = nil
    }

    /// The store trims what it writes, so a draft that differs only in
    /// surrounding whitespace is not an edit anybody would miss.
    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
