import AppKit
import SwiftUI

/// Several notes selected at once, the way Finder, Mail and Notes allow.
///
/// The multi-selection is one more `LibrarySelection` value rather than a
/// second piece of state beside it. That keeps every existing safety path
/// (the leave guard, the pending selection behind the Save or Discard alert,
/// scope changes) working unchanged: leaving a note with unsaved Markdown for
/// a multi-selection asks exactly as leaving it for another note does.
///
/// A `.notes` value always holds two or more notes. One note is `.note`, so
/// the detail column shows it and nothing downstream has to treat a
/// one-element set as a special case.
extension LibrarySelection {
    /// The canonical selection for these notes: nothing, one note, or many.
    static func forNotes<S: Sequence>(_ identities: S) -> LibrarySelection?
    where S.Element == LibraryNoteIdentity {
        let set = Set(identities)
        switch set.count {
        case 0: return nil
        case 1: return .note(set.first!)
        default: return .notes(set)
        }
    }

    /// The notes this selection holds, empty for the live, prep and copies
    /// panes.
    var noteIdentities: Set<LibraryNoteIdentity> {
        switch self {
        case .note(let identity): [identity]
        case .notes(let identities): identities
        case .live, .prep, .copies: []
        }
    }

    var isMultipleNotes: Bool {
        if case .notes = self { return true }
        return false
    }

    /// The rows the sidebar's `List` shows as selected.
    static func listRows(for selection: LibrarySelection?) -> Set<LibrarySelection> {
        switch selection {
        case nil, .copies: []
        case .notes(let identities): Set(identities.map(LibrarySelection.note))
        case let single?: [single]
        }
    }

    /// Turns what the `List` proposes into a selection the library accepts.
    ///
    /// Only note rows take part in a multi-selection. A live or prep row wins
    /// only when it is the one row the user just added, which is a click or a
    /// Command-click on it; it then replaces the notes. When it arrives
    /// together with notes (Select All, or a Shift-click range that crosses
    /// it) it is dropped and the notes are kept.
    static func fromList(
        _ proposed: Set<LibrarySelection>,
        replacing current: LibrarySelection?
    ) -> LibrarySelection? {
        var notes: [LibraryNoteIdentity] = []
        var specials: [LibrarySelection] = []
        for row in proposed {
            switch row {
            case .note(let identity): notes.append(identity)
            case .notes(let identities): notes.append(contentsOf: identities)
            case .live, .prep: specials.append(row)
            case .copies: continue
            }
        }
        let added = proposed.subtracting(listRows(for: current))
        if added.count == 1, let only = added.first, specials.contains(only) {
            return only
        }
        if notes.isEmpty {
            // Two standing rows at once can only come from a range between
            // them. Prefer the one that was not already selected.
            return specials.first(where: { added.contains($0) }) ?? specials.first
        }
        return forNotes(notes)
    }

    /// Keeps the selected notes that a new range, folder or search still
    /// shows. Nil when none of them are visible, so the caller can choose
    /// the first visible note as it does for a single selection.
    func restricted(to visible: [LibraryNoteIdentity]) -> LibrarySelection? {
        let kept = noteIdentities.intersection(visible)
        return Self.forNotes(kept)
    }

    /// The same notes after the library changed underneath them: a note
    /// whose file moved (a folder renamed or removed, a move in Finder) is
    /// followed by its unique ID, and a note that is gone leaves the
    /// selection. Returns nil when no note is left.
    func following(
        present: Set<LibraryNoteIdentity>,
        uniqueNote: (UUID) -> LibraryNoteIdentity?
    ) -> LibrarySelection? {
        let followed = noteIdentities.compactMap { identity -> LibraryNoteIdentity? in
            if present.contains(identity) { return identity }
            return uniqueNote(identity.noteID)
        }
        return Self.forNotes(followed)
    }

    /// The selection after Nook moved some of its notes, each to a new path.
    func applyingMoves(
        _ moves: [LibraryNoteIdentity: LibraryNoteIdentity]
    ) -> LibrarySelection? {
        switch self {
        case .note(let identity):
            return .note(moves[identity] ?? identity)
        case .notes(let identities):
            return Self.forNotes(identities.map { moves[$0] ?? $0 })
        case .live, .prep, .copies:
            return self
        }
    }

    /// What a note row's context menu acts on. As in Finder: the whole
    /// selection when the row is part of it, only that row otherwise.
    func contextTargets(for row: LibraryNoteIdentity) -> Set<LibraryNoteIdentity> {
        let selected = noteIdentities
        guard selected.count > 1, selected.contains(row) else { return [row] }
        return selected
    }
}

