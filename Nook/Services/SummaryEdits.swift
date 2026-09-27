import Foundation
import Observation

/// The five sections a summary run writes, read out of a note as one value.
///
/// These are the fields regeneration replaces and the fields the Notes tab
/// lets a person rewrite in place. Comparisons are by exact bytes, never by
/// Swift's canonical String equality: a Unicode-only edit is still an edit,
/// and treating it as unchanged would let a stale draft overwrite it.
struct GeneratedSections: Sendable {
    var summary: String
    var keyPoints: [String]
    var decisions: [String]
    var actionItems: [String]
    var openQuestions: [String]
    var completedActionItems: Set<String>

    init(
        summary: String = "",
        keyPoints: [String] = [],
        decisions: [String] = [],
        actionItems: [String] = [],
        openQuestions: [String] = [],
        completedActionItems: Set<String> = []
    ) {
        self.summary = summary
        self.keyPoints = keyPoints
        self.decisions = decisions
        self.actionItems = actionItems
        self.openQuestions = openQuestions
        self.completedActionItems = completedActionItems
    }

    init(_ note: MeetingNote) {
        self.init(
            summary: note.summary,
            keyPoints: note.keyPoints,
            decisions: note.decisions,
            actionItems: note.actionItems,
            openQuestions: note.openQuestions,
            completedActionItems: note.completedActionItems
        )
    }

    /// One editable part of the set. Action items and their ticks travel as
    /// one field because completion is keyed by the item's text: editing the
    /// words has to move the tick in the same write.
    enum Field: CaseIterable, Sendable {
        case summary, keyPoints, decisions, actions, openQuestions
    }

    func matches(_ other: GeneratedSections, in field: Field) -> Bool {
        switch field {
        case .summary: summary.utf8.elementsEqual(other.summary.utf8)
        case .keyPoints: Self.exact(keyPoints, other.keyPoints)
        case .decisions: Self.exact(decisions, other.decisions)
        case .openQuestions: Self.exact(openQuestions, other.openQuestions)
        case .actions:
            Self.exact(actionItems, other.actionItems)
                && Self.exact(completedActionItems.sorted(), other.completedActionItems.sorted())
        }
    }

    func matches(_ other: GeneratedSections) -> Bool {
        Field.allCases.allSatisfy { matches(other, in: $0) }
    }

    mutating func take(_ field: Field, from other: GeneratedSections) {
        switch field {
        case .summary: summary = other.summary
        case .keyPoints: keyPoints = other.keyPoints
        case .decisions: decisions = other.decisions
        case .openQuestions: openQuestions = other.openQuestions
        case .actions:
            actionItems = other.actionItems
            completedActionItems = other.completedActionItems
        }
    }

    func applied(to note: MeetingNote) -> MeetingNote {
        var updated = note
        updated.summary = summary
        updated.keyPoints = keyPoints
        updated.decisions = decisions
        updated.actionItems = actionItems
        updated.openQuestions = openQuestions
        // A tick can only belong to an item that still exists; otherwise it
        // would wait to ambush a future item worded the same way.
        updated.completedActionItems = completedActionItems.filter { actionItems.contains($0) }
        return updated
    }

    private static func exact(_ left: [String], _ right: [String]) -> Bool {
        left.count == right.count && zip(left, right).allSatisfy { $0.utf8.elementsEqual($1.utf8) }
    }
}

/// Whether Regenerate has to ask first.
///
/// Regeneration replaces every generated section. Once the person has written
/// in them, doing that without a question would throw their words away.
enum SummaryRegenerationGuard {
    static func needsConfirmation(note: MeetingNote, hasUnsavedEdits: Bool) -> Bool {
        note.summaryEditedByUser || hasUnsavedEdits
    }
}

