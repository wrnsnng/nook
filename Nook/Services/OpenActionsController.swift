import EventKit
import Foundation

/// Only the explicitly requested reminder crosses the EventKit boundary.
/// Keeping that boundary lazy also lets tests exercise export arbitration
/// without constructing an event store or consulting the user's calendars.
struct ReminderExportPayload: Equatable, Sendable {
    let title: String
    let dueDateComponents: DateComponents?
}

@MainActor
struct ReminderExportClient {
    var requestAccess: @MainActor () async throws -> Bool
    var save: @MainActor (ReminderExportPayload) throws -> Void

    static func live() -> Self {
        let eventStore = EKEventStore()
        return Self(
            requestAccess: { try await eventStore.requestFullAccessToReminders() },
            save: { payload in
                guard let calendar = eventStore.defaultCalendarForNewReminders()
                    ?? eventStore.calendars(for: .reminder).first else {
                    throw ReminderExportError.noList
                }
                let reminder = EKReminder(eventStore: eventStore)
                reminder.title = payload.title
                reminder.calendar = calendar
                reminder.dueDateComponents = payload.dueDateComponents
                try eventStore.save(reminder, commit: true)
            }
        )
    }
}

/// Cancellation can arrive on any executor while the system permission
/// request is suspended. A cancelled request must not reserve an action
/// indefinitely if that request does not resume promptly.
final class ReminderExportReservation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

/// Every Library window shares this coordinator. Success is re-read before
/// each check and merged at commit, so a controller created earlier cannot
/// overwrite another window's receipts with its stale cached set.
@MainActor
final class ReminderExportState {
    static let defaultsKey = "OpenActionsController.exportedReminderKeys"
    static let shared = ReminderExportState(
        load: { Set(UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []) },
        persist: { UserDefaults.standard.set(Array($0), forKey: defaultsKey) }
    )

    enum Reservation {
        case alreadyExported
        case alreadyRunning
        case acquired(ReminderExportReservation)
    }

    private let load: @MainActor () -> Set<String>
    private let persist: @MainActor (Set<String>) -> Void
    private var inFlight: [String: ReminderExportReservation] = [:]

    init(
        load: @escaping @MainActor () -> Set<String>,
        persist: @escaping @MainActor (Set<String>) -> Void
    ) {
        self.load = load
        self.persist = persist
    }

    var exportedKeys: Set<String> { load() }

    func reserve(_ key: String) -> Reservation {
        if load().contains(key) { return .alreadyExported }
        if let existing = inFlight[key], !existing.isCancelled { return .alreadyRunning }
        let reservation = ReminderExportReservation()
        inFlight[key] = reservation
        return .acquired(reservation)
    }

    func release(_ key: String, reservation: ReminderExportReservation) {
        // A late cancelled request cannot release its successor's claim.
        if inFlight[key] === reservation { inFlight.removeValue(forKey: key) }
    }

    func recordSuccess(_ key: String) {
        var keys = load()
        keys.insert(key)
        persist(keys)
    }
}

struct ReminderExportLibrarySnapshot {
    let directoryURL: URL
    let generation: Int
    let isLoading: Bool
    let notes: [MeetingNote]
}

private enum ReminderExportError: LocalizedError {
    case noList
    case libraryChanged
    case libraryLoading
    case sourceChanged

    var errorDescription: String? {
        switch self {
        case .noList: "No Reminders list was available."
        case .libraryChanged:
            "The notes folder changed. Review the action before sending it to Reminders."
        case .libraryLoading:
            "Wait for the notes folder to finish loading before sending an action to Reminders."
        case .sourceChanged:
            "That action changed or is no longer available. Refresh the library and review it before sending it to Reminders."
        }
    }
}

/// One unchecked action item across the whole library, addressed back to its
/// line in its note's file.
struct OpenAction: Identifiable, Hashable {
    let noteID: UUID
    let itemIndex: Int
    /// The full stored text, including any `[due: ...]` suffix.
    let text: String
    /// The optional due date parsed out of that suffix.
    let dueDate: Date?
    let noteTitle: String
    let startedAt: Date
    /// The row's authority is the file snapshot it was read from, not just
    /// the UUID, which Finder copies and copied libraries can share.
    let sourceFileURL: URL?
    let sourceRevision: Data?