/// Moving and trashing several notes at once. Each note goes through the
/// same store call a single note does, so every refusal it has (a file
/// changed elsewhere, a busy note, a missing folder, a Trash that is not
/// available) still applies, and one failure never stops the others.
@MainActor
enum LibraryBulkNoteAction {
    struct Failure: Equatable {
        let title: String
        let reason: String
    }

    struct MoveOutcome: Equatable {
        let total: Int
        /// Old identity to new identity, for every note whose file moved.
        var moved: [LibraryNoteIdentity: LibraryNoteIdentity] = [:]
        var alreadyThere = 0
        var failures: [Failure] = []
    }

    struct DeleteOutcome: Equatable {
        let total: Int
        var deleted: [LibraryNoteIdentity] = []
        var failures: [Failure] = []
    }

    static func move(
        _ identities: [LibraryNoteIdentity],
        toFolder folder: String?,
        store: MarkdownStore
    ) -> MoveOutcome {
        var outcome = MoveOutcome(total: identities.count)
        for identity in identities {
            // Resolved again for each note: the store publishes a new
            // snapshot after every move.
            guard let note = store.note(matching: identity) else {
                outcome.failures.append(Failure(
                    title: "A note",
                    reason: MarkdownStoreError.fileChangedElsewhere.localizedDescription
                ))
                continue
            }
            guard !store.duplicateNoteIDs.contains(note.id) else {
                outcome.failures.append(Failure(
                    title: note.title,
                    reason: MarkdownStoreError.ambiguousNoteIdentity.localizedDescription
                ))
                continue
            }
            if note.fileURL != nil, store.folderName(of: note) == folder {
                outcome.alreadyThere += 1
                continue
            }
            do {
                let moved = try store.move(note, toFolder: folder)
                outcome.moved[identity] = moved.libraryIdentity
            } catch {
                outcome.failures.append(Failure(
                    title: note.title, reason: error.localizedDescription
                ))
            }
        }
        return outcome
    }

    static func delete(
        _ identities: [LibraryNoteIdentity],
        store: MarkdownStore
    ) -> DeleteOutcome {
        var outcome = DeleteOutcome(total: identities.count)
        var firstError: String?
        for identity in identities {
            guard let note = store.note(matching: identity) else {
                let reason = "The original note is no longer available."
                outcome.failures.append(Failure(title: "A note", reason: reason))
                continue
            }
            if store.delete(note) {
                outcome.deleted.append(identity)
            } else {
                let reason = store.lastError ?? "Nook couldn’t move this note to the Trash."
                firstError = firstError ?? reason
                outcome.failures.append(Failure(title: note.title, reason: reason))
            }
        }
        // A later success clears the store's error. The library status
        // still owes the first refusal, as it would for a single delete.
        if let firstError { store.lastError = firstError }
        return outcome
    }

    static func moveNotice(
        _ outcome: MoveOutcome,
        toFolder folder: String?
    ) -> (message: String, isFailure: Bool) {
        let destination = folder ?? "Library"
        let moved = outcome.moved.count
        guard let first = outcome.failures.first else {
            if moved == 0 {
                return ("Already in \(destination)", false)
            }
            return ("Moved \(LibraryBulkCopy.notes(moved)) to \(destination)", false)
        }
        let others = outcome.failures.count - 1
        let detail = others == 0
            ? "“\(first.title)” wasn’t moved. \(first.reason)"
            : "\(LibraryBulkCopy.notes(outcome.failures.count)) weren’t moved. \(first.reason)"
        if moved == 0 {
            return ("No notes were moved. \(first.reason)", true)
        }
        return ("Moved \(moved) of \(LibraryBulkCopy.notes(outcome.total)) to \(destination). \(detail)", true)
    }

    static func deleteNotice(_ outcome: DeleteOutcome) -> (message: String, isFailure: Bool) {
        let deleted = outcome.deleted.count
        guard let first = outcome.failures.first else {
            return ("Moved \(LibraryBulkCopy.notes(deleted)) to the Trash", false)
        }
        let others = outcome.failures.count - 1
        let rest = others == 0 ? "" : " \(LibraryBulkCopy.notes(others)) more also stayed where they were."
        if deleted == 0 {
            return ("No notes were moved to the Trash. \(first.reason)", true)
        }
        return ("Moved \(deleted) of \(LibraryBulkCopy.notes(outcome.total)) to the Trash. \(first.reason)\(rest)", true)
    }
}