/// One line of an editable list: a key point, decision, open question or
/// action item.
///
/// The identifier is presentation identity only, so SwiftUI keeps focus on
/// the right field while rows are inserted and removed around it. It is never
/// written to the file.
struct SummaryListRow: Identifiable, Hashable, Sendable {
    let id: UUID
    /// The words the person edits. For an action item this excludes the
    /// `[due: ...]` suffix, which is Nook's bookkeeping and is carried in
    /// `dueSuffix` so an edit can never silently reschedule a task.
    var text: String
    var isCompleted: Bool
    var dueSuffix: String

    init(id: UUID = UUID(), text: String, isCompleted: Bool = false, dueSuffix: String = "") {
        self.id = id
        self.text = text
        self.isCompleted = isCompleted
        self.dueSuffix = dueSuffix
    }

    /// The item as the file stores it.
    var storedText: String {
        let words = Self.singleLine(text)
        guard !words.isEmpty else { return "" }
        return words + dueSuffix
    }

    /// A list item is one Markdown line, so pasted line breaks become spaces
    /// rather than a second line the codec would read as something else.
    static func singleLine(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func rows(from items: [String]) -> [SummaryListRow] {
        items.map { SummaryListRow(text: $0) }
    }

    static func actionRows(from items: [String], completed: Set<String>) -> [SummaryListRow] {
        items.map { item in
            let words = ActionItemLine.strippingDueSuffix(from: item)
            let suffix = item.range(
                of: #"\s*\[due:\s*\d{4}-\d{2}-\d{2}\]\s*$"#,
                options: .regularExpression
            ).map { String(item[$0]) } ?? ""
            // Only a suffix that sits at the very end can be put back after
            // an edit. An item with the date elsewhere keeps all its words.
            return suffix.isEmpty
                ? SummaryListRow(text: item, isCompleted: completed.contains(item))
                : SummaryListRow(text: words, isCompleted: completed.contains(item), dueSuffix: suffix)
        }
    }

    /// The stored list, without the rows that hold nothing a reader would
    /// recognise. The decoder drops those too, so keeping them here would only
    /// make a save that cannot be read back.
    static func items(from rows: [SummaryListRow]) -> [String] {
        NoteContentSanitizer.meaningfulItems(rows.map(\.storedText))
    }

    static func completed(in rows: [SummaryListRow]) -> Set<String> {
        let kept = Set(items(from: rows))
        return Set(rows.filter(\.isCompleted).map(\.storedText)).intersection(kept)
    }
}

/// One paragraph of the gist as the Notes tab shows it.
///
/// The gist is displayed a sentence (or a balanced paragraph) per row, and it
/// is edited the same way, so the page looks the same whether or not a field
/// has the keyboard. Each row remembers the exact text that separated it from
/// the row before, which is what lets an edit to one sentence write back the
/// rest of the prose byte for byte.
struct SummaryProseRow: Identifiable, Hashable, Sendable {
    let id: UUID
    var text: String
    /// What sat between the previous row and this one in the stored summary.
    /// New rows made with Return start a new paragraph.
    var separator: String

    init(id: UUID = UUID(), text: String, separator: String = "\n\n") {
        self.id = id
        self.text = text
        self.separator = separator
    }

    /// Rows for the pieces the detail view displays, located in order in the
    /// stored text so the separators are the file's own.
    static func rows(displaying pieces: [String], of summary: String) -> [SummaryProseRow] {
        var rows: [SummaryProseRow] = []
        var cursor = summary.startIndex
        for piece in pieces {
            let text = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if let found = summary.range(of: text, options: .literal, range: cursor..<summary.endIndex) {
                let gap = String(summary[cursor..<found.lowerBound])
                let separator = rows.isEmpty ? "" : (gap.isEmpty ? " " : gap)
                rows.append(SummaryProseRow(text: text, separator: separator))
                cursor = found.upperBound
            } else {
                rows.append(SummaryProseRow(text: text, separator: rows.isEmpty ? "" : "\n\n"))
            }
        }
        if rows.isEmpty {
            rows.append(SummaryProseRow(text: "", separator: ""))
        }
        return rows
    }

