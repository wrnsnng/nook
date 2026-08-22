import EventKit
import Foundation

/// One unchecked action item across the whole library, addressed back to its
/// line in its note's file.
struct OpenAction: Identifiable, Hashable {
    let noteID: UUID
    let itemIndex: Int
    let text: String
    let noteTitle: String
    let startedAt: Date

    var id: String { "\(noteID.uuidString)#\(itemIndex)" }
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
                            noteTitle: note.title,
                            startedAt: note.startedAt
                        )
                    )
                }
            }
            return result
        }.value

        guard generation == refreshGeneration else { return }
        entries = collected
        isRefreshing = false
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
        reminder.title = entry.text
        reminder.calendar = calendar
        do {
            try eventStore.save(reminder, commit: true)
            exportedIDs.insert(entry.id)
            lastError = nil
        } catch {
            lastError = "Nook couldn't add that to Reminders."
        }
    }
}