    init(
        noteID: UUID, itemIndex: Int, text: String, dueDate: Date?,
        noteTitle: String, startedAt: Date,
        sourceFileURL: URL? = nil, sourceRevision: Data? = nil
    ) {
        self.noteID = noteID
        self.itemIndex = itemIndex
        self.text = text
        self.dueDate = dueDate
        self.noteTitle = noteTitle
        self.startedAt = startedAt
        self.sourceFileURL = sourceFileURL?.standardizedFileURL.resolvingSymlinksInPath()
        self.sourceRevision = sourceRevision
    }

    var id: String {
        "\(sourceFileURL?.path ?? "")|\(noteID.uuidString)#\(itemIndex)"
    }

    /// What the user reads: the wording without its bookkeeping.
    var displayText: String {
        ActionItemLine.strippingDueSuffix(from: text)
    }

    /// Sidebar chip text for the due date, and whether it has lapsed.
    func dueChip(
        asOf now: Date = Date(),
        calendar: Calendar = .current
    ) -> (text: String, isOverdue: Bool) {
        guard let dueDate else { return ("", false) }
        if calendar.isDateInToday(dueDate) { return ("Due today", false) }
        if calendar.isDateInTomorrow(dueDate) { return ("Due tomorrow", false) }
        if dueDate < calendar.startOfDay(for: now) {
            if calendar.isDateInYesterday(dueDate) {
                return ("Due yesterday", true)
            }
            let days = calendar.dateComponents(
                [.day],
                from: calendar.startOfDay(for: dueDate),
                to: calendar.startOfDay(for: now)
            ).day ?? 0
            return ("Overdue \(days)d", true)
        }
        return (
            "Due " + dueDate.formatted(.dateTime.month().day()),
            false
        )
    }
}

/// What `refresh` last read from one note's file, so the next refresh can
/// tell whether re-reading is necessary at all.
private struct CachedNoteActions: Sendable {
    let url: URL
    let revision: Data
    let actions: [OpenAction]
}

/// Aggregates unfinished action items from every meeting note.
///
/// Items are read straight from each file because checkbox state is not part
/// of the decoded model; that keeps the model portable while still making
/// follow-through possible. Toggling rewrites exactly one line of the file
/// through the codec, so nothing else in the document moves.
@MainActor
final class OpenActionsController: ObservableObject {
    @Published private(set) var entries: [OpenAction] = []
    // No surface displays this bookkeeping state. Publishing its transitions
    // rebuilt every Library row even when the action list stayed identical.
    private(set) var isRefreshing = false
    @Published private(set) var lastError: String?
    /// Successful exports visible in the current action list.
    @Published private(set) var exportedIDs: Set<String> = []

    private var refreshGeneration = 0
    /// Keyed by note id. `store.notes` publishes on every save across the
    /// whole app, and every publish used to re-read and re-parse every
    /// action-bearing note's file from disk regardless of whether that note
    /// had changed. Only a matching file URL and exact content revision permit
    /// reuse. Ambiguous UUIDs never enter this cache or the action list.
    private var cache: [UUID: CachedNoteActions] = [:]

    private let reminderExports: ReminderExportState
    private let makeReminderClient: @MainActor () -> ReminderExportClient
    private let reminderCalendar: Calendar
    private var reminderRequests: [String: UUID] = [:]
    private var reminderError: (key: String, message: String)?

    init(
        reminderExports: ReminderExportState = .shared,
        makeReminderClient: @escaping @MainActor () -> ReminderExportClient = ReminderExportClient.live,
        reminderCalendar: Calendar = .current
    ) {
        self.reminderExports = reminderExports
        self.makeReminderClient = makeReminderClient
        self.reminderCalendar = reminderCalendar
    }