    static func summary(from rows: [SummaryProseRow]) -> String {
        var result = ""
        for row in rows {
            let text = row.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if !result.isEmpty {
                result += row.separator.isEmpty ? " " : row.separator
            }
            result += text
        }
        return result
    }
}

/// Keyboard editing of a list of rows, as a pure function of the rows.
///
/// Kept apart from the view and the controller so the behaviour a person
/// relies on, Return adds a row and Delete on an empty one removes it, is
/// tested without driving AppKit.
enum SummaryRowEditing {
    /// Where the keyboard should go after an edit.
    struct Focus: Equatable {
        let rowID: UUID
        /// Caret position in UTF-16 units, as AppKit counts them.
        let caret: Int
    }

    /// Return: the text after the caret moves into a new row below. Ticks and
    /// due dates stay with the item they belonged to.
    static func split(_ rows: inout [SummaryListRow], at id: UUID, caret: Int) -> Focus? {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return nil }
        let (head, tail) = divide(rows[index].text, at: caret)
        rows[index].text = head
        let row = SummaryListRow(text: tail)
        rows.insert(row, at: index + 1)
        return Focus(rowID: row.id, caret: 0)
    }

    static func split(_ rows: inout [SummaryProseRow], at id: UUID, caret: Int) -> Focus? {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return nil }
        let (head, tail) = divide(rows[index].text, at: caret)
        rows[index].text = head
        let row = SummaryProseRow(text: tail, separator: "\n\n")
        rows.insert(row, at: index + 1)
        return Focus(rowID: row.id, caret: 0)
    }

    /// Delete at the start of a row: an empty row goes away, a row with words
    /// joins the one above, the way a paragraph does in any Mac text editor.
    /// Returns nil when there is nothing above to join, which leaves the
    /// keystroke to do nothing, as it would at the start of a document.
    static func deleteBackward(_ rows: inout [SummaryListRow], at id: UUID) -> Focus? {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return nil }
        let row = rows[index]
        if row.text.isEmpty {
            rows.remove(at: index)
            if index > 0 {
                let previous = rows[index - 1]
                return Focus(rowID: previous.id, caret: previous.text.utf16.count)
            }
            return rows.first.map { Focus(rowID: $0.id, caret: 0) }
        }
        guard index > 0 else { return nil }
        let previous = rows[index - 1]
        let joint = previous.text.utf16.count
        let needsSpace = !previous.text.isEmpty && !(previous.text.last?.isWhitespace ?? true)
            && !(row.text.first?.isWhitespace ?? true)
        rows[index - 1].text = previous.text + (needsSpace ? " " : "") + row.text
        if previous.dueSuffix.isEmpty { rows[index - 1].dueSuffix = row.dueSuffix }
        rows.remove(at: index)
        return Focus(rowID: previous.id, caret: joint + (needsSpace ? 1 : 0))
    }

    static func deleteBackward(_ rows: inout [SummaryProseRow], at id: UUID) -> Focus? {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return nil }
        let row = rows[index]
        if row.text.isEmpty {
            // The gist always keeps one row to type into.
            guard rows.count > 1 else { return nil }
            rows.remove(at: index)
            if index > 0 {
                let previous = rows[index - 1]
                return Focus(rowID: previous.id, caret: previous.text.utf16.count)
            }
            // The first row's separator is never written; the new first
            // row's would otherwise lead the summary.
            rows[0].separator = ""
            return Focus(rowID: rows[0].id, caret: 0)
        }
        guard index > 0 else { return nil }
        let previous = rows[index - 1]
        let joint = previous.text.utf16.count
        let needsSpace = !previous.text.isEmpty && !(previous.text.last?.isWhitespace ?? true)
        rows[index - 1].text = previous.text + (needsSpace ? " " : "") + row.text
        rows.remove(at: index)
        return Focus(rowID: previous.id, caret: joint + (needsSpace ? 1 : 0))
    }

    private static func divide(_ text: String, at caret: Int) -> (String, String) {
        let utf16 = text.utf16
        let offset = min(max(0, caret), utf16.count)
        guard let index = utf16.index(utf16.startIndex, offsetBy: offset, limitedBy: utf16.endIndex),
              let split = index.samePosition(in: text) else {
            return (text, "")
        }
        return (
            String(text[..<split]).trimmingCharacters(in: .whitespaces),
            String(text[split...]).trimmingCharacters(in: .whitespaces)
        )
    }
}

