import Foundation

/// What Nook remembers about folder suggestions, outside the notes.
///
/// Two small sets of note IDs in the app's preferences: notes whose
/// suggestion was dismissed, and notes the person placed themselves (moved
/// by hand, or moved back with Undo after Nook filed them). Neither belongs
/// in the Markdown: a dismissed hint is not part of the note, and writing
/// frontmatter to remember one would change the file's bytes, its revision
/// and its modification date for something nobody wrote.
///
/// Only UUIDs are stored, never titles or folder names, and each set is
/// capped so a library churned for years cannot grow it without bound.
@MainActor
final class FolderPlacementMemory {
    enum Keys {
        static let dismissed = "folderSuggestions.dismissedNoteIDs"
        static let userPlaced = "folderSuggestions.userPlacedNoteIDs"
    }

    /// Oldest entries are forgotten first. Forgetting one only means a note
    /// could show its suggestion again; it can never move a note, because
    /// automatic filing happens once, right after a recording is saved.
    static let capacity = 2_000

    private let defaults: UserDefaults
    private var dismissed: [String]
    private var userPlaced: [String]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        dismissed = defaults.stringArray(forKey: Keys.dismissed) ?? []
        userPlaced = defaults.stringArray(forKey: Keys.userPlaced) ?? []
    }

    func isDismissed(_ id: UUID) -> Bool {
        dismissed.contains(id.uuidString)
    }

    func isUserPlaced(_ id: UUID) -> Bool {
        userPlaced.contains(id.uuidString)
    }

    func dismissSuggestion(for id: UUID) {
        Self.insert(id, into: &dismissed)
        defaults.set(dismissed, forKey: Keys.dismissed)
    }

    func markUserPlaced(_ ids: some Sequence<UUID>) {
        var changed = false
        for id in ids where !userPlaced.contains(id.uuidString) {
            Self.insert(id, into: &userPlaced)
            changed = true
        }
        if changed { defaults.set(userPlaced, forKey: Keys.userPlaced) }
    }

    private static func insert(_ id: UUID, into list: inout [String]) {
        let value = id.uuidString
        list.removeAll { $0 == value }
        list.append(value)
        if list.count > capacity { list.removeFirst(list.count - capacity) }
    }
}

extension FolderSuggestionIndex {
    /// The suggestion the library actually shows: none while something is
    /// still writing to the note, and none for a note whose hint was
    /// dismissed or that the person placed themselves.
    @MainActor
    func offeredSuggestion(
        for note: MeetingNote,
        isInFolder: Bool,
        isBusy: Bool,
        placements: FolderPlacementMemory
    ) -> FolderSuggestion? {
        guard !isBusy,
              !placements.isDismissed(note.id),
              !placements.isUserPlaced(note.id)
        else { return nil }
        return suggestion(for: note, isInFolder: isInFolder)
    }
}