    /// Re-reads action state from disk. Notes are unchanged between saves,
    /// but files can also be edited outside Nook, so this never assumes.
    func refresh(store: MarkdownStore) async {
        refreshGeneration += 1
        let generation = refreshGeneration
        isRefreshing = true

        // Spoken notes keep their checkboxes inline in the body, so their
        // decoded model never lists items; they stay eligible on kind.
        let duplicates = Self.duplicateIDs(in: store.notes)
        let notes = store.notes
            .filter { !duplicates.contains($0.id) && (!$0.actionItems.isEmpty || $0.kind == .spoken) }
            .sorted(by: { $0.startedAt > $1.startedAt })

        var reused: [UUID: CachedNoteActions] = [:]
        var toRead: [MeetingNote] = []
        for note in notes {
            guard let url = note.fileURL else { continue }
            if let cached = cache[note.id],
               cached.url == url,
               cached.revision == note.fileRevision {
                reused[note.id] = cached
            } else {
                toRead.append(note)
            }
        }

        let freshlyRead: [(UUID, CachedNoteActions)] = await Task.detached(
            priority: .userInitiated
        ) {
            toRead.compactMap { note -> (UUID, CachedNoteActions)? in
                guard let url = note.fileURL,
                      let bytes = try? Data(contentsOf: url),
                      let markdown = String(data: bytes, encoding: .utf8)
                else { return nil }
                let revision = MeetingNote.contentRevision(bytes)
                guard note.fileRevision == nil || revision == note.fileRevision else { return nil }
                let actions = Self.actionItemLines(for: note, in: markdown)
                    .filter { !$0.isChecked }
                    .map { item in
                        OpenAction(
                            noteID: note.id,
                            itemIndex: item.index,
                            text: item.text,
                            dueDate: item.dueDate,
                            noteTitle: note.title,
                            startedAt: note.startedAt,
                            sourceFileURL: url,
                            sourceRevision: revision
                        )
                    }
                return (
                    note.id,
                    CachedNoteActions(
                        url: url,
                        revision: revision,
                        actions: actions
                    )
                )
            }
        }.value

        guard generation == refreshGeneration else { return }

        for (id, cached) in freshlyRead {
            reused[id] = cached
        }
        // Drop notes that are no longer eligible (every item checked off,
        // the note deleted, or its file gone), so the cache does not grow
        // without bound.
        let currentDuplicates = Self.duplicateIDs(in: store.notes)
        let currentNotes = store.notes.filter { !currentDuplicates.contains($0.id) }
        let currentByID = Dictionary(uniqueKeysWithValues: currentNotes.map { ($0.id, $0) })
        cache = reused.filter { id, cached in
            guard let current = currentByID[id] else { return false }
            return current.fileURL == cached.url
                && (current.fileRevision == nil || current.fileRevision == cached.revision)
        }

        let combined = currentNotes.flatMap { cache[$0.id]?.actions ?? [] }
        let refreshedEntries = Self.sortedByDueUrgency(combined)
        // Equality includes the exact source revision. Identical wording from
        // a changed file still needs a new row with current mutation authority.
        if entries != refreshedEntries { entries = refreshedEntries }
        let exportedKeys = reminderExports.exportedKeys
        let refreshedExportedIDs = Set(refreshedEntries.filter {
            exportedKeys.contains(Self.exportKey(for: $0))
        }.map(\.id))
        if exportedIDs != refreshedExportedIDs { exportedIDs = refreshedExportedIDs }
        if !currentDuplicates.isEmpty {
            let message = OpenActionMutationError.ambiguousIdentity.localizedDescription
            if lastError != message { lastError = message }
        } else if lastError == OpenActionMutationError.ambiguousIdentity.localizedDescription {
            lastError = nil
        }
        isRefreshing = false
    }

    /// Dated items lead, soonest deadline first; undated items follow by
    /// recency. Overdue items therefore surface at the very top.
    nonisolated static func sortedByDueUrgency(
        _ entries: [OpenAction]
    ) -> [OpenAction] {
        entries.sorted { lhs, rhs in
            switch (lhs.dueDate, rhs.dueDate) {
            case let (left?, right?):
                return left == right
                    ? lhs.startedAt > rhs.startedAt
                    : left < right
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            default:
                return lhs.startedAt > rhs.startedAt
            }
        }
    }

    /// Checkbox lines where this note keeps them: the Action items section
    /// for meetings and digests, anywhere in the body for spoken notes.
    nonisolated private static func actionItemLines(
        for note: MeetingNote,
        in markdown: String
    ) -> [ActionItemLine] {
        note.kind == .spoken
            ? MarkdownCodec.spokenCheckboxLines(in: markdown)
            : MarkdownCodec.actionItemLines(in: markdown)
    }

    /// Sets or clears an item's due date by editing one line of its file.
    func setDue(
        _ entry: OpenAction,
        on date: Date?,
        store: MarkdownStore
    ) async {
        await change(entry, store: store) { note, current, markdown in
            note.kind == .spoken
                ? MarkdownCodec.markdownBySettingSpokenCheckboxDue(
                    current, dueTo: date, in: markdown)
                : MarkdownCodec.markdownBySettingActionItemDue(
                    current, dueTo: date, in: markdown)
        }
    }