enum LibraryBulkCopy {
    static func notes(_ count: Int) -> String {
        count == 1 ? "1 note" : "\(count) notes"
    }

    static func selectedTitle(_ count: Int) -> String {
        "\(count) Notes Selected"
    }

    static func trashTitle(_ count: Int) -> String {
        count == 1 ? "Move this note to the Trash?" : "Move \(count) notes to the Trash?"
    }

    static let trashMessage = "The Markdown files move to the Trash and can be restored from there. Unsaved edits and recovery copies for these notes are also discarded. Kept audio remains available in Recovery until you delete it there."

    static func mergeMessage(target: String) -> String {
        "Both notes become one, kept as “\(target)”, the meeting that started first. Transcripts, moments, personal notes, and action items are combined, kept audio is joined into a single recording, and the summary is written again from everything. A title you typed is kept. The other note moves to the Trash."
    }

    /// Names the first titles, as Mail's selection summary does, and counts
    /// the rest rather than listing a long selection in full.
    static func titleSummary(_ titles: [String]) -> String {
        let shown = titles.count <= 3 ? titles : Array(titles.prefix(2))
        let rest = titles.count - shown.count
        let quoted = shown.map { "“\($0)”" }
        if rest > 0 {
            return quoted.joined(separator: ", ") + " and \(rest) more"
        }
        return quoted.formatted(.list(type: .and))
    }
}

/// What a dragged note row carries. A private text form rather than the
/// file's URL: a file URL dropped on Finder would move or copy the Markdown
/// behind Nook's back, while this names the note only to Nook's own folders.
///
/// A multi-selection travels as one payload with one note per line. Each
/// line is validated on its own, so a foreign or damaged line is ignored
/// rather than taking the rest of the drop with it.
enum LibraryNoteDrag {
    private static let prefix = "nook-note:"
    /// Far more than a sidebar selection, and small enough that pasted text
    /// cannot make a drop do unbounded work.
    static let maximumNotes = 2_000

    static func payload(for note: MeetingNote) -> String {
        payload(for: note.libraryIdentity)
    }

    static func payload(for identity: LibraryNoteIdentity) -> String {
        prefix + identity.noteID.uuidString + ":" + (identity.filePath ?? "")
    }

    static func payload(for identities: [LibraryNoteIdentity]) -> String {
        identities.map(payload(for:)).joined(separator: "\n")
    }

    static func identity(from payload: String) -> LibraryNoteIdentity? {
        guard payload.hasPrefix(prefix) else { return nil }
        let body = payload.dropFirst(prefix.count)
        guard let separator = body.firstIndex(of: ":"),
              let id = UUID(uuidString: String(body[..<separator])) else { return nil }
        let path = String(body[body.index(after: separator)...])
        guard path.hasPrefix("/"), !path.contains("\n") else { return nil }
        return LibraryNoteIdentity(noteID: id, fileURL: URL(fileURLWithPath: path))
    }

    /// Every note named in the dropped items, in order and without repeats.
    static func identities(from items: [String]) -> [LibraryNoteIdentity] {
        var seen = Set<LibraryNoteIdentity>()
        var result: [LibraryNoteIdentity] = []
        for item in items {
            for line in item.split(separator: "\n", omittingEmptySubsequences: true) {
                guard result.count < maximumNotes,
                      let identity = identity(from: String(line)),
                      seen.insert(identity).inserted else { continue }
                result.append(identity)
            }
        }
        return result
    }
}

