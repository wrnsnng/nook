import Foundation

/// Settings > General > Folders. On unless the person turns it off.
enum AutoFilingPreference {
    static let key = "fileRecurringMeetingsAutomatically"

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }
}

/// A note Nook moved into a folder on its own, and where it came from, so
/// the notice can offer Undo.
struct AutoFiledNote: Hashable, Sendable {
    let noteID: UUID
    let title: String
    let folder: String
    let from: LibraryNoteIdentity
    let to: LibraryNoteIdentity
    let filedAt: Date

    var notice: String { "Filed in \(folder) with earlier sittings" }
}

extension Notification.Name {
    /// Posted on the main actor after a recurring meeting was filed. The
    /// object is the `AutoFiledNote`.
    static let nookNoteAutoFiled = Notification.Name("com.localfirst.nook.note-auto-filed")
}

/// Files a newly recorded meeting with the earlier sittings of its series.
///
/// The only folder change Nook makes without being asked, so it is narrow:
/// it happens once per new recording, after the first save and after the
/// background summary settles (the summary can give a placeholder title a
/// real one, and a running summary would refuse the move anyway). It never
/// touches a note that is in a folder already, one the person placed
/// themselves, or one something is still writing to; for those, and for
/// every non-recurring meeting, the detail pane suggests instead.
///
/// Moves go through `MarkdownStore.move`, with the same revision and busy
/// checks as a move from the sidebar.
@MainActor
final class FolderAutoFiler {
    enum Outcome: Equatable {
        case filed(AutoFiledNote)
        /// Not a recurring meeting with a consistent folder, or no longer
        /// Nook's to place. Nothing more will be tried.
        case notEligible
        /// Something is writing to the note, or an editor holds unsaved
        /// words for it. Worth trying again shortly.
        case busy
        /// The move itself failed. Left where it is; the suggestion remains.
        case failed
    }

    private let store: MarkdownStore
    private let defaults: UserDefaults
    /// Whether the calendar event this meeting was recorded from repeats.
    /// Nil when calendar context is off: then only the library's own history
    /// decides.
    var calendarRecurrence: (@MainActor (_ title: String, _ startedAt: Date) async -> Bool)?
    /// Unsaved words for this note in an editor. Moving now would leave that
    /// editor pointed at the old path, so filing waits for the save.
    var hasUnsavedEdits: (@MainActor (MeetingNote) -> Bool)?
    var onFiled: (@MainActor (AutoFiledNote) -> Void)?
    var retryDelay: Duration = .seconds(3)
    var maximumAttempts = 20

    private var pending: [UUID: Task<Void, Never>] = [:]

    init(store: MarkdownStore, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
    }

    /// Called once when a recording has just created a note. `work` is the
    /// background summary, if one started.
    @discardableResult
    func newMeetingSaved(_ note: MeetingNote, after work: Task<Void, Never>?) -> Task<Void, Never> {
        pending[note.id]?.cancel()
        let generation = store.storageGeneration
        let id = note.id
        let task = Task { [weak self] in
            await work?.value
            guard let self, !Task.isCancelled else { return }
            await self.fileWhenReady(noteID: id, generation: generation)
            self.pending[id] = nil
        }
        pending[id] = task
        return task
    }

    func cancelAll() {
        for task in pending.values { task.cancel() }
        pending.removeAll()
    }

    private func fileWhenReady(noteID: UUID, generation: Int) async {
        guard let note = store.uniqueNote(id: noteID) else { return }
        let recurring = await calendarRecurrence?(note.title, note.startedAt) ?? false
        for attempt in 0..<max(1, maximumAttempts) {
            guard !Task.isCancelled else { return }
            let outcome = self.attempt(
                noteID: noteID, generation: generation, calendarSaysRecurring: recurring
            )
            guard outcome == .busy, attempt + 1 < maximumAttempts else { return }
            do { try await Task.sleep(for: retryDelay) } catch { return }
        }
    }

    /// One try, with no waiting. Public so the rules can be tested directly.
    func attempt(noteID: UUID, generation: Int, calendarSaysRecurring: Bool) -> Outcome {
        guard store.storageGeneration == generation,
              AutoFilingPreference.isEnabled(in: defaults),
              let note = store.uniqueNote(id: noteID),
              store.folderName(of: note) == nil,
              !store.folderPlacements.isUserPlaced(noteID)
        else { return .notEligible }
        let index = FolderSuggestionIndex(
            notes: store.notes, folders: store.folders, libraryURL: store.storageURL
        )
        guard let folder = index.autoFilingFolder(
            for: note, calendarSaysRecurring: calendarSaysRecurring
        ) else { return .notEligible }
        if store.summarySessions.isRunning(for: note.libraryIdentity)
            || store.isNoteBusy?(note.libraryIdentity) == true
            || hasUnsavedEdits?(note) == true {
            return .busy
        }
        do {
            let moved = try store.move(note, toFolder: folder)
            let filing = AutoFiledNote(
                noteID: noteID,
                title: moved.title,
                folder: store.folderName(of: moved) ?? folder,
                from: note.libraryIdentity,
                to: moved.libraryIdentity,
                filedAt: Date()
            )
            store.lastAutoFiling = filing
            onFiled?(filing)
            return .filed(filing)
        } catch LibraryFolderError.noteIsBusy {
            return .busy
        } catch {
            return .failed
        }
    }
}
