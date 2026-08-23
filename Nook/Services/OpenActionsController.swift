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

    /// Re-reads action state from disk. Notes are unchanged between saves,
    /// but files can also be edited outside Nook, so this never assumes.
    func refresh(store: MarkdownStore) async {
        refreshGeneration += 1
        let generation = refreshGeneration
        isRefreshing = true

        let notes = store.notes.filter { !$0.actionItems.isEmpty }
        let collected: [OpenAction] = await Task.detached(
            priority: .userInitiated
        ) {
            var result: [OpenAction] = []
            for note in notes.sorted(by: { $0.startedAt > $1.startedAt }) {
                guard let url = note.fileURL,
                      let markdown = try? String(
                          contentsOf: url,
                          encoding: .utf8
                      )
                else { continue }
                let lines = MarkdownCodec.actionItemLines(in: markdown)
                for item in lines where !item.isChecked {
                    result.append(
                        OpenAction(
                            noteID: note.id,
                            itemIndex: item.index,
                            text: item.text,
                            dueDate: item.dueDate,
                            noteTitle: note.title,
                            startedAt: note.startedAt
                        )
                    )
                }
            }
            return Self.sortedByDueUrgency(result)
        }.value

        guard generation == refreshGeneration else { return }
        entries = collected
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

    /// Sets or clears an item's due date by editing one line of its file.
    func setDue(
        _ entry: OpenAction,
        on date: Date?,
        store: MarkdownStore
    ) async {
        guard let note = store.notes.first(where: { $0.id == entry.noteID }),
              let url = note.fileURL,
              let markdown = try? String(contentsOf: url, encoding: .utf8),
              let current = MarkdownCodec.actionItemLines(in: markdown)
                  .first(where: { $0.index == entry.itemIndex })
        else {
            lastError = "That action could not be found anymore."
            await refresh(store: store)
            return
        }

        let rewritten = MarkdownCodec.markdownBySettingActionItemDue(
            current,
            dueTo: date,
            in: markdown
        )
        guard let rewritten else {
            lastError = "That action changed on disk. Refreshing."
            await refresh(store: store)
            return
        }

        do {
            try store.saveRawMarkdown(rewritten, for: note)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        await refresh(store: store)
    }

    /// Checks an item off, or reopens it, by editing one line of its file.
    func toggle(_ entry: OpenAction, store: MarkdownStore) async {
        guard let note = store.notes.first(where: { $0.id == entry.noteID }),
              let url = note.fileURL,
              let markdown = try? String(contentsOf: url, encoding: .utf8),
              let current = MarkdownCodec.actionItemLines(in: markdown)
                  .first(where: { $0.index == entry.itemIndex })
        else {
            lastError = "That action could not be found anymore."
            await refresh(store: store)
            return
        }

        let rewritten = MarkdownCodec.markdownBySettingActionItem(
            current,
            checked: !current.isChecked,
            in: markdown
        )
        guard let rewritten else {
            lastError = "That action changed on disk. Refreshing."
            await refresh(store: store)
            return
        }

        do {
            try store.saveRawMarkdown(rewritten, for: note)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        await refresh(store: store)
    }

    /// Exports one item into the user's Reminders.
    ///
    /// Reminders access is requested here rather than at launch, so nobody
    /// grants it without using the feature.
    func sendToReminders(_ entry: OpenAction) async {
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
            exportedIDs.insert(entry.id)
            lastError = nil
        } catch {
            lastError = "Nook couldn't add that to Reminders."
        }
    }
}
