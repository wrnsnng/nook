import AppKit
import SwiftUI

/// One row of the command palette: a verb, a note, or an open action.
struct CommandPaletteItem: Identifiable, Equatable {
    enum Destination: Equatable {
        case verb
        case note(MeetingNote.ID)
        case askLibrary
    }

    let id: String
    let symbol: String
    let title: String
    let subtitle: String?
    let destination: Destination
    /// The global shortcut that already runs this command, written the way
    /// the menus write it. Only ever a shortcut that genuinely exists: a
    /// hint for a key combination that does nothing is worse than no hint.
    var shortcut: String?
    let perform: () -> Void

    static func == (lhs: CommandPaletteItem, rhs: CommandPaletteItem) -> Bool {
        lhs.id == rhs.id
    }
}

enum CommandPaletteCommandDisposition {
    case dismiss
    case keepPresented
}

/// Most commands wait for AppKit to restore the parent's responder before
/// opening their destination. Ask replaces the palette inside the same modal
/// session, so the parent cannot receive question text during sheet dismissal.
struct CommandPalettePresentation {
    private enum Phase { case idle, presented, destination, dismissing }
    private var phase = Phase.idle
    private var pendingCommand: CommandPaletteItem?

    var canPresent: Bool { phase == .idle }
    var isShowingDestination: Bool { phase == .destination }

    var isPresented: Bool {
        get { phase == .presented }
        set {
            if newValue {
                present()
            } else if phase == .presented {
                phase = .dismissing
            }
        }
    }

    mutating func present() {
        guard canPresent else { return }
        pendingCommand = nil
        phase = .presented
    }

    mutating func select(_ command: CommandPaletteItem) {
        guard isPresented else { return }
        pendingCommand = command
        phase = .dismissing
    }

    @discardableResult
    mutating func showDestination() -> Bool {
        guard phase == .presented else { return false }
        pendingCommand = nil
        phase = .destination
        return true
    }

    /// A citation still owes the normal editor leave guard, after Ask closes.
    mutating func finishDestination(with command: CommandPaletteItem? = nil) {
        guard phase == .destination else { return }
        pendingCommand = command
        phase = .dismissing
    }

    /// A folder change or a closing parent invalidates even a command whose
    /// sheet has already started dismissing.
    mutating func cancel() {
        pendingCommand = nil
        if phase == .presented || phase == .destination { phase = .dismissing }
    }

    mutating func takeDismissedCommand() -> CommandPaletteItem? {
        guard phase == .dismissing else { return nil }
        phase = .idle
        let command = pendingCommand
        pendingCommand = nil
        return command
    }
}

/// Establishes the native modal boundary in the shortcut action itself.
/// SwiftUI's state-driven sheet left the parent accepting the first query
/// characters while it scheduled presentation, even with defaultFocus.
@MainActor
final class CommandPaletteSheetPresenter: NSObject, ObservableObject {
    private weak var parentWindow: NSWindow?
    private weak var presentingWindow: NSWindow?
    private var sheet: NSWindow?
    private var presentationID: UUID?
    private var isDismissing = false
    private var onDismiss: (() -> Void)?
    private var onInvalidation: (() -> Void)?

    var canPresent: Bool {
        guard let parentWindow else { return false }
        // beginSheet otherwise queues behind an existing dialog. A palette
        // must never appear later in response to keys typed into that dialog.
        return presentationID == nil && parentWindow.attachedSheet == nil
    }

    func isCurrent(_ id: UUID) -> Bool { presentationID == id }

    func attach(to window: NSWindow?) {
        guard window !== parentWindow else { return }
        invalidate()
        if let parentWindow {
            NotificationCenter.default.removeObserver(
                self, name: NSWindow.willCloseNotification, object: parentWindow
            )
        }
        parentWindow = window
        if let window {
            NotificationCenter.default.addObserver(
                self, selector: #selector(parentWillClose(_:)),
                name: NSWindow.willCloseNotification, object: window
            )
        }
    }

