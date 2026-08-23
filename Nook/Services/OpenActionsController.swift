import EventKit
import Foundation

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

    var id: String { "\(noteID.uuidString)#\(itemIndex)" }

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
    let fileModified: Date?
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
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastError: String?
    /// Set briefly when an export succeeds, for the row's confirmation.
    @Published private(set) var exportedIDs: Set<String> = []

    private var refreshGeneration = 0
    /// Keyed by note id. `store.notes` publishes on every save across the
    /// whole app, and every publish used to re-read and re-parse every
    /// action-bearing note's file from disk regardless of whether that note
    /// had changed; this reuses the previous read whenever a note's file URL
    /// and on-disk modification date both still match.
    private var cache: [UUID: CachedNoteActions] = [:]

    /// Reminder export keys already sent, persisted so a relaunch does not
    /// offer to export the same action again. See `sendToReminders`.
    private var exportedReminderKeys: Set<String>

    init() {
        exportedReminderKeys = Self.loadExportedReminderKeys()
    }

    /// Re-reads action state from disk. Notes are unchanged between saves,
    /// but files can also be edited outside Nook, so this never assumes.
    func refresh(store: MarkdownStore) async {
        refreshGeneration += 1
        let generation = refreshGeneration
        isRefreshing = true

        // Spoken notes keep their checkboxes inline in the body, so their
        // decoded model never lists items; they stay eligible on kind.
        let notes = store.notes
            .filter { !$0.actionItems.isEmpty || $0.kind == .spoken }
            .sorted(by: { $0.startedAt > $1.startedAt })

        var reused: [UUID: CachedNoteActions] = [:]
        var toRead: [MeetingNote] = []
        for note in notes {
            guard let url = note.fileURL else { continue }
            if let cached = cache[note.id],
               cached.url == url,
               cached.fileModified == note.fileModified {
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
                      let markdown = try? String(
                          contentsOf: url,
                          encoding: .utf8
                      )
                else { return nil }
                let actions = Self.actionItemLines(for: note, in: markdown)
                    .filter { !$0.isChecked }
                    .map { item in
                        OpenAction(
                            noteID: note.id,
                            itemIndex: item.index,
                            text: item.text,
                            dueDate: item.dueDate,
                            noteTitle: note.title,
                            startedAt: note.startedAt
                        )
                    }
                return (
                    note.id,
                    CachedNoteActions(
                        url: url,
                        fileModified: note.fileModified,
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
        cache = reused

        let combined = notes.flatMap { reused[$0.id]?.actions ?? [] }
        entries = Self.sortedByDueUrgency(combined)
        for entry in entries
        where exportedReminderKeys.contains(Self.exportKey(for: entry)) {
            exportedIDs.insert(entry.id)
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
        guard let note = store.notes.first(where: { $0.id == entry.noteID }),
              let url = note.fileURL,
              let markdown = try? String(contentsOf: url, encoding: .utf8),
              let current = Self.actionItemLines(for: note, in: markdown)
                  .first(where: { $0.index == entry.itemIndex })
        else {
            lastError = "That action could not be found anymore."
            await refresh(store: store)
            return
        }

        let rewritten = note.kind == .spoken
            ? MarkdownCodec.markdownBySettingSpokenCheckboxDue(
                current, dueTo: date, in: markdown)
            : MarkdownCodec.markdownBySettingActionItemDue(
                current, dueTo: date, in: markdown)
        guard let rewritten else {
            lastError = "That action changed on disk. Refreshing."
            await refresh(store: store)
            return
        }

        do {
            try store.saveRawMarkdown(rewritten, for: note)
            lastError = nil
            // `saveRawMarkdown` updates `store.notes`, which the library
            // view observes to call `refresh` itself; refreshing again here
            // would re-read this note's file a second time for nothing.
        } catch {
            lastError = error.localizedDescription
            await refresh(store: store)
        }
    }

    /// Checks an item off, or reopens it, by editing one line of its file.
    func toggle(_ entry: OpenAction, store: MarkdownStore) async {
        guard let note = store.notes.first(where: { $0.id == entry.noteID }),
              let url = note.fileURL,
              let markdown = try? String(contentsOf: url, encoding: .utf8),
              let current = Self.actionItemLines(for: note, in: markdown)
                  .first(where: { $0.index == entry.itemIndex })
        else {
            lastError = "That action could not be found anymore."
            await refresh(store: store)
            return
        }

        let rewritten: String?
        if note.kind == .spoken {
            rewritten = MarkdownCodec.markdownBySettingSpokenCheckbox(
                current,
                checked: !current.isChecked,
                in: markdown
            )
        } else {
            rewritten = MarkdownCodec.markdownBySettingActionItem(
                current,
                checked: !current.isChecked,
                in: markdown
            )
        }
        guard let rewritten else {
            lastError = "That action changed on disk. Refreshing."
            await refresh(store: store)
            return
        }

        do {
            try store.saveRawMarkdown(rewritten, for: note)
            lastError = nil
            // See the matching comment in `setDue`: `store.notes` publishing
            // already triggers the library view's own refresh.
        } catch {
            lastError = error.localizedDescription
            await refresh(store: store)
        }
    }

    /// UserDefaults key for the persisted set of exported reminder keys. See
    /// `exportKey(for:)` for what a key contains.
    private static let exportedReminderKeysDefaultsKey =
        "OpenActionsController.exportedReminderKeys"

    /// Identifies an action for reminder-export dedupe by note id and the
    /// item's display text, not its file index: the index shifts whenever
    /// another item is added above it in the file, which would otherwise
    /// silently forget that this one was already exported.
    private static func exportKey(for entry: OpenAction) -> String {
        "\(entry.noteID.uuidString)|\(entry.displayText)"
    }

    private static func loadExportedReminderKeys() -> Set<String> {
        Set(
            UserDefaults.standard.stringArray(
                forKey: exportedReminderKeysDefaultsKey
            ) ?? []
        )
    }

    /// Exports one item into the user's Reminders, unless it was exported
    /// before: without this, reopening Nook offered the export again on
    /// every relaunch, since `exportedIDs` only tracked the current session.
    ///
    /// Reminders access is requested here rather than at launch, so nobody
    /// grants it without using the feature.
    func sendToReminders(_ entry: OpenAction) async {
        let key = Self.exportKey(for: entry)
        guard !exportedReminderKeys.contains(key) else {
            exportedIDs.insert(entry.id)
            lastError = "Already in Reminders."
            return
        }

        let eventStore = EKEventStore()
        // The write-only scope is not offered on macOS; full access is still
        // requested here rather than at launch, so nobody grants it without
        // using the feature.
        let granted = (try? await eventStore.requestFullAccessToReminders())
            ?? false
        guard granted else {
            lastError =
                "Reminders access was declined, so the item stayed in Nook."
            return
        }

        let calendar = eventStore.defaultCalendarForNewReminders()
            ?? eventStore.calendars(for: .reminder).first
        guard let calendar else {
            lastError = "No Reminders list was available."
            return
        }

        let reminder = EKReminder(eventStore: eventStore)
        reminder.title = entry.displayText
        reminder.calendar = calendar
        if let dueDate = entry.dueDate {
            // A due date, not a start date: the item is due that morning.
            var components = Calendar.current.dateComponents(
                [.year, .month, .day],
                from: dueDate
            )
            components.hour = 9
            components.calendar = Calendar.current
            reminder.dueDateComponents = components
        }
        do {
            try eventStore.save(reminder, commit: true)
            exportedReminderKeys.insert(key)
            UserDefaults.standard.set(
                Array(exportedReminderKeys),
                forKey: Self.exportedReminderKeysDefaultsKey
            )
            exportedIDs.insert(entry.id)
            lastError = nil
        } catch {
            lastError = "Nook couldn't add that to Reminders."
        }
    }
}
