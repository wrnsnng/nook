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

    var hasChanges: Bool {
        noteID != nil && Self.normalized(text) != Self.normalized(savedText)
    }

    /// Points the draft at a note, keeping unsaved words for a different one.
    ///
    /// Refusing to load over an unsaved edit is what makes a lost selection
    /// survivable: the words stay until something has written them.
    func prepare(for note: MeetingNote, store: MarkdownStore) {
        guard noteID != note.id else { return }
        // A draft belonging to another note is written before this one takes
        // the field over, so no keystroke depends on the window that typed it
        // still being on screen. If that write fails the old words stay in the
        // field with the reason beside them, which is visibly wrong and
        // recoverable, rather than quietly gone.
        if hasChanges, saveIfNeeded(store: store) != nil { return }
        load(from: note)
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
    /// reason it could not save, or nil when the words are safe.
    func saveIfNeeded(store: MarkdownStore) -> String? {
        guard hasChanges, let noteID else { return nil }
        guard let note = store.notes.first(where: { $0.id == noteID }) else {
            let reason = "The note these belong to is no longer in this folder."
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