/// The Notes tab's in-place edits to the generated sections, held outside the
/// view that draws them.
///
/// Owned by the store for the same reason the My notes draft is not view
/// state: the detail view is rebuilt whenever the selection changes, and a
/// meeting starting on its own changes the selection. Words live here until a
/// save has written them, and a save that is refused keeps them parked against
/// their own note instead of following the field to whatever is on screen.
@MainActor
@Observable
final class SummaryEditsController {
    struct Draft: Equatable {
        var summary: [SummaryProseRow] = []
        var keyPoints: [SummaryListRow] = []
        var decisions: [SummaryListRow] = []
        var actions: [SummaryListRow] = []
        var openQuestions: [SummaryListRow] = []

        /// The rows written back as the note's fields.
        var sections: GeneratedSections {
            GeneratedSections(
                summary: SummaryProseRow.summary(from: summary),
                keyPoints: SummaryListRow.items(from: keyPoints),
                decisions: SummaryListRow.items(from: decisions),
                actionItems: SummaryListRow.items(from: actions),
                openQuestions: SummaryListRow.items(from: openQuestions),
                completedActionItems: SummaryListRow.completed(in: actions)
            )
        }
    }

    private struct Parked {
        let draft: Draft
        let baseline: GeneratedSections
        let pristine: GeneratedSections
        var reason: String
    }

    /// How long typing pauses before the edit is written.
    static let saveDelay: Duration = .seconds(1.2)

    private(set) var owner: LibraryNoteIdentity?
    var draft = Draft()
    /// What the file held when these rows were loaded or last saved. The only
    /// thing that authorizes writing a section the person changed.
    private(set) var baseline = GeneratedSections()
    /// What the rows read as before anyone typed in them.
    ///
    /// Not the same as `baseline`. Splitting prose into rows and joining it
    /// back is exact for anything Nook wrote, but a hand-edited file can
    /// carry stray whitespace or a placeholder bullet the rows do not keep.
    /// Measuring edits against the file would call that difference an edit,
    /// and the debounce would then rewrite a note, and mark it as edited by
    /// the person, when nobody had typed a thing.
    private(set) var pristine = GeneratedSections()
    /// Why the last save did not happen, shown beside the sections.
    var statusMessage: String?
    private var parked: [LibraryNoteIdentity: Parked] = [:]
    @ObservationIgnored private var pendingSave: Task<Void, Never>?

    /// The sections someone has typed into since they were loaded or saved.
    var changedFields: [GeneratedSections.Field] {
        let current = draft.sections
        return GeneratedSections.Field.allCases.filter { !current.matches(pristine, in: $0) }
    }

    /// Whether anything typed into these sections has not reached the file.
    var hasChanges: Bool {
        owner != nil && !changedFields.isEmpty
    }

    /// Whether any note, on screen or not, has edits still waiting.
    var hasUnwrittenEdits: Bool { hasChanges || !parked.isEmpty }

    func hasChanges(for note: MeetingNote) -> Bool {
        owner == note.libraryIdentity && hasChanges
    }

    /// The fields as they should be written: the person's rows where they
    /// typed, and the file's own bytes everywhere else.
    var proposal: GeneratedSections {
        var proposed = baseline
        let current = draft.sections
        for field in changedFields { proposed.take(field, from: current) }
        return proposed
    }

