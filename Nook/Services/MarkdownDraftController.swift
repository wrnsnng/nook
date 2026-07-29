import Foundation

@MainActor
final class MarkdownDraftController: ObservableObject {
    @Published private(set) var noteID: MeetingNote.ID?
    @Published var rawMarkdown = ""
    @Published private(set) var originalMarkdown = ""
    @Published var statusMessage: String?

    var hasChanges: Bool {
        noteID != nil && rawMarkdown != originalMarkdown
    }

    func prepare(for note: MeetingNote, store: MarkdownStore) {
        guard noteID != note.id else { return }
        guard !hasChanges else {
            statusMessage = "Save or discard the other meeting’s edit before opening this Markdown source."
            return
        }
        load(for: note, store: store)
    }

    func refresh(for note: MeetingNote, store: MarkdownStore) {
        guard !hasChanges else {
            statusMessage = "Save or revert Markdown edits before refreshing this source."
            return
        }
        load(for: note, store: store)
    }

    private func load(for note: MeetingNote, store: MarkdownStore) {
        let markdown = store.rawMarkdown(for: note)
        noteID = note.id
        rawMarkdown = markdown
        originalMarkdown = markdown
        statusMessage = nil
    }

    func save(note: MeetingNote, store: MarkdownStore) throws {
        try store.saveRawMarkdown(rawMarkdown, for: note)
        originalMarkdown = rawMarkdown
        statusMessage = "Saved"
    }

    func discardChanges() {
        rawMarkdown = originalMarkdown
        statusMessage = nil
    }
}
