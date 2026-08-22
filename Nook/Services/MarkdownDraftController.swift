import Foundation

@MainActor
final class MarkdownDraftController: ObservableObject {
    @Published private(set) var noteID: MeetingNote.ID?
    @Published var rawMarkdown = ""
    @Published private(set) var originalMarkdown = ""
    @Published var statusMessage: String?

    /// When the draft was loaded from disk. A file modified after this point
    /// was changed by something other than Nook.
    private var loadedModificationDate: Date?

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
        do {
            let markdown = try store.rawMarkdown(for: note)
            noteID = note.id
            rawMarkdown = markdown
            originalMarkdown = markdown
            loadedModificationDate = Self.modificationDate(of: note.fileURL)
            statusMessage = nil
        } catch {
            statusMessage = "Nook couldn’t read this file, so the editor shows nothing rather than something stale."
        }
    }

    func save(note: MeetingNote, store: MarkdownStore) throws {
        // Nook is not the only writer of these files, and this editor can sit
        // open while another app changes the one on disk. Saving would then
        // overwrite edits nobody in this window has seen, so it stops and
        // asks for a refresh instead.
        if let current = Self.modificationDate(of: note.fileURL),
           let loaded = loadedModificationDate,
           abs(current.timeIntervalSince(loaded)) > 1 {
            statusMessage = "This file changed outside Nook. Refresh to load it, then reapply your edits."
            return
        }
        try store.saveRawMarkdown(rawMarkdown, for: note)
        originalMarkdown = rawMarkdown
        loadedModificationDate = Self.modificationDate(of: note.fileURL)
        statusMessage = "Saved"
    }

    func discardChanges() {
        rawMarkdown = originalMarkdown
        statusMessage = nil
    }

    private static func modificationDate(of url: URL?) -> Date? {
        guard let url,
              let attributes = try? FileManager.default.attributesOfItem(
                  atPath: url.path
              ) else {
            return nil
        }
        return attributes[.modificationDate] as? Date
    }
}