    /// Points the rows at a note, writing any edit that belongs to another.
    func prepare(for note: MeetingNote, store: MarkdownStore) {
        guard owner != note.libraryIdentity else {
            refresh(for: note)
            return
        }
        pendingSave?.cancel()
        if hasChanges, let reason = saveLiveDraft(store: store), let owner {
            parked[owner] = Parked(draft: draft, baseline: baseline, pristine: pristine, reason: reason)
        }
        retryParked(store: store)
        if let waiting = parked.removeValue(forKey: note.libraryIdentity) {
            // Back on the note whose words are still unwritten: they belong
            // in the fields they were typed in, not the file's older copy.
            owner = note.libraryIdentity
            draft = waiting.draft
            baseline = waiting.baseline
            pristine = waiting.pristine
            statusMessage = waiting.reason
            return
        }
        load(note)
    }

    /// Adopts newer file contents for every section the person has not
    /// changed. A section with unsaved words keeps them; its save then
    /// compares against the baseline and refuses rather than overwrite.
    func refresh(for note: MeetingNote) {
        guard owner == note.libraryIdentity else { return }
        let incoming = GeneratedSections(note)
        let changed = Set(changedFields)
        for field in GeneratedSections.Field.allCases
        where !changed.contains(field) && !incoming.matches(baseline, in: field) {
            reloadRows(field, from: note)
            baseline.take(field, from: incoming)
            pristine.take(field, from: draft.sections)
        }
    }

    /// Row identity is kept by position, so a field that has the keyboard
    /// keeps it while, say, a tick made in the sidebar is picked up.
    private func reloadRows(_ field: GeneratedSections.Field, from note: MeetingNote) {
        switch field {
        case .summary:
            draft.summary = Self.reusingIDs(Self.summaryRows(for: note), from: draft.summary)
        case .keyPoints:
            draft.keyPoints = Self.reusingIDs(SummaryListRow.rows(from: note.keyPoints), from: draft.keyPoints)
        case .decisions:
            draft.decisions = Self.reusingIDs(SummaryListRow.rows(from: note.decisions), from: draft.decisions)
        case .openQuestions:
            draft.openQuestions = Self.reusingIDs(
                SummaryListRow.rows(from: note.openQuestions), from: draft.openQuestions
            )
        case .actions:
            draft.actions = Self.reusingIDs(
                SummaryListRow.actionRows(from: note.actionItems, completed: note.completedActionItems),
                from: draft.actions
            )
        }
    }

    private func load(_ note: MeetingNote) {
        owner = note.libraryIdentity
        baseline = GeneratedSections(note)
        draft = Draft(
            summary: Self.summaryRows(for: note),
            keyPoints: SummaryListRow.rows(from: note.keyPoints),
            decisions: SummaryListRow.rows(from: note.decisions),
            actions: SummaryListRow.actionRows(from: note.actionItems, completed: note.completedActionItems),
            openQuestions: SummaryListRow.rows(from: note.openQuestions)
        )
        pristine = draft.sections
        statusMessage = nil
    }

    /// The gist split the way the detail view shows it: a sentence per row
    /// for a meeting, balanced paragraphs otherwise.
    static func summaryRows(for note: MeetingNote) -> [SummaryProseRow] {
        let sentences = SummaryReviewItem.sentences(in: note.summary)
        if note.kind == .meeting, !sentences.isEmpty {
            return SummaryProseRow.rows(displaying: sentences.map(\.text), of: note.summary)
        }
        return SummaryProseRow.rows(
            displaying: DetailSummaryParagraphPolicy.paragraphs(for: note.summary),
            of: note.summary
        )
    }

    private static func reusingIDs(_ fresh: [SummaryListRow], from old: [SummaryListRow]) -> [SummaryListRow] {
        fresh.enumerated().map { index, row in
            guard old.indices.contains(index) else { return row }
            return SummaryListRow(id: old[index].id, text: row.text, isCompleted: row.isCompleted, dueSuffix: row.dueSuffix)
        }
    }

    private static func reusingIDs(_ fresh: [SummaryProseRow], from old: [SummaryProseRow]) -> [SummaryProseRow] {
        fresh.enumerated().map { index, row in
            guard old.indices.contains(index) else { return row }
            return SummaryProseRow(id: old[index].id, text: row.text, separator: row.separator)
        }
    }