    @discardableResult
    func present(
        id: UUID,
        content: AnyView,
        onDismiss: @escaping () -> Void,
        onInvalidation: @escaping () -> Void
    ) -> Bool {
        guard canPresent, let parentWindow else { return false }
        let hostingView = NSHostingView(rootView: content)
        let sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 464),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        sheet.title = "Command palette"
        sheet.titleVisibility = .hidden
        sheet.titlebarAppearsTransparent = true
        sheet.isReleasedWhenClosed = false
        sheet.tabbingMode = .disallowed
        sheet.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()
        sheet.setContentSize(hostingView.fittingSize)
        sheet.layoutIfNeeded()
        sheet.recalculateKeyViewLoop()
        // Prepare the actual window before beginning the modal session. The
        // SwiftUI-content overload returned before any sheet was attached.
        guard canPresent, self.parentWindow === parentWindow else { return false }
        presentationID = id
        presentingWindow = parentWindow
        self.onDismiss = onDismiss
        self.onInvalidation = onInvalidation
        isDismissing = false
        self.sheet = sheet
        parentWindow.beginSheet(sheet) { [weak self] _ in
            self?.didDismiss(id)
        }
        if isCurrent(id), sheet.sheetParent === parentWindow { sheet.makeKey() }
        return true
    }

    func dismiss(id: UUID? = nil) {
        if let id, !isCurrent(id) { return }
        guard !isDismissing, let sheet, let presentingWindow else { return }
        isDismissing = true
        presentingWindow.endSheet(sheet)
    }

    /// Keep the same native modal boundary while moving into a text-entry
    /// destination. Ending this sheet first lets the parent's sidebar or
    /// editor receive keys before a second sheet has appeared.
    @discardableResult
    func replaceContent(id: UUID, content: AnyView, title: String) -> Bool {
        guard isCurrent(id), !isDismissing,
              let sheet, let presentingWindow,
              parentWindow === presentingWindow,
              presentingWindow.attachedSheet === sheet else { return false }
        let hostingView = NSHostingView(rootView: content)
        guard sheet.makeFirstResponder(nil) else { return false }
        sheet.initialFirstResponder = nil
        sheet.contentView = hostingView
        sheet.title = title
        hostingView.layoutSubtreeIfNeeded()
        sheet.setContentSize(hostingView.fittingSize)
        sheet.layoutIfNeeded()
        sheet.recalculateKeyViewLoop()
        // Selecting through AppKit's prepared key-view loop is synchronous.
        // An onAppear focus request alone still needs a SwiftUI update.
        sheet.selectKeyView(following: hostingView)
        return isCurrent(id) && !isDismissing
            && presentingWindow.attachedSheet === sheet
    }

    func invalidate() {
        guard presentationID != nil else { return }
        onInvalidation?()
        dismiss()
    }

    private func didDismiss(_ id: UUID) {
        guard isCurrent(id) else { return }
        // Native parent teardown need not pass through the palette's binding.
        if !isDismissing { onInvalidation?() }
        let completion = onDismiss
        let dismissedSheet = sheet
        sheet = nil
        presentationID = nil
        presentingWindow = nil
        onDismiss = nil
        onInvalidation = nil
        isDismissing = false
        dismissedSheet?.orderOut(nil)
        dismissedSheet?.contentView = nil
        completion?()
    }

    @objc private func parentWillClose(_ notification: Notification) {
        invalidate()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

/// Captures this library's own window, never whichever app window happens to
/// be key. Window attachment is synchronous and does not activate anything.
struct CommandPaletteWindowAnchor: NSViewRepresentable {
    let presenter: CommandPaletteSheetPresenter

    func makeNSView(context: Context) -> CommandPaletteWindowTrackingView {
        let view = CommandPaletteWindowTrackingView()
        view.presenter = presenter
        return view
    }

    func updateNSView(_ view: CommandPaletteWindowTrackingView, context: Context) {
        view.presenter = presenter
        presenter.attach(to: view.window)
    }

    static func dismantleNSView(_ view: CommandPaletteWindowTrackingView, coordinator: ()) {
        view.presenter?.attach(to: nil)
        view.presenter = nil
    }
}

final class CommandPaletteWindowTrackingView: NSView {
    weak var presenter: CommandPaletteSheetPresenter?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        presenter?.attach(to: window)
    }
}

/// A native hosted sheet does not receive new value arguments from the
/// library's body. Observe the existing controller so refreshed actions still
/// reach the palette without replacing its query, selection, or view identity.
struct CommandPaletteOpenActionsHost: View {
    @ObservedObject var openActions: OpenActionsController
    let content: ([OpenAction]) -> CommandPaletteView