    /// Checks an item off, or reopens it, by editing one line of its file.
    func toggle(_ entry: OpenAction, store: MarkdownStore) async {
        await change(entry, store: store) { note, current, markdown in
            note.kind == .spoken
                ? MarkdownCodec.markdownBySettingSpokenCheckbox(
                    current, checked: !current.isChecked, in: markdown)
                : MarkdownCodec.markdownBySettingActionItem(
                    current, checked: !current.isChecked, in: markdown)
        }
    }

    private func change(
        _ entry: OpenAction,
        store: MarkdownStore,
        rewriting: (MeetingNote, ActionItemLine, String) -> String?
    ) async {
        do {
            let note = try target(for: entry, store: store)
            let snapshot = try store.markdownSnapshot(for: note)
            guard snapshot.revision == entry.sourceRevision,
                  let current = Self.actionItemLines(for: note, in: snapshot.markdown)
                    .first(where: { $0.index == entry.itemIndex }),
                  current.text.utf8.elementsEqual(entry.text.utf8),
                  let rewritten = rewriting(note, current, snapshot.markdown) else {
                throw OpenActionMutationError.changed
            }
            // Recheck ownership at the mutation boundary. The store then
            // checks these exact source bytes again before replacing the file.
            let currentTarget = try target(for: entry, store: store)
            try store.saveRawMarkdown(
                rewritten, for: currentTarget, expectedRevision: snapshot.revision
            )
            lastError = nil
            // The library observes store.notes and refreshes once after this
            // save, instead of reading every action twice for one click.
        } catch {
            lastError = error.localizedDescription
            cache.removeValue(forKey: entry.noteID)
            await refresh(store: store)
        }
    }

    private func target(for entry: OpenAction, store: MarkdownStore) throws -> MeetingNote {
        let candidates = store.notes.filter { $0.id == entry.noteID }
        guard candidates.count <= 1 else { throw OpenActionMutationError.ambiguousIdentity }
        guard let note = candidates.first else { throw OpenActionMutationError.missing }
        guard let sourceURL = entry.sourceFileURL,
              let sourceRevision = entry.sourceRevision,
              let currentURL = note.fileURL?.standardizedFileURL.resolvingSymlinksInPath(),
              currentURL == sourceURL,
              currentURL.deletingLastPathComponent()
                == store.storageURL.standardizedFileURL.resolvingSymlinksInPath(),
              note.fileRevision == sourceRevision else {
            throw OpenActionMutationError.changed
        }
        return note
    }

    private static func duplicateIDs(in notes: [MeetingNote]) -> Set<UUID> {
        Set(Dictionary(grouping: notes, by: \.id).filter { $0.value.count > 1 }.keys)
    }

    /// Keep the original persisted key format: moving a line or changing
    /// only its due date must not forget an earlier successful export.
    private static func exportKey(for entry: OpenAction) -> String {
        "\(entry.noteID.uuidString)|\(entry.displayText)"
    }

    /// Reminders access is requested only for an explicit export. Capture
    /// the generation at the UI action when scheduling this asynchronous call.
    func sendToReminders(
        _ entry: OpenAction,
        store: MarkdownStore,
        expectedGeneration: Int? = nil
    ) async {
        await sendToReminders(entry, expectedGeneration: expectedGeneration) {
            ReminderExportLibrarySnapshot(
                directoryURL: store.storageURL,
                generation: store.storageGeneration,
                isLoading: store.isLoading,
                notes: store.notes
            )
        }
    }