    /// Writes the edited sections through the store's conflict checks.
    @discardableResult
    func save(note: MeetingNote, store: MarkdownStore) throws -> MeetingNote {
        pendingSave?.cancel()
        guard owner == note.libraryIdentity else { throw EditorDraftOwnershipError.wrongOwner }
        guard hasChanges else { return note }
        let changed = Set(changedFields)
        let saved = try store.updateGeneratedSections(proposal, expected: baseline, for: note)
        let incoming = GeneratedSections(saved)
        // The rows the person typed in keep their shape; a sentence split
        // across two rows must not be re-flowed under the caret. Sections the
        // merge took from a newer file are reloaded so they are not stale.
        for field in GeneratedSections.Field.allCases
        where !changed.contains(field) && !incoming.matches(baseline, in: field) {
            reloadRows(field, from: saved)
        }
        baseline = incoming
        pristine = draft.sections
        statusMessage = nil
        return saved
    }

    /// Saves after typing pauses. Every keystroke restarts the wait, so a
    /// sentence is written once, not once per letter.
    func scheduleSave(
        store: MarkdownStore,
        onSaved: @escaping @MainActor (MeetingNote) -> Void = { _ in },
        onFailure: @escaping @MainActor (String) -> Void
    ) {
        pendingSave?.cancel()
        guard hasChanges else { return }
        pendingSave = Task { [weak self, weak store] in
            try? await Task.sleep(for: Self.saveDelay)
            guard !Task.isCancelled, let self, let store, self.hasChanges, let owner = self.owner else { return }
            guard let note = store.note(matching: owner) else {
                self.statusMessage = Self.missingNoteReason
                onFailure(Self.missingNoteReason)
                return
            }
            do {
                onSaved(try self.save(note: note, store: store))
            } catch {
                self.statusMessage = error.localizedDescription
                onFailure(error.localizedDescription)
            }
        }
    }

    /// Saves whatever is pending, finding the note by identity. Returns the
    /// reason nothing could be written, or nil when every word is safe.
    func saveIfNeeded(store: MarkdownStore) -> String? {
        pendingSave?.cancel()
        retryParked(store: store)
        return saveLiveDraft(store: store) ?? parked.values.first?.reason
    }

    /// Puts the file's version back into the rows, for when a save was
    /// refused because the sections changed somewhere else.
    func discardChanges(for note: MeetingNote) {
        guard owner == note.libraryIdentity else { return }
        pendingSave?.cancel()
        load(note)
    }

    private func saveLiveDraft(store: MarkdownStore) -> String? {
        guard hasChanges, let owner else { return nil }
        guard let note = store.note(matching: owner) else {
            let reason = Self.missingNoteReason
            statusMessage = reason
            return reason
        }
        do {
            try save(note: note, store: store)
            return nil
        } catch {
            statusMessage = error.localizedDescription
            return error.localizedDescription
        }
    }

    private func retryParked(store: MarkdownStore) {
        for (identity, waiting) in parked {
            guard let note = store.note(matching: identity) else {
                parked[identity]?.reason = Self.missingNoteReason
                continue
            }
            var proposed = waiting.baseline
            let current = waiting.draft.sections
            for field in GeneratedSections.Field.allCases where !current.matches(waiting.pristine, in: field) {
                proposed.take(field, from: current)
            }
            do {
                _ = try store.updateGeneratedSections(proposed, expected: waiting.baseline, for: note)
                parked.removeValue(forKey: identity)
            } catch {
                parked[identity]?.reason = error.localizedDescription
            }
        }
    }

    /// Called after a note's file went to the Trash: its edits have nowhere
    /// to go and must not be written into a same-UUID copy.
    func noteWasDeleted(_ note: MeetingNote) {
        parked.removeValue(forKey: note.libraryIdentity)
        guard owner == note.libraryIdentity else { return }
        pendingSave?.cancel()
        owner = nil
        baseline = GeneratedSections()
        pristine = GeneratedSections()
        draft = Draft()
        statusMessage = nil
    }

    private static let missingNoteReason =
        "The note these edits belong to is no longer in this folder."
}