    var body: some View {
        content(Array(openActions.entries.prefix(6)))
    }
}

enum CommandPaletteCommands {
    @MainActor
    static func recording(
        isRecording: Bool,
        shortcuts: ShortcutStore,
        start: @escaping () -> Void,
        finish: @escaping () -> Void
    ) -> CommandPaletteItem {
        CommandPaletteItem(
            id: isRecording ? "verb-finish" : "verb-record",
            symbol: isRecording ? "stop.fill" : "waveform.badge.mic",
            title: isRecording ? "Finish meeting" : "Start recording",
            subtitle: nil,
            destination: .verb,
            shortcut: shortcuts.binding(
                for: isRecording ? .finishMeeting : .startRecording
            ).displayString,
            perform: isRecording ? finish : start
        )
    }
}

/// A titled run of palette rows.
///
/// The palette used to be one flat list where a verb and a meeting looked
/// identical, so the eye had to read every row to learn what kind of thing it
/// was about to run.
struct CommandPaletteSection: Identifiable {
    let title: String
    let items: [CommandPaletteItem]

    var id: String { title }

    /// Groups in a fixed order, dropping anything empty so the palette never
    /// shows a heading with nothing under it.
    static func grouped(
        commands: [CommandPaletteItem],
        notes: [CommandPaletteItem],
        openActions: [CommandPaletteItem]
    ) -> [CommandPaletteSection] {
        [
            CommandPaletteSection(title: "Commands", items: commands),
            CommandPaletteSection(title: "Notes", items: notes),
            CommandPaletteSection(title: "Open actions", items: openActions),
        ]
        .filter { !$0.items.isEmpty }
    }
}

/// A reload can reorder Finder copies without changing their UUID or date.
/// Keep the chosen row's identity, and require another choice if it disappears.
struct CommandPaletteSelection {
    private(set) var itemID: String?
    private var selectsFirstSearchResult = false

    mutating func beginSearch() {
        itemID = nil
        selectsFirstSearchResult = true
    }

    mutating func finishSearch(in items: [CommandPaletteItem]) {
        refresh(in: items, selectFirst: selectsFirstSearchResult && itemID == nil)
        selectsFirstSearchResult = false
    }

    mutating func select(_ item: CommandPaletteItem) {
        selectsFirstSearchResult = false
        itemID = item.id
    }

    mutating func refresh(in items: [CommandPaletteItem], selectFirst: Bool = false) {
        if selectFirst {
            itemID = items.first?.id
        } else if !items.contains(where: { $0.id == itemID }) {
            itemID = nil
        }
    }

    mutating func move(_ direction: Int, in items: [CommandPaletteItem]) {
        guard !items.isEmpty else { return }
        selectsFirstSearchResult = false
        let index: Int
        if let current = items.firstIndex(where: { $0.id == itemID }) {
            index = min(max(current + direction, 0), items.count - 1)
        } else {
            index = direction < 0 ? items.count - 1 : 0
        }
        itemID = items[index].id
    }

    func selectedItem(in items: [CommandPaletteItem]) -> CommandPaletteItem? {
        items.first { $0.id == itemID }
    }
}

/// Fuzzy matching is local and deterministic. Exact title hits lead, then
/// abbreviations/typos, then content. Matching never changes the stored words.
enum CommandPaletteNoteOrder {
    nonisolated static func ordered(
        _ notes: [MeetingNote],
        matching query: String,
        documents: [LibraryNoteIdentity: String]? = nil,
        isCancelled: @Sendable () -> Bool = { Task.isCancelled }
    ) -> [MeetingNote] {
        guard !isCancelled() else { return [] }
        let matcher = PaletteFuzzyQuery(query)
        var hits: [(note: MeetingNote, rank: Int)] = []
        for note in notes {
            guard !isCancelled() else { return [] }
            let rank: Int?
            if matcher.text.isEmpty {
                rank = 0
            } else if let titleRank = matcher.rank(in: note.title, isTitle: true, isCancelled: isCancelled) {
                rank = titleRank
            } else {
                let document = documents?[note.libraryIdentity]
                    ?? LibrarySearchController.document(for: note)
                rank = matcher.rank(in: document, isTitle: false, isCancelled: isCancelled).map { $0 + 3 }
            }
            // A cancelled last note must not return the earlier partial hits.
            guard !isCancelled() else { return [] }
            if let rank { hits.append((note, rank)) }
        }
        guard !isCancelled() else { return [] }
        let ordered = hits.sorted {
            if $0.rank != $1.rank { return $0.rank < $1.rank }
            let left = $0.note
            let right = $1.note
            if left.startedAt != right.startedAt { return left.startedAt > right.startedAt }
            let leftPath = left.libraryIdentity.filePath ?? ""
            let rightPath = right.libraryIdentity.filePath ?? ""
            if leftPath != rightPath { return leftPath < rightPath }
            return left.id.uuidString < right.id.uuidString
        }.map(\.note)
        guard !isCancelled() else { return [] }
        return matcher.text.isEmpty ? Array(ordered.prefix(5)) : ordered
    }
}