/// The detail column while several notes are selected. Like Finder's and
/// Notes' multi-selection panes: what is selected, and the actions that
/// apply to all of it.
struct LibraryMultiSelectionPane: View {
    let notes: [MeetingNote]
    let folders: [String]
    /// The folder every selected note is in, or nil when they differ or all
    /// sit in the library's root; see `allInLibraryRoot`.
    let commonFolder: String?
    let allInLibraryRoot: Bool
    let canMove: Bool
    let canMerge: Bool
    let showsMerge: Bool
    let onMove: (String?) -> Void
    let onNewFolder: () -> Void
    let onMerge: () -> Void
    let onTrash: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            LibraryNoteStack(notes: Array(notes.prefix(3)))
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text(LibraryBulkCopy.selectedTitle(notes.count))
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(LibraryBulkCopy.titleSummary(notes.map(\.title)))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(maxWidth: 540)
            }

            HStack(spacing: 10) {
                Menu {
                    LibraryMoveToMenuItems(
                        folders: folders,
                        commonFolder: commonFolder,
                        allInLibraryRoot: allInLibraryRoot,
                        onMove: onMove,
                        onNewFolder: onNewFolder
                    )
                } label: {
                    Label("Move To", systemImage: "folder")
                }
                .fixedSize()
                .disabled(!canMove)
                .help("Move the selected notes to a folder")

                if showsMerge {
                    Button(action: onMerge) {
                        Label("Merge…", systemImage: "arrow.triangle.merge")
                    }
                    .disabled(!canMerge)
                    .help("Combine the two selected notes into one")
                }

                Button(role: .destructive, action: onTrash) {
                    Label("Move to Trash", systemImage: "trash")
                }
                .disabled(!canMove)
                .help("Move the selected notes to the Trash")
            }
            .controlSize(.large)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(LibraryBulkCopy.selectedTitle(notes.count))
        .onAppear(perform: announce)
        .onChange(of: notes.count) { _, _ in announce() }
    }

    private func announce() {
        AccessibilityNotification.Announcement(
            "\(LibraryBulkCopy.notes(notes.count)) selected"
        ).post()
    }
}

/// Move To for one note or several. The notes' own location is shown
/// checked rather than offered as a no-op move.
struct LibraryMoveToMenuItems: View {
    let folders: [String]
    let commonFolder: String?
    let allInLibraryRoot: Bool
    /// Nook's suggestion for a single note, offered first under its own
    /// heading, the way Finder lists recent destinations before the rest.
    var suggestedFolder: String? = nil
    let onMove: (String?) -> Void
    let onNewFolder: () -> Void

    var body: some View {
        if let suggestedFolder, folders.contains(suggestedFolder), commonFolder != suggestedFolder {
            Section("Suggested") {
                Button {
                    onMove(suggestedFolder)
                } label: {
                    Label(suggestedFolder, systemImage: "folder")
                }
                .accessibilityLabel("\(suggestedFolder), suggested folder")
            }
            Divider()
        }
        Button {
            onMove(nil)
        } label: {
            if allInLibraryRoot {
                Label("Library", systemImage: "checkmark")
            } else {
                Text("Library")
            }
        }
        .disabled(allInLibraryRoot)
        if !folders.isEmpty {
            Divider()
            ForEach(folders, id: \.self) { name in
                Button {
                    onMove(name)
                } label: {
                    if commonFolder == name {
                        Label(name, systemImage: "checkmark")
                    } else {
                        Text(name)
                    }
                }
                .disabled(commonFolder == name)
            }
        }
        Divider()
        Button("New Folder…", action: onNewFolder)
    }
}

/// A small fanned stack of the selected notes, drawn as paper cards. Titles
/// only: the pane is about the selection, not a preview of each note.
private struct LibraryNoteStack: View {
    let notes: [MeetingNote]
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            // Drawn back to front, so the first selected note is on top.
            ForEach(Array(notes.enumerated().reversed()), id: \.offset) { index, note in
                let placement = Self.placement(index: index, count: notes.count)
                card(for: note, isFront: index == 0)
                    .rotationEffect(.degrees(placement.angle))
                    .offset(placement.offset)
            }
        }
        .frame(width: 260, height: 176)
    }

    /// The front card stays nearly upright; the others fan out behind it.
    /// Two cards lean apart around the centre so the pair looks balanced.
    private static func placement(index: Int, count: Int) -> (angle: Double, offset: CGSize) {
        switch (count, index) {
        case (2, 0): (-2, CGSize(width: -16, height: 0))
        case (2, _): (7, CGSize(width: 24, height: 4))
        case (_, 0): (0, .zero)
        case (_, 1): (-8, CGSize(width: -40, height: 8))
        default: (7, CGSize(width: 38, height: 4))
        }
    }

    private func card(for note: MeetingNote, isFront: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(note.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
            Text(note.startedAt, format: .dateTime.month(.abbreviated).day())
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 5) {
                ForEach(0..<4, id: \.self) { line in
                    Capsule()
                        .fill(.quaternary)
                        .frame(width: line == 3 ? 58 : 96, height: 4)
                }
            }
            .padding(.top, 3)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(width: 124, height: 150, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
        .shadow(
            color: .black.opacity(colorScheme == .dark ? 0.45 : 0.12),
            radius: isFront ? 6 : 3, y: isFront ? 3 : 1
        )
    }
}