    /// The snapshot reader is shared by production and synthetic-file tests.
    /// It is read again after permission, rather than retaining old models as
    /// authority to export from a library the user has since left or edited.
    func sendToReminders(
        _ entry: OpenAction,
        expectedGeneration: Int? = nil,
        library: @escaping @MainActor () -> ReminderExportLibrarySnapshot
    ) async {
        let requestID = UUID()
        let key = Self.exportKey(for: entry)
        let reservation: ReminderExportReservation
        switch reminderExports.reserve(key) {
        case .alreadyExported:
            exportedIDs.insert(entry.id)
            showReminderError("Already in Reminders.", for: key)
            return
        case .alreadyRunning:
            showReminderError("This action is already being sent to Reminders.", for: key)
            return
        case .acquired(let acquired):
            reservation = acquired
        }
        reminderRequests[key] = requestID
        defer {
            reminderExports.release(key, reservation: reservation)
            if reminderRequests[key] == requestID { reminderRequests.removeValue(forKey: key) }
        }

        await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                let captured = library()
                guard expectedGeneration == nil || captured.generation == expectedGeneration else {
                    throw ReminderExportError.libraryChanged
                }
                _ = try reminderPayload(for: entry, library: captured)
                let client = makeReminderClient()
                let granted = try await client.requestAccess()
                try Task.checkCancellation()
                guard granted else {
                    if reminderRequests[key] == requestID {
                        showReminderError("Reminders access was declined, so the item stayed in Nook.", for: key)
                    }
                    return
                }
                // Another successful export may have been persisted while
                // the system permission sheet was open. Never trust a cache.
                guard !reminderExports.exportedKeys.contains(key) else {
                    exportedIDs.insert(entry.id)
                    if reminderRequests[key] == requestID { showReminderError("Already in Reminders.", for: key) }
                    return
                }
                let current = library()
                guard current.generation == captured.generation,
                      current.directoryURL.standardizedFileURL
                        == captured.directoryURL.standardizedFileURL else {
                    throw ReminderExportError.libraryChanged
                }
                let payload = try reminderPayload(for: entry, library: current)
                try Task.checkCancellation()
                // Save is synchronous on the main actor. There is no yield
                // between source validation, commit and merging its receipt.
                try client.save(payload)
                reminderExports.recordSuccess(key)
                exportedIDs.insert(entry.id)
                if reminderRequests[key] == requestID,
                   reminderError?.key == key, reminderError?.message == lastError {
                    lastError = nil
                    reminderError = nil
                }
            } catch is CancellationError {
                if reminderRequests[key] == requestID {
                    showReminderError("Sending to Reminders was cancelled. The item stayed in Nook.", for: key)
                }
            } catch let error as ReminderExportError {
                if reminderRequests[key] == requestID { showReminderError(error.localizedDescription, for: key) }
            } catch let error as OpenActionMutationError {
                if reminderRequests[key] == requestID { showReminderError(error.localizedDescription, for: key) }
            } catch {
                if reminderRequests[key] == requestID { showReminderError("Nook couldn't add that to Reminders.", for: key) }
            }
        } onCancel: {
            reservation.cancel()
        }
    }

    private func showReminderError(_ message: String, for key: String) {
        lastError = message
        reminderError = (key, message)
    }

    private func reminderPayload(
        for entry: OpenAction,
        library: ReminderExportLibrarySnapshot
    ) throws -> ReminderExportPayload {
        guard !library.isLoading else { throw ReminderExportError.libraryLoading }
        let candidates = library.notes.filter { $0.id == entry.noteID }
        guard candidates.count <= 1 else { throw OpenActionMutationError.ambiguousIdentity }
        guard let note = candidates.first,
              let sourceURL = entry.sourceFileURL,
              let revision = entry.sourceRevision,
              note.fileURL?.standardizedFileURL.resolvingSymlinksInPath() == sourceURL,
              sourceURL.deletingLastPathComponent()
                == library.directoryURL.standardizedFileURL.resolvingSymlinksInPath(),
              note.fileRevision == revision,
              let bytes = try? Data(contentsOf: sourceURL),
              MeetingNote.contentRevision(bytes) == revision,
              let markdown = String(data: bytes, encoding: .utf8),
              let current = Self.actionItemLines(for: note, in: markdown)
                .first(where: { $0.index == entry.itemIndex }),
              !current.isChecked,
              current.text.utf8.elementsEqual(entry.text.utf8),
              current.dueDate == entry.dueDate else {
            throw ReminderExportError.sourceChanged
        }
        let components: DateComponents?
        if let dueDate = current.dueDate {
            // A due date, not a start date: the item is due that morning.
            var due = reminderCalendar.dateComponents([.year, .month, .day], from: dueDate)
            due.hour = 9
            due.calendar = reminderCalendar
            components = due
        } else {
            components = nil
        }
        return ReminderExportPayload(title: current.displayText, dueDateComponents: components)
    }

}

private enum OpenActionMutationError: LocalizedError {
    case ambiguousIdentity
    case changed
    case missing

    var errorDescription: String? {
        switch self {
        case .ambiguousIdentity:
            "Some notes share an ID. Their action items are hidden to protect your writing. Review the copies in your library."
        case .changed:
            "That action changed or moved. Refresh the library and review it before editing."
        case .missing:
            "That action could not be found anymore."
        }
    }
}