private struct PaletteFuzzyQuery {
    let text: String
    private let terms: [String]

    init(_ query: String) {
        text = Self.normalized(query).trimmingCharacters(in: .whitespacesAndNewlines)
        terms = text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    func rank(in source: String, isTitle: Bool, isCancelled: () -> Bool) -> Int? {
        guard !isCancelled() else { return nil }
        let value = Self.normalized(source)
        guard !isCancelled() else { return nil }
        if value.hasPrefix(text) { return 0 }
        if value.contains(text) { return 1 }
        guard !isCancelled() else { return nil }
        let words = value.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        if isTitle {
            // Initials let "rr" find "Research review"; do not let a pair of
            // letters match arbitrary distant characters in a transcript.
            let initials = String(words.compactMap(\.first))
            if text.count >= 2, !text.contains(" "), initials.hasPrefix(text) { return 2 }
        }
        for term in terms {
            guard !isCancelled() else { return nil }
            if value.contains(term) { continue }
            var matched = false
            for word in words {
                // One long transcript can contain most of the library's work.
                // Checking only between notes/terms leaves obsolete fuzzy
                // comparisons running after the next query has already begun.
                guard !isCancelled() else { return nil }
                if Self.fuzzyWord(term, matches: word) {
                    matched = true
                    break
                }
            }
            guard matched else { return nil }
        }
        return 2
    }

    private static func normalized(_ text: String) -> String {
        text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    private static func fuzzyWord(_ query: String, matches word: String) -> Bool {
        // Short strings have too little information for typo guesses. Limit
        // edit-distance work, not source text: long words still match exactly.
        guard query.count >= 3, query.count <= 64, word.count <= 64 else { return false }
        let needle = Array(query)
        let candidate = Array(word)
        if needle.count >= 3, needle.first == candidate.first,
           candidate.count <= needle.count * 2 {
            var index = 0
            for character in candidate where index < needle.count {
                if character == needle[index] { index += 1 }
            }
            if index == needle.count { return true }
        }
        let limit = needle.count >= 8 ? 2 : 1
        guard abs(needle.count - candidate.count) <= limit else { return false }
        // Bounded Damerau-Levenshtein also recognizes a transposed keystroke.
        var previous = Array(0...candidate.count)
        var beforePrevious = previous
        for i in 1...needle.count {
            var row = [i] + Array(repeating: 0, count: candidate.count)
            for j in 1...candidate.count {
                row[j] = min(
                    row[j - 1] + 1,
                    previous[j] + 1,
                    previous[j - 1] + (needle[i - 1] == candidate[j - 1] ? 0 : 1)
                )
                if i > 1, j > 1,
                   needle[i - 1] == candidate[j - 2],
                   needle[i - 2] == candidate[j - 1] {
                    row[j] = min(row[j], beforePrevious[j - 2] + 1)
                }
            }
            if row.min()! > limit { return false }
            beforePrevious = previous
            previous = row
        }
        return previous[candidate.count] <= limit
    }
}

/// Searching whole transcripts cannot run on the query field's main actor.
/// One cancellable request owns each result; closing or changing the library
/// invalidates it even if an old matcher ignores cancellation.
@MainActor
final class CommandPaletteSearchController: ObservableObject {
    @Published private(set) var matches: [MeetingNote] = []
    @Published private(set) var isSearching = false
    private let documents = SearchDocumentCache()
    private let matcher: @Sendable (String, [MeetingNote], [LibraryNoteIdentity: String]) async -> [MeetingNote]
    private var task: Task<Void, Never>?
    private var revision = 0

    init(
        matcher: @escaping @Sendable (String, [MeetingNote], [LibraryNoteIdentity: String]) async -> [MeetingNote] = {
            CommandPaletteNoteOrder.ordered($1, matching: $0, documents: $2)
        }
    ) {
        self.matcher = matcher
    }

    deinit { task?.cancel() }

    @discardableResult
    func update(query: String, notes: [MeetingNote]) -> Task<Void, Never>? {
        cancel()
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            matches = CommandPaletteNoteOrder.ordered(notes, matching: "")
            return nil
        }
        isSearching = true
        let expected = revision
        task = Task { [weak self, documents, matcher] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let snapshots = await documents.documents(for: notes)
            guard !Task.isCancelled else { return }
            let worker = Task.detached(priority: .userInitiated) {
                await matcher(query, notes, snapshots)
            }
            let result = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled, let self, self.revision == expected else { return }
            self.matches = result
            self.isSearching = false
        }
        return task
    }

    func cancel() {
        revision += 1
        task?.cancel()
        task = nil
        matches = []
        isSearching = false
    }
}

/// A `⌘K` launcher over everything the library can do.
///
/// Verbs stay visible so the palette teaches the app's actions while it
/// jumps between them; notes use a cancellable local fuzzy search; open actions appear so follow-through is one keystroke away.
/// A native sheet owns the keyboard and accessibility boundary. An overlay
/// left the underlying editor focused, so typing a query edited the note.
struct CommandPaletteView: View {
    @Binding var isPresented: Bool
    @EnvironmentObject private var store: MarkdownStore
    @EnvironmentObject private var meeting: MeetingCoordinator
    @EnvironmentObject private var shortcuts: ShortcutStore

    /// The sidebar's aggregated open items, so follow-through is one
    /// keystroke away.
    let openActionEntries: [OpenAction]
    let createNote: (NoteTemplate) -> Void
    let createWeeklyDigest: () -> Void
    let showAskSheet: () -> Void
    let presentQuickNote: () -> Void
    /// The host queues ordinary commands until dismissal, but can replace the
    /// current sheet for Ask. Static snapshots deliberately perform no actions.
    var onSelectCommand: (CommandPaletteItem) -> CommandPaletteCommandDisposition = { _ in .dismiss }

    @State private var query = ""
    @StateObject private var noteSearch = CommandPaletteSearchController()
    @State private var selection = CommandPaletteSelection()
    @FocusState private var queryFocused: Bool
    /// The sections as of the last refresh. `sections` used to be computed
    /// straight in the body, lowercasing every note on every hover
    /// (`selection` is `@State`, so a hover invalidated the view) and on
    /// every tick the coordinator publishes while the palette happens to be
    /// open during a recording. Recomputed only from `refreshSections()`,
    /// called when the query, the notes, or whether a meeting is recording
    /// actually changes.
    @State private var cachedSections: [CommandPaletteSection] = []

    var body: some View {
        VStack(spacing: 0) {
            searchHeader
            if noteSearch.isSearching {
                ProgressView("Searching notes…")
                    .controlSize(.small)
                    .padding(.bottom, NookSpacing.small)
            }
            SoftDivider()

            if items.isEmpty, !noteSearch.isSearching {
                emptyState
            } else {
                resultsList
            }
        }
        .frame(width: 560)
        .background(
            .regularMaterial,
            in: RoundedRectangle(
                cornerRadius: NookRadius.surface,
                style: .continuous
            )
        )
        .overlay {
            RoundedRectangle(cornerRadius: NookRadius.surface, style: .continuous)
                .stroke(.primary.opacity(0.12), lineWidth: 0.7)
        }
        // Arrow navigation must work while the query field holds focus, which
        // field-level key handling cannot promise; hidden accelerators can.
        .background {
            Button("Previous") {
                moveSelection(-1)
            }
            .keyboardShortcut(.upArrow, modifiers: [])
            .focusable(false)
            .allowsHitTesting(false)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)

            Button("Next") {
                moveSelection(1)
            }
            .keyboardShortcut(.downArrow, modifiers: [])
            .focusable(false)
            .allowsHitTesting(false)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
        }
        .onExitCommand { isPresented = false }
        // Register the field as the sheet's initial focus destination. Asking
        // in onAppear required another focus update and let the first typed
        // character reach the parent window during the presentation handoff.
        .defaultFocus($queryFocused, true)
        .onAppear {
            selection.beginSearch()
            noteSearch.update(query: query, notes: store.notes)
            refreshSections(selectFirst: true)
        }
        .onChange(of: query) { _, _ in
            selection.beginSearch()
            noteSearch.update(query: query, notes: store.notes)
            refreshSections(selectFirst: true)
        }
        .onChange(of: store.notes) { _, _ in
            noteSearch.update(query: query, notes: store.notes)
            refreshSections()
        }
        .onChange(of: noteSearch.matches) { _, _ in
            refreshSections()
        }
        .onChange(of: noteSearch.isSearching) { _, isSearching in
            if !isSearching {
                refreshSections()
                selection.finishSearch(in: items)
            }
        }
        .onDisappear { noteSearch.cancel() }
        .onChange(of: meeting.phase) { _, _ in
            refreshSections()
        }
        .onChange(of: openActionEntries) { _, _ in
            refreshSections()
        }
        .onChange(of: shortcuts.overrides) { _, _ in
            refreshSections()
        }
        // Give the sheet a named group without replacing the search field
        // and Close button's own names in the accessibility tree.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Command palette")
    }

    private var searchHeader: some View {
        HStack(spacing: NookSpacing.small) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(
                "Type a command or search notes",
                text: $query
            )
            .textFieldStyle(.plain)
            .font(NookType.body)
            .focused($queryFocused)
            .onSubmit(runSelected)
            .accessibilityLabel("Search commands and notes")

            Button {
                isPresented = false
            } label: {
                Image(systemName: "xmark")
                    .font(NookType.micro.weight(.semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Close command palette (Escape)")
            .accessibilityLabel("Close command palette")
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
    }

    private var emptyState: some View {
        Label("Nothing matches.", systemImage: "questionmark.circle")
            .font(NookType.body)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 26)
    }

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(sections) { section in
                        sectionHeader(section.title)
                        ForEach(section.items) { item in
                            row(item, isSelected: item.id == selection.itemID)
                                .id(item.id)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: selection.itemID) { _, itemID in
                if let itemID { proxy.scrollTo(itemID, anchor: .center) }
            }
            .onChange(of: items.map(\.id)) { _, _ in
                if let itemID = selection.itemID {
                    proxy.scrollTo(itemID, anchor: .center)
                }
            }
        }
        // A ScrollView takes every point offered, which left a blank band
        // under a short result list. Sized to its content first, then capped.
        .frame(maxHeight: 420)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(NookType.micro.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }

    private func row(
        _ item: CommandPaletteItem,
        isSelected: Bool
    ) -> some View {
        // Runs the row that was pressed. It used to run whichever row was
        // highlighted, so clicking anything the pointer had not settled on
        // ran a different command than the one under the cursor.
        Button {
            run(item)
        } label: {
            HStack(spacing: NookSpacing.medium - 2) {
                Image(systemName: item.symbol)
                    .font(NookType.bodyEmphasized)
                    .foregroundStyle(
                        isSelected ? Color.white : NookPalette.accent
                    )
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(NookType.bodyEmphasized)
                        .foregroundStyle(
                            isSelected
                                ? Color.white : Color(nsColor: .labelColor)
                        )
                        .lineLimit(1)
                    if let subtitle = item.subtitle {
                        Text(subtitle)
                            .font(NookType.caption)
                            .foregroundStyle(
                                isSelected
                                    ? Color.white.opacity(0.82) : .secondary
                            )
                            .lineLimit(1)
                            .help(subtitle)
                    }
                }
                Spacer(minLength: NookSpacing.small)
                if let shortcut = item.shortcut {
                    Text(shortcut)
                        .font(NookType.micro.weight(.medium))
                        .foregroundStyle(
                            isSelected
                                ? Color.white.opacity(0.72)
                                : Color(nsColor: .tertiaryLabelColor)
                        )
                        .accessibilityLabel("Shortcut \(shortcut)")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background {
                if isSelected {
                    RoundedRectangle(
                        cornerRadius: NookRadius.control,
                        style: .continuous
                    )
                    .fill(NookPalette.sidebarSelection)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            guard hovering else { return }
            selection.select(item)
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func moveSelection(_ direction: Int) {
        selection.move(direction, in: items)
    }

    private func runSelected() {
        guard let item = selection.selectedItem(in: items) else { return }
        run(item)
    }

    private func run(_ item: CommandPaletteItem) {
        if onSelectCommand(item) == .dismiss { isPresented = false }
    }

    // MARK: - Items

    /// The sections as of the last `refreshSections()` call. See
    /// `cachedSections`.
    private var sections: [CommandPaletteSection] { cachedSections }

    /// Redoes the query match, the note search, and the open-actions list.
    /// Called from `refreshSections()`'s call sites rather than from `body`,
    /// so a hover or a meter tick that changes none of the query, the notes,
    /// or the recording state does not lowercase and filter every note again.
    private func refreshSections(selectFirst: Bool = false) {
        cachedSections = computeSections()
        selection.refresh(in: items, selectFirst: selectFirst)
    }

    private func computeSections() -> [CommandPaletteSection] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .localizedLowercase

        let commands = verbs.filter {
            needle.isEmpty || $0.title.localizedLowercase.contains(needle)
        }

        let notes = noteSearch.matches.prefix(8).map { note in
            CommandPaletteItem(
                id: "note-\(note.libraryIdentity.navigationKey)",
                symbol: note.kind.symbol,
                title: note.title,
                subtitle: store.duplicateNoteIDs.contains(note.id)
                    ? note.fileURL?.lastPathComponent
                    : note.startedAt.formatted(date: .abbreviated, time: .shortened),
                destination: .note(note.id),
                perform: {
                    NotificationCenter.default.post(
                        name: .nookOpenMeetingNote,
                        object: note.libraryIdentity
                    )
                }
            )
        }

        var openActions: [CommandPaletteItem] = []
        if needle.isEmpty || "actions".hasPrefix(needle) {
            openActions = openActionEntries.prefix(3).map { entry in
                CommandPaletteItem(
                    id: "action-\(entry.id)",
                    symbol: "checklist",
                    title: entry.displayText,
                    subtitle: entry.noteTitle,
                    destination: .note(entry.noteID),
                    perform: {
                        NotificationCenter.default.post(
                            name: .nookOpenMeetingNote,
                            object: entry.noteID
                        )
                    }
                )
            }
        }

        return CommandPaletteSection.grouped(
            commands: commands,
            notes: Array(notes),
            openActions: openActions
        )
    }

    /// The sections flattened, which is what arrow keys move through.
    private var items: [CommandPaletteItem] {
        sections.flatMap(\.items)
    }

    private var verbs: [CommandPaletteItem] {
        var list = [CommandPaletteCommands.recording(
            isRecording: meeting.phase.isRecording,
            shortcuts: shortcuts,
            start: { meeting.startManualMeeting() },
            finish: { meeting.stopRecording() }
        )]
        list.append(
            contentsOf: [
                CommandPaletteItem(
                    id: "verb-palette-note",
                    symbol: "square.and.pencil",
                    title: "New blank note",
                    subtitle: nil,
                    destination: .verb,
                    perform: { createNote(.blank) }
                ),
                CommandPaletteItem(
                    id: "verb-quick-note",
                    symbol: "note.text",
                    title: "Open quick note",
                    subtitle: "A pad for a thought with nowhere to type it",
                    destination: .verb,
                    perform: { presentQuickNote() }
                ),
                CommandPaletteItem(
                    id: "verb-ask",
                    symbol: "sparkle.magnifyingglass",
                    title: "Ask your library",
                    subtitle: nil,
                    destination: .askLibrary,
                    perform: { showAskSheet() }
                ),
                CommandPaletteItem(
                    id: "verb-digest",
                    symbol: "newspaper",
                    title: "Create weekly digest",
                    subtitle: nil,
                    destination: .verb,
                    perform: { createWeeklyDigest() }
                ),
                CommandPaletteItem(
                    id: "verb-folder",
                    symbol: "folder",
                    title: "Open notes folder",
                    subtitle: nil,
                    destination: .verb,
                    perform: { store.openStorageDirectory() }
                ),
            ]
        )
        return list
    }
}
