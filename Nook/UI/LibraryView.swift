import AppKit
import SwiftUI

enum LibrarySelection: Hashable {
    case live
    case note(LibraryNoteIdentity)
    case copies(MeetingNote.ID)
    case prep
}

extension LibraryLeaveGuard {
    /// A reload or phase change must not replace an unanswered destination.
    /// Once that decision settles, every path owes the same editor checks.
    static func decide(
        from current: LibrarySelection?,
        to requested: LibrarySelection?,
        isConfirmingMarkdown: Bool,
        hasMarkdownChanges: Bool,
        hasPersonalNotesChanges: Bool
    ) -> UnsavedEditDecision? {
        guard !isConfirmingMarkdown, requested != current else { return nil }
        return decide(
            hasMarkdownChanges: hasMarkdownChanges,
            hasPersonalNotesChanges: hasPersonalNotesChanges
        )
    }
}

/// A scope change must not hide the editor before its leave decision settles.
/// Keeping the old range until confirmation makes Cancel a true no-op.
struct LibraryScopeState: Equatable {
    private(set) var todayOnly = false
    private(set) var pendingTodayOnly: Bool?

    mutating func request(_ value: Bool, needsConfirmation: Bool) {
        if needsConfirmation {
            pendingTodayOnly = value
        } else {
            todayOnly = value
            pendingTodayOnly = nil
        }
    }

    mutating func settle(confirmed: Bool) {
        if confirmed, let pendingTodayOnly { todayOnly = pendingTodayOnly }
        pendingTodayOnly = nil
    }

    static func visibleSelection(
        preserving selected: LibraryNoteIdentity?,
        in notes: [MeetingNote]
    ) -> LibraryNoteIdentity? {
        if let selected, notes.contains(where: { $0.libraryIdentity == selected }) {
            return selected
        }
        return notes.first?.libraryIdentity
    }
}

enum LibraryPlaceholderState: Equatable {
    case loading
    case loadFailure
    case emptyToday
    case noSearchMatches
    case emptyLibrary
    case noSelection

    static func choose(
        isLoading: Bool,
        hasNotes: Bool,
        todayOnly: Bool,
        hasVisibleNotes: Bool,
        hasSearch: Bool,
        hasLoadError: Bool
    ) -> Self {
        if isLoading { return .loading }
        if !hasNotes, hasLoadError { return .loadFailure }
        if todayOnly, !hasVisibleNotes { return .emptyToday }
        if hasSearch, !hasVisibleNotes { return .noSearchMatches }
        return hasNotes ? .noSelection : .emptyLibrary
    }
}

/// A failed or pending folder reload can leave the previous models visible.
/// The loader reads direct Markdown children, so saved addresses must belong
/// to this exact parent before a new Ask or palette session can use them.
enum LibrarySheetOwnership {
    static func matchesCurrentFolder(_ notes: [MeetingNote], directoryURL: URL) -> Bool {
        let directoryPath = directoryURL.standardizedFileURL.path
        return notes.allSatisfy { note in
            guard let fileURL = note.fileURL else { return true }
            return fileURL.deletingLastPathComponent().standardizedFileURL.path
                == directoryPath
        }
    }
}

struct LibraryNoteGroup: Identifiable {
    let title: String
    let notes: [MeetingNote]
    var id: String { title }
}

/// Which phases put the "Now" row in the sidebar and the live pane in the
/// detail column.
///
/// Lives on the phase itself, not as a private computed property on the
/// view, so both the view that decides the initial selection and the small
/// child view that renders the "Now" row (each observing the coordinator
/// independently, for the reasons explained on `MeetingPhaseObserver`) agree
/// on exactly the same phases without duplicating the switch.
extension MeetingPhase {
    var presentsLiveActivity: Bool {
        switch self {
        case .recording, .processing, .failed: true
        case .idle, .detected, .completed: false
        }
    }
}

/// The sidebar's filtering (search, today-only) and day-bucketing, pulled out
/// of the view so both halves can be pinned with tests and cached without
/// rendering anything.
enum LibraryNoteGrouping {
    static func filter(
        _ notes: [MeetingNote],
        todayOnly: Bool,
        matchingIDs: Set<LibraryNoteIdentity>?,
        calendar: Calendar = .current
    ) -> [MeetingNote] {
        var result = notes
        if todayOnly {
            result = result.filter { calendar.isDateInToday($0.startedAt) }
        }
        guard let matchingIDs else { return result }
        return result.filter { matchingIDs.contains($0.libraryIdentity) }
    }

    static func group(
        _ notes: [MeetingNote],
        referenceDate: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) -> [LibraryNoteGroup] {
        var orderedTitles: [String] = []
        var values: [String: [MeetingNote]] = [:]
        for note in notes {
            let title = title(
                for: note.startedAt,
                referenceDate: referenceDate,
                calendar: calendar
            )
            if values[title] == nil {
                orderedTitles.append(title)
            }
            values[title, default: []].append(note)
        }
        return orderedTitles.map {
            LibraryNoteGroup(title: $0, notes: values[$0] ?? [])
        }
    }

    static func title(
        for date: Date,
        referenceDate: Date,
        calendar: Calendar
    ) -> String {
        if calendar.isDateInToday(date) {
            return "Today"
        }
        if calendar.isDateInYesterday(date) {
            return "Yesterday"
        }
        if let currentWeek = calendar.dateInterval(
            of: .weekOfYear,
            for: referenceDate
        ), currentWeek.contains(date) {
            return "This week"
        }
        return date.formatted(
            .dateTime
                .month(.wide)
                .year()
        )
    }
}

/// What the sidebar's grouped, filtered note list was last computed from.
///
/// While a meeting records, the coordinator publishes audio level up to
/// ~12 times a second and the live transcript up to ~10 times a second.
/// `LibraryView` used to recompute this filter-and-group pass, Calendar
/// arithmetic and all, on every one of those ticks even though none of them
/// touch a note, a search match, or the clock crossing midnight. Comparing
/// this key first, and only redoing the work when it actually changes, turns
/// a tick that changes none of these into a cheap equality check instead of
/// an `O(library)` pass.
///
/// `noteCount` plus a per-note fingerprint stands in for the notes array's
/// identity: two loads that produced the same count and the same fingerprint
/// are the same library for grouping purposes, without diffing every note on
/// every comparison.
///
/// The fingerprint includes file identity and content revision as well as
/// display metadata, not just the newest modification date in the library.
/// The latest-modified-date alone
/// went stale whenever an edit's new timestamp did not change the overall
/// maximum: two saves landing in the same tick, or a volume whose
/// modification dates only carry second granularity, both leave the max
/// looking identical to the last one cached even though a note's title (say)
/// really did change. Folding every note's own identity and revision in means a change to
/// *any* note is visible, including external edits that preserve timestamps
/// and copied notes whose UUIDs collide.
struct LibraryGroupingCacheKey: Equatable {
    let noteCount: Int
    let notesFingerprint: Int
    let matchingIDs: Set<LibraryNoteIdentity>?
    let todayOnly: Bool
    let day: Date

    init(
        notes: [MeetingNote],
        matchingIDs: Set<LibraryNoteIdentity>?,
        todayOnly: Bool,
        now: Date = Date(),
        calendar: Calendar = .current
    ) {
        self.noteCount = notes.count
        self.notesFingerprint = Self.fingerprint(of: notes)
        self.matchingIDs = matchingIDs
        self.todayOnly = todayOnly
        self.day = calendar.startOfDay(for: now)
    }

    /// Combined with XOR rather than folded through one running `Hasher`, so
    /// the result does not depend on the notes' order: a reload that returns
    /// the same notes in a different order must compare equal, or every
    /// reload would look like a change and defeat the cache.
    private static func fingerprint(of notes: [MeetingNote]) -> Int {
        notes.reduce(into: 0) { fingerprint, note in
            var hasher = Hasher()
            hasher.combine(note.libraryIdentity)
            hasher.combine(note.fileRevision)
            hasher.combine(note.fileModified)
            hasher.combine(note.title)
            hasher.combine(note.startedAt)
            // Transient fixtures/unsaved notes have no on-disk revision.
            if note.fileRevision == nil { hasher.combine(note) }
            fingerprint ^= hasher.finalize()
        }
    }
}

/// How much of the standing sidebar furniture is allowed to sit above the
/// meetings.
///
/// At the window's minimum height, one prep card plus five open actions
/// filled the sidebar and the first meeting note was below the fold, which
/// made the library's own contents the least visible thing in it. Three
/// actions leave room for meetings at 580 points; the rest are one click
/// away rather than gone.
enum LibrarySidebarPolicy {
    static let collapsedOpenActionLimit = 3

    static func emptySearchMessage(
        query: String,
        todayOnly: Bool,
        isLoading: Bool,
        isSearching: Bool,
        hasVisibleNotes: Bool
    ) -> String? {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !isLoading, !isSearching, !hasVisibleNotes else { return nil }
        return todayOnly ? "No matching notes today" : "No matching notes"
    }

    static func visibleOpenActions(
        _ entries: [OpenAction],
        showingAll: Bool
    ) -> [OpenAction] {
        guard !showingAll else { return entries }
        return Array(entries.prefix(collapsedOpenActionLimit))
    }

    /// The disclosure under the visible actions, or nil when there is nothing
    /// left to reveal and nothing gained by folding what is already short.
    static func disclosureLabel(
        pool: Int,
        visible: Int,
        showingAll: Bool
    ) -> String? {
        if showingAll {
            guard pool > collapsedOpenActionLimit else { return nil }
            return "Show fewer"
        }
        // Everything past the pool is named separately, so the count here
        // promises only what this disclosure will actually reveal.
        let hidden = pool - visible
        guard hidden > 0 else { return nil }
        return "\(hidden) more"
    }
}

/// Checkpoint completion can publish status without changing any note. Observe
/// it at the recovery section so typing in Quick Note does not invalidate the
/// entire Library just to keep the recovery controls current.
private struct LibraryDraftRecoverySection: View {
    @EnvironmentObject private var journal: DraftJournal
    @EnvironmentObject private var controller: DraftRecoveryController

    var body: some View {
        DraftRecoverySection(controller: controller, journal: journal)
    }
}

struct LibraryView: View {
    @EnvironmentObject private var store: MarkdownStore
    @EnvironmentObject private var markdownDraft: MarkdownDraftController
    @EnvironmentObject private var personalNotesDraft: PersonalNotesDraftController
    @EnvironmentObject private var prep: PrepBriefController
    @EnvironmentObject private var recovery: RecordingRecovery
    @EnvironmentObject private var shortcuts: ShortcutStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var searchController = LibrarySearchController()
    @StateObject private var openActions = OpenActionsController()
    @StateObject private var mergeWorkflow = NoteMergeWorkflow()
    @StateObject private var commandPaletteSheet = CommandPaletteSheetPresenter()
    @State private var selection: LibrarySelection?
    @State private var searchText = ""
    @State private var pendingSelection: LibrarySelection?
    @State private var showsUnsavedChangesAlert = false
    @State private var copyNotice = CopyNoticeState()
    @State private var showsAskSheet = false
    /// Answers and queued palette commands belong to the folder they opened
    /// from. A copied library can contain the same note UUIDs at new paths.
    @State private var askLibraryURL: URL?
    @State private var commandPaletteLibraryURL: URL?
    @State private var commandPaletteAskSession: LibraryAskSession?
    /// The note a second note is being merged into, when the picker shows.
    @State private var mergeTarget: MeetingNote?
    @State private var pendingMergeTarget: LibraryNoteIdentity?
    @State private var pendingMergeGeneration: Int?
    @State private var mergeTask: Task<Void, Never>?
    @State private var mergeIsStopping = false
    /// The note awaiting Trash confirmation.
    @State private var notePendingDeletion: MeetingNote?
    @State private var commandPalette = CommandPalettePresentation()
    /// Sidebar scope: the whole library or just today's capture.
    @State private var scope = LibraryScopeState()
    private var todayOnly: Bool { scope.todayOnly }
    /// Mirrors `meeting.phase`, kept current by `MeetingPhaseObserver`. See
    /// that type for why this view reads a plain, rarely-changing `@State`
    /// value here rather than holding the coordinator itself.
    @State private var currentPhase: MeetingPhase = .idle
    /// Mirrors `meeting.localeIdentifier` through the same observer, for the
    /// recovery section's Recover action. Starts on the same fallback the
    /// coordinator itself uses until the observer first appears. Holding the
    /// coordinator here just to read this value made the whole window
    /// re-render on every meter tick (1.19.0 regression).
    @State private var currentLocaleIdentifier = Locale.current.identifier
    /// The last grouping pass's inputs, and its result. Recomputed only when
    /// `groupingCacheKey` no longer matches; see
    /// `LibraryGroupingCacheKey` for why this exists.
    @State private var groupingCacheKey: LibraryGroupingCacheKey?
    @State private var cachedFilteredNotes: [MeetingNote] = []
    @State private var cachedGroupedNotes: [LibraryNoteGroup] = []
    /// Whether the two standing sections above the meetings are open, and
    /// whether the open-actions list is showing past its cap.
    ///
    /// Remembered rather than reset per launch: at the window's minimum
    /// height one prep card and five open actions pushed every meeting below
    /// the fold, and a person who collapses them means it.
    @AppStorage("library.prepExpanded") private var prepExpanded = true
    @AppStorage("library.openActionsExpanded")
    private var openActionsExpanded = true
    @AppStorage("library.openActionsShowAll")
    private var openActionsShowAll = false

    init(initialNoteID: MeetingNote.ID? = nil) {
        _selection = State(
            initialValue: initialNoteID.map(LibrarySelection.copies)
        )
    }

    /// The filtered notes as of the last cache refresh. See
    /// `LibraryGroupingCacheKey`.
    private var filteredNotes: [MeetingNote] { cachedFilteredNotes }

    /// The grouped notes as of the last cache refresh. See
    /// `LibraryGroupingCacheKey`.
    private var groupedNotes: [LibraryNoteGroup] { cachedGroupedNotes }

    private var selectedNote: MeetingNote? {
        guard case .note(let identity) = selection else { return nil }
        return store.note(matching: identity)
    }

    private var currentGroupingCacheKey: LibraryGroupingCacheKey {
        LibraryGroupingCacheKey(
            notes: store.notes,
            matchingIDs: searchController.matchingIDs,
            todayOnly: todayOnly
        )
    }

    /// Redoes the filter-and-group pass, but only when
    /// `currentGroupingCacheKey` no longer matches what it was last computed
    /// from. Called from `.onChange(of: currentGroupingCacheKey)`, so a tick
    /// that changes none of the key's inputs never reaches this.
    private func refreshLibraryCacheIfNeeded() {
        let key = currentGroupingCacheKey
        guard key != groupingCacheKey else { return }
        groupingCacheKey = key
        let filtered = LibraryNoteGrouping.filter(
            store.notes,
            todayOnly: todayOnly,
            matchingIDs: searchController.matchingIDs
        )
        cachedFilteredNotes = filtered
        cachedGroupedNotes = LibraryNoteGrouping.group(filtered)
    }

    private var presentsLiveActivity: Bool {
        currentPhase.presentsLiveActivity
    }

    // The body is split into three chained properties on purpose. As one
    // expression this chain exceeded the stable compiler's type-check budget
    // and only built on a newer toolchain, which AGENTS.md rule 2 forbids.
    var body: some View {
        librarySheets
    }

    /// The window itself: panes, palette, toolbar, and the notice banner.
    private var libraryChrome: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 260, ideal: 304, max: 380)
        } detail: {
            detail
        }
        .tint(NookPalette.accent)
        .background {
            CommandPaletteWindowAnchor(presenter: commandPaletteSheet)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
            // See `MeetingPhaseObserver`: this is the only place in the view
            // that subscribes to the coordinator, so meter ticks land here
            // instead of on the sidebar's grouping and filtering.
            MeetingPhaseObserver(
                phase: $currentPhase,
                localeIdentifier: $currentLocaleIdentifier
            )
            // A hidden accelerator so the palette reaches from anywhere in
            // the window, toolbar focus included.
            Button("Command Palette", action: presentCommandPalette)
                .keyboardShortcut(
                    shortcuts.binding(for: .commandPalette).keyEquivalent,
                    modifiers: shortcuts.binding(for: .commandPalette)
                        .eventModifiers
                )
                .disabled(!commandPalette.canPresent)
                .focusable(false)
                .allowsHitTesting(false)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(action: presentAskSheet) {
                    Label("Ask your library", systemImage: "sparkle.magnifyingglass")
                }
                .help("Ask a question across all your notes")
                .disabled(store.isLoading)

                Button {
                    createWeeklyDigest()
                } label: {
                    Label("Create weekly digest", systemImage: "newspaper")
                }
                .help("Compile this week's meetings into one note")

                LibraryRecordingToolbar(createNote: createNote)
            }
        }
        .nookNotice(copyNotice.current) { id in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                copyNotice.dismiss(id: id)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if mergeTask != nil {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                    Text(mergeIsStopping ? "Stopping merge…" : "Merging notes on this Mac…")
                        .font(.callout)
                    Spacer(minLength: 12)
                    Button("Cancel Merge", action: cancelMerge)
                        .disabled(mergeIsStopping)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color(nsColor: .windowBackgroundColor))
                .accessibilityElement(children: .contain)
            }
        }
    }

    /// Everything the library reacts to while it is open.
    private var libraryEvents: some View {
        libraryChrome
        .onAppear {
            store.reload()
            searchController.update(query: searchText, notes: store.notes)
            refreshLibraryCacheIfNeeded()
            chooseInitialSelection()
            Task { await openActions.refresh(store: store) }
        }
        .onDisappear {
            invalidateCommandPalette()
            cancelMerge()
        }
        .onChange(of: currentGroupingCacheKey) { _, _ in
            refreshLibraryCacheIfNeeded()
        }
        .onChange(of: store.storageURL.standardizedFileURL) { _, _ in
            // Routine reloads keep a question and its answer visible. Only
            // changing its library invalidates the session; onDisappear then
            // cancels Ask's work. Invalidate a palette command even if its
            // native dismissal is already in progress.
            askLibraryURL = nil
            showsAskSheet = false
            invalidateCommandPalette()
        }
        .onChange(of: store.storageGeneration) { _, _ in
            // A folder switch can return to the original path before SwiftUI
            // renders again. The store generation still invalidates the job.
            mergeTarget = nil
            cancelMerge()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .nookOpenMeetingNote)
        ) { notification in
            if let identity = notification.object as? LibraryNoteIdentity {
                guard store.note(matching: identity) != nil else { return }
                requestSelection(.note(identity))
            } else if let requestedID = notification.object as? MeetingNote.ID {
                requestNote(id: requestedID)
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .nookOpenPrepBrief)
        ) { _ in
            guard prep.current != nil else { return }
            requestSelection(.prep)
        }
        // A brief dies when its event starts. Falling back to the ordinary
        // selection beats stranding the detail pane on a vanished surface.
        .onChange(of: prep.current) { _, brief in
            if brief == nil, selection == .prep {
                requestSelection(restoredOrFirstSelection(in: store.notes))
            }
        }
        .onChange(of: store.notes) { _, notes in
            // Share one array change observation for the derived sidebar
            // state and selection. Separate handlers repeated change tracking
            // over the same library snapshot on each publication.
            Task { await openActions.refresh(store: store) }
            searchController.update(query: searchText, notes: notes)
            guard !notes.isEmpty else {
                if !presentsLiveActivity { requestSelection(nil) }
                return
            }
            if case .note(let identity) = selection,
               !notes.contains(where: { $0.libraryIdentity == identity }) {
                if let renamed = store.uniqueNote(id: identity.noteID) {
                    requestSelection(.note(renamed.libraryIdentity))
                } else {
                    requestSelection(restoredOrFirstSelection(in: notes))
                }
            } else if case .copies(let id) = selection,
                      let unique = store.uniqueNote(id: id) {
                requestSelection(.note(unique.libraryIdentity))
            } else if selection == nil, !presentsLiveActivity {
                requestSelection(restoredOrFirstSelection(in: notes))
            }
        }
        .onChange(of: searchText) { _, query in
            searchController.update(query: query, notes: store.notes)
        }
        .onChange(of: searchController.matchingIDs) { _, _ in
            refreshLibraryCacheIfNeeded()
            synchronizeSelectionWithSearch()
        }
        .onChange(of: currentPhase) { _, phase in
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.34)) {
                switch phase {
                case .recording, .processing, .failed:
                    // Through the guard, not around it. A meeting starting by
                    // itself used to move the pane while a half-typed
                    // Markdown edit was still unsaved, which is exactly the
                    // case the guard exists for.
                    requestSelection(.live)
                case .completed:
                    store.reload()
                    requestSelection(restoredOrFirstSelection(in: store.notes))
                case .idle:
                    if selection == .live {
                        requestSelection(restoredOrFirstSelection(in: store.notes))
                    }
                case .detected:
                    break
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                store.reload()
            }
        }
    }

    /// The sheets and alerts the library can raise over itself.
    private var librarySheets: some View {
        libraryEvents
        .sheet(item: $mergeTarget) { target in
            NoteMergePickerView(
                target: target,
                candidates: store.notes.filter {
                    $0.id != target.id && $0.kind != .digest
                        && !store.duplicateNoteIDs.contains($0.id)
                }
            ) { absorbed in
                mergeNotes(absorbed, into: target)
            }
        }
        .alert(
            "Move this note to the Trash?",
            isPresented: Binding(
                get: { notePendingDeletion != nil },
                set: { if !$0 { notePendingDeletion = nil } }
            )
        ) {
            Button("Move to Trash", role: .destructive) {
                if let note = notePendingDeletion {
                    _ = store.delete(note)
                }
                notePendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                notePendingDeletion = nil
            }
        } message: {
            Text(
                "The Markdown file moves to the Trash and can be restored from there. Unsaved edits and recovery copies for this note are also discarded. Kept audio remains available in Recovery until you delete it there."
            )
        }
        .sheet(isPresented: $showsAskSheet) {
            let sourceLibrary = askLibraryURL
            LibraryAskView(
                notes: store.notes,
                onSelectNote: { noteID in
                    showsAskSheet = false
                    guard sourceLibrary == store.storageURL.standardizedFileURL else { return }
                    requestNote(id: noteID)
                },
                onClose: { showsAskSheet = false }
            )
        }
        .alert(
            "Save your Markdown changes?",
            isPresented: $showsUnsavedChangesAlert
        ) {
            Button("Save") {
                saveDraftAndContinue()
            }
            Button("Discard Changes", role: .destructive) {
                markdownDraft.discardChanges()
                applyPendingSelection()
            }
            Button("Cancel", role: .cancel) {
                pendingSelection = nil
                pendingMergeTarget = nil
                pendingMergeGeneration = nil
                scope.settle(confirmed: false)
            }
        } message: {
            Text("This meeting has edits that haven’t been written to its Markdown file.")
        }
    }

    private func presentAskSheet() {
        guard libraryIsReadyForSheet() else { return }
        askLibraryURL = store.storageURL.standardizedFileURL
        showsAskSheet = true
    }

    private func presentCommandPalette() {
        guard commandPalette.canPresent, commandPaletteSheet.canPresent,
              libraryIsReadyForSheet() else { return }
        let presentationID = UUID()
        let sourceLibrary = store.storageURL.standardizedFileURL
        commandPaletteLibraryURL = sourceLibrary
        commandPalette.present()
        let presented = Binding(
            get: {
                commandPaletteSheet.isCurrent(presentationID) && commandPalette.isPresented
            },
            set: { isPresented in
                // A closing hosted view cannot dismiss a later presentation.
                guard commandPaletteSheet.isCurrent(presentationID),
                      !commandPalette.isShowingDestination else { return }
                commandPalette.isPresented = isPresented
                if !isPresented { commandPaletteSheet.dismiss(id: presentationID) }
            }
        )
        let content = CommandPaletteOpenActionsHost(openActions: openActions) { entries in
            CommandPaletteView(
                isPresented: presented,
                openActionEntries: entries,
                createNote: { template in createNote(from: template) },
                createWeeklyDigest: { createWeeklyDigest() },
                showAskSheet: presentAskSheet,
                presentQuickNote: { AppModel.shared.quickNote.present() },
                onSelectCommand: { command in
                    guard commandPaletteSheet.isCurrent(presentationID),
                          commandPalette.isPresented else { return .keepPresented }
                    guard sourceLibrary == store.storageURL.standardizedFileURL else {
                        invalidateCommandPalette()
                        return .keepPresented
                    }
                    if command.destination == .askLibrary {
                        if presentAskInCommandPalette(id: presentationID, sourceLibrary: sourceLibrary) {
                            return .keepPresented
                        }
                        commandPalette.cancel()
                        return .dismiss
                    }
                    commandPalette.select(command)
                    return .dismiss
                }
            )
        }
        .environmentObject(store)
        // Reached through the app model rather than an `@EnvironmentObject`
        // on `LibraryView`; see `MeetingPhaseObserver` for why this view must
        // not subscribe to the coordinator.
        .environmentObject(AppModel.shared.meeting)
        .environmentObject(shortcuts)

        let didPresent = commandPaletteSheet.present(
            id: presentationID,
            content: AnyView(content),
            onDismiss: {
                commandPaletteAskSession?.cancel()
                commandPaletteAskSession = nil
                let command = commandPalette.takeDismissedCommand()
                let originalLibrary = commandPaletteLibraryURL
                commandPaletteLibraryURL = nil
                guard originalLibrary == store.storageURL.standardizedFileURL else { return }
                command?.perform()
            },
            onInvalidation: {
                commandPaletteAskSession?.cancel()
                commandPaletteAskSession = nil
                commandPaletteLibraryURL = nil
                commandPalette.cancel()
            }
        )
        if !didPresent {
            commandPaletteLibraryURL = nil
            commandPalette.cancel()
            _ = commandPalette.takeDismissedCommand()
        }
    }

    private func presentAskInCommandPalette(id: UUID, sourceLibrary: URL) -> Bool {
        guard libraryIsReadyForSheet(), commandPalette.showDestination() else { return false }
        let session = LibraryAskSession()
        commandPaletteAskSession = session
        let content = LibraryAskStoreHost(
            store: store,
            session: session,
            onSelectNote: { noteID in
                closeCommandPaletteAsk(id: id, sourceLibrary: sourceLibrary, selecting: noteID)
            },
            onClose: { closeCommandPaletteAsk(id: id, sourceLibrary: sourceLibrary) }
        )
        return commandPaletteSheet.replaceContent(
            id: id, content: AnyView(content), title: "Ask your library"
        )
    }

    private func closeCommandPaletteAsk(
        id: UUID, sourceLibrary: URL, selecting noteID: MeetingNote.ID? = nil
    ) {
        guard commandPaletteSheet.isCurrent(id), commandPalette.isShowingDestination else { return }
        commandPaletteAskSession?.cancel()
        let command = noteID.map { noteID in
            CommandPaletteItem(
                id: "ask-citation-\(noteID.uuidString)", symbol: "doc.text",
                title: "Open cited note", subtitle: nil, destination: .note(noteID),
                perform: {
                    guard sourceLibrary == store.storageURL.standardizedFileURL else { return }
                    requestNote(id: noteID)
                }
            )
        }
        commandPalette.finishDestination(with: command)
        commandPaletteSheet.dismiss(id: id)
    }

    private func invalidateCommandPalette() {
        commandPaletteAskSession?.cancel()
        commandPaletteAskSession = nil
        commandPaletteLibraryURL = nil
        commandPalette.cancel()
        commandPaletteSheet.invalidate()
    }

    private func libraryIsReadyForSheet() -> Bool {
        guard !store.isLoading else {
            showCopyNotice("Your notes are still loading. Try again when loading finishes.", severity: .info)
            return false
        }
        // Check on invocation, not every view update or editor keystroke.
        guard LibrarySheetOwnership.matchesCurrentFolder(
            store.notes, directoryURL: store.storageURL
        ) else {
            showCopyNotice("The displayed notes belong to another folder. Retry loading this library before continuing.", severity: .info)
            return false
        }
        return true
    }

    /// Selection as the `List` drives it, routed through the same guard a
    /// click does. Without this the arrow keys could leave a pane holding
    /// unsaved Markdown without ever asking.
    private var listSelection: Binding<LibrarySelection?> {
        Binding(
            get: { selection },
            set: { requestSelection($0) }
        )
    }

    private var scopeSelection: Binding<Bool> {
        Binding(
            get: { todayOnly },
            set: { requestScopeChange($0) }
        )
    }

    private var sidebar: some View {
        List(selection: listSelection) {
            Section {
                Picker("Range", selection: scopeSelection) {
                    Text("All").tag(false)
                    Text("Today").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Show all notes or only today's")
            }

            prepSection
            openActionsSection
            LibraryRecoverySection(
                recovery: recovery,
                localeIdentifier: currentLocaleIdentifier
            )
            LibraryDraftRecoverySection()

            LibraryLiveSection(selection: selection)

            if let lastError = store.lastError {
                Section("Library status") {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(lastError, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(NookPalette.danger)
                        ForEach(store.loadIssues.prefix(3)) { issue in
                            Button {
                                store.reveal(issue)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(issue.fileURL.lastPathComponent)
                                        .lineLimit(1)
                                    Text(issue.message)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                        }
                        HStack {
                            Button("Retry") {
                                store.reload()
                            }
                            Button("Open notes folder") {
                                store.openStorageDirectory()
                            }
                        }
                        .font(.caption)
                    }
                    .padding(.vertical, 4)
                }
            }

            if store.notes.isEmpty, !store.isLoading {
                Section {
                    Label {
                        Text("Recorded meetings will appear here.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "text.page")
                            .foregroundStyle(NookPalette.accent)
                    }
                    .accessibilityLabel("No recorded meetings yet")
                }
            }

            // Keep search feedback in the list's flow. An empty-state overlay
            // covered standing sections and suggested the query was wrong
            // even when its matches were only outside the Today range.
            if searchController.isSearching, !store.isLoading {
                Section("Search results") {
                    ProgressView("Searching…")
                        .controlSize(.small)
                        .font(.caption)
                }
            } else if let message = LibrarySidebarPolicy.emptySearchMessage(
                query: searchText,
                todayOnly: todayOnly,
                isLoading: store.isLoading,
                isSearching: searchController.isSearching,
                hasVisibleNotes: !filteredNotes.isEmpty
            ) {
                Section("Search results") {
                    Label(message, systemImage: "magnifyingglass")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(message)
                }
            }

            ForEach(groupedNotes) { group in
                Section {
                    ForEach(group.notes, id: \.libraryIdentity) { note in
                        // Plain rows, not buttons: the List owns selection now,
                        // so arrow keys and type-select reach these the way
                        // they reach any other sidebar. A button in the row
                        // would swallow the click before the List saw it.
                        MeetingRow(
                            note: note,
                            isSelected: selection == .note(note.libraryIdentity),
                            showsFileIdentity: store.duplicateNoteIDs.contains(note.id)
                        )
                        .tag(LibrarySelection.note(note.libraryIdentity))
                        // Nook's own selection fill rather than the system's:
                        // it is a deeper blue chosen so white row text keeps
                        // AA contrast in an inactive window too.
                        .listRowBackground(
                            selection == .note(note.libraryIdentity)
                                ? NookPalette.sidebarSelection
                                : Color.clear
                        )
                        .contextMenu {
                            Button("Show in Finder") {
                                store.reveal(note)
                            }
                            Button("Copy Markdown") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(
                                    (try? store.rawMarkdown(for: note))
                                        ?? MarkdownCodec.encode(note),
                                    forType: .string
                                )
                                showCopyNotice("Markdown copied")
                            }
                            if note.kind != .digest {
                                Divider()
                                Button("Record into this note") {
                                    AppModel.shared.meeting.continueRecording(into: note)
                                }
                                .disabled(
                                    currentPhase.isRecording || isProcessing
                                        || store.duplicateNoteIDs.contains(note.id)
                                )
                                .help(
                                    "Appends the next recording to this note instead of creating a new one"
                                )
                                Button("Merge another note into this") {
                                    requestMergePicker(for: note)
                                }
                                .disabled(mergeTask != nil)
                                .disabled(isProcessing || store.duplicateNoteIDs.contains(note.id))
                            }
                            Divider()
                            Button("Move to Trash", role: .destructive) {
                                notePendingDeletion = note
                            }
                        }
                    }
                } header: {
                    sidebarSectionHeader(group.title)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Nook")
        .searchable(
            text: $searchText,
            placement: .sidebar,
            prompt: "Search every word"
        )
        .safeAreaInset(edge: .bottom, spacing: 0) {
            sidebarFooter
        }
    }

    private func sidebarSectionHeader(_ title: String) -> some View {
        librarySidebarSectionHeader(title)
    }

    /// A section header that folds its own section away.
    ///
    /// The disclosure is a real button rather than a tap on the label, so it
    /// has a hit target, a focus ring, and something for VoiceOver to say.
    private func collapsibleSectionHeader(
        _ title: String,
        isExpanded: Binding<Bool>
    ) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : NookMotion.quick) {
                isExpanded.wrappedValue.toggle()
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .rotationEffect(
                        .degrees(isExpanded.wrappedValue ? 90 : 0)
                    )
                    .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                sidebarSectionHeader(title)
                Spacer(minLength: 0)
            }
            .frame(minHeight: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isExpanded.wrappedValue ? "Hide \(title)" : "Show \(title)")
        .accessibilityLabel(title)
        .accessibilityValue(isExpanded.wrappedValue ? "Showing" : "Hidden")
        .accessibilityHint("Shows or hides this section")
    }

    /// A quiet pointer at the next sitting of a series with history. Time-
    /// sensitive, so it leads the sidebar; tapping opens the brief.
    @ViewBuilder
    private var prepSection: some View {
        if let brief = prep.current {
            Section {
                if prepExpanded {
                    PrepCard(
                        brief: brief,
                        isOpen: selection == .prep,
                        onOpen: { requestSelection(.prep) }
                    )
                    .tag(LibrarySelection.prep)
                }
            } header: {
                collapsibleSectionHeader("Prep", isExpanded: $prepExpanded)
            }
        }
    }

    /// Unfinished action items across the library, closest first.
    ///
    /// Capped rather than listed in full. Five of these plus a prep card
    /// filled the whole sidebar at the window's minimum height, so the notes
    /// the library exists to show never appeared without scrolling.
    @ViewBuilder
    private var openActionsSection: some View {
        let pool = Array(openActions.entries.prefix(8))
        let visible = LibrarySidebarPolicy.visibleOpenActions(
            pool,
            showingAll: openActionsShowAll
        )
        if !pool.isEmpty || openActions.lastError != nil {
            Section {
                if openActionsExpanded {
                    openActionRows(visible: visible, pool: pool)
                }
                if let message = openActions.lastError {
                    Label {
                        Text(message)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                        .font(.caption)
                        .foregroundStyle(NookPalette.danger)
                        .help(message)
                }
            } header: {
                collapsibleSectionHeader(
                    "Open actions",
                    isExpanded: $openActionsExpanded
                )
            }
        }
    }

    @ViewBuilder
    private func openActionRows(
        visible: [OpenAction],
        pool: [OpenAction]
    ) -> some View {
        Group {
            ForEach(visible) { entry in
                OpenActionRow(
                    entry: entry,
                    exported: openActions.exportedIDs.contains(entry.id),
                    onToggle: {
                        Task {
                            await openActions.toggle(entry, store: store)
                        }
                    },
                    onSelect: {
                        requestNote(id: entry.noteID)
                    },
                    onSendToReminders: {
                        let generation = store.storageGeneration
                        Task {
                            await openActions.sendToReminders(
                                entry, store: store, expectedGeneration: generation
                            )
                        }
                    },
                    onSetDue: { date in
                        Task {
                            await openActions.setDue(
                                entry,
                                on: date,
                                store: store
                            )
                        }
                    },
                    onClearDue: {
                        Task {
                            await openActions.setDue(
                                entry,
                                on: nil,
                                store: store
                            )
                        }
                    }
                )
            }
            if let disclosure = LibrarySidebarPolicy.disclosureLabel(
                pool: pool.count,
                visible: visible.count,
                showingAll: openActionsShowAll
            ) {
                Button(disclosure) {
                    withAnimation(reduceMotion ? nil : NookMotion.quick) {
                        openActionsShowAll.toggle()
                    }
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.medium))
                .foregroundStyle(NookPalette.accent)
                .frame(minHeight: 28)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            if openActionsShowAll,
               openActions.entries.count > pool.count {
                Text("\(openActions.entries.count - pool.count) more in the notes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if selection == .live {
            LiveMeetingView()
        } else if selection == .prep, let brief = prep.current {
            PrepBriefView(
                brief: brief,
                onSelectNote: { noteID in
                    requestNote(id: noteID)
                },
                // Named after the event so the note joins the rest of the
                // series rather than arriving as an unrelated "Meeting
                // Thu 7:34 PM". Withheld while a recording is already
                // running, which is the one case the coordinator refuses.
                onRecordSitting: canStartRecording
                    ? {
                        AppModel.shared.meeting.startCalendarMeeting(
                            title: brief.eventTitle
                        )
                    }
                    : nil
            )
        } else if let selectedNote {
            if store.duplicateNoteIDs.contains(selectedNote.id) {
                DuplicateNotePreview(
                    note: selectedNote,
                    retainedDraftText: markdownDraft.hasChanges
                        && markdownDraft.libraryIdentity == selectedNote.libraryIdentity
                        ? markdownDraft.rawMarkdown : nil,
                    onReloadLibrary: { store.reload() }
                )
                    .id(selectedNote.libraryIdentity)
            } else {
                MeetingDetailView(
                    note: selectedNote,
                    summarySession: store.summarySessions.session(for: selectedNote)
                )
                    .id(selectedNote.libraryIdentity)
            }
        } else if store.isLoading {
            libraryPlaceholder
        } else if case .copies(let id) = selection {
            DuplicateNoteChooser(
                notes: store.notes.filter { $0.id == id },
                onSelect: { requestSelection(.note($0)) }
            )
        } else {
            libraryPlaceholder
        }
    }

    @ViewBuilder
    private var libraryPlaceholder: some View {
        switch LibraryPlaceholderState.choose(
            isLoading: store.isLoading,
            hasNotes: !store.notes.isEmpty,
            todayOnly: todayOnly,
            hasVisibleNotes: !filteredNotes.isEmpty,
            hasSearch: !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            hasLoadError: store.lastError != nil
        ) {
        case .loading:
            VStack(spacing: 12) {
                ProgressView("Loading notes…")
                Text("Reading your local notes folder.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Loading notes from your local folder")
        case .loadFailure:
            ContentUnavailableView {
                Label("Your notes couldn’t be loaded", systemImage: "doc.badge.ellipsis")
            } description: {
                Text("Retry loading the library or inspect the notes folder in Finder.")
            } actions: {
                Button("Retry") { store.reload() }
                Button("Open Notes Folder") { store.openStorageDirectory() }
            }
        case .emptyToday:
            ContentUnavailableView {
                Label(
                    searchText.isEmpty ? "No notes today" : "No matching notes today",
                    systemImage: "calendar"
                )
            } description: {
                Text("Change the range to All to see your whole library.")
            } actions: {
                Button("Show All Notes") { requestScopeChange(false) }
            }
        case .noSearchMatches:
            ContentUnavailableView.search(text: searchText)
        case .emptyLibrary:
            EmptyLibraryView {
                AppModel.shared.meeting.startManualMeeting()
            }
        case .noSelection:
            ContentUnavailableView(
                "Choose a note",
                systemImage: "doc.text",
                description: Text("Select a note from the sidebar to review it.")
            )
        }
    }

    private var sidebarFooter: some View {
        HStack(spacing: 9) {
            Image(systemName: "lock.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(NookPalette.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("Local library")
                    .font(NookType.metadata)
                Text(store.storageURL.lastPathComponent)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                store.openStorageDirectory()
            } label: {
                Image(systemName: "folder")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .help("Open notes folder")
            .accessibilityLabel("Open notes folder")
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private var isProcessing: Bool {
        if case .processing = currentPhase { return true }
        return false
    }

    private var canStartRecording: Bool {
        !currentPhase.isRecording && !isProcessing
    }

    /// Changes what the detail pane shows, after settling what the pane it is
    /// leaving still owes.
    ///
    /// Both editors are considered, not only the Markdown one. A meeting
    /// starting by itself moves the selection to the live pane, so leaving My
    /// notes unaccounted for meant a recording could delete a half-typed
    /// follow-up while the user was still typing it.
    private func requestNote(id: MeetingNote.ID) {
        switch LibraryNoteResolution.resolve(id, in: store.notes) {
        case .unique(let identity): requestSelection(.note(identity))
        case .ambiguous: requestSelection(.copies(id))
        case .missing:
            showCopyNotice("This note is no longer in the selected folder.", severity: .info)
        }
    }

    private func requestScopeChange(_ requestedScope: Bool) {
        guard requestedScope != todayOnly, !showsUnsavedChangesAlert else { return }
        let target = selectionForScope(requestedScope)
        // The editor can stay put when its file also belongs to the new range.
        // There is no leave decision to ask about in that case.
        if target == selection {
            scope.request(requestedScope, needsConfirmation: false)
            refreshLibraryCacheIfNeeded()
        } else {
            requestSelection(target, changingScopeTo: requestedScope)
        }
    }

    private func selectionForScope(_ requestedScope: Bool) -> LibrarySelection? {
        switch selection {
        case .live, .prep:
            // These standing sections are visible in both date ranges.
            return selection
        default:
            let visible = LibraryNoteGrouping.filter(
                store.notes, todayOnly: requestedScope,
                matchingIDs: searchController.matchingIDs
            )
            let current: LibraryNoteIdentity?
            if case .note(let identity) = selection { current = identity }
            else { current = nil }
            return LibraryScopeState.visibleSelection(preserving: current, in: visible)
                .map(LibrarySelection.note)
        }
    }

    private func requestSelection(
        _ requestedSelection: LibrarySelection?,
        changingScopeTo requestedScope: Bool? = nil
    ) {
        // A background reload must not replace the destination of a question
        // the user is already answering, including its pending date range.
        guard let decision = LibraryLeaveGuard.decide(
            from: selection,
            to: requestedSelection,
            isConfirmingMarkdown: showsUnsavedChangesAlert,
            hasMarkdownChanges: markdownDraft.hasChanges,
            // Not `hasChanges`: a parked draft belongs to whichever note
            // refused it, which may not be the selected file, so leaving
            // must account for it explicitly rather than only for what is
            // live in the field right now.
            hasPersonalNotesChanges: personalNotesDraft.hasUnwrittenNotes
        ) else { return }
        switch decision {
        case .leave:
            if let requestedScope {
                scope.request(requestedScope, needsConfirmation: false)
                refreshLibraryCacheIfNeeded()
            }
            selection = requestedSelection
        case .saveFirst:
            // Written rather than queried: this field has one destination and
            // no discard of its own, so an alert would only ask the user to
            // confirm the obvious. A refusal from the store is different, and
            // it keeps the selection where it is so the words stay reachable.
            if let failure = personalNotesDraft.saveIfNeeded(store: store) {
                showCopyNotice(failure, severity: .failure)
                return
            }
            if let requestedScope {
                scope.request(requestedScope, needsConfirmation: false)
                refreshLibraryCacheIfNeeded()
            }
            selection = requestedSelection
        case .askAboutMarkdown:
            pendingSelection = requestedSelection
            if let requestedScope {
                scope.request(requestedScope, needsConfirmation: true)
            }
            showsUnsavedChangesAlert = true
        }
    }

    private func saveDraftAndContinue() {
        guard let identity = markdownDraft.libraryIdentity,
              let note = store.note(matching: identity)
        else {
            markdownDraft.statusMessage = "The original note is no longer in this folder."
            pendingSelection = nil
            pendingMergeTarget = nil
            pendingMergeGeneration = nil
            scope.settle(confirmed: false)
            return
        }
        do {
            try markdownDraft.save(note: note, store: store)
            applyPendingSelection()
        } catch {
            markdownDraft.statusMessage = error.localizedDescription
            pendingSelection = nil
            pendingMergeTarget = nil
            pendingMergeGeneration = nil
            scope.settle(confirmed: false)
        }
    }

    private func applyPendingSelection() {
        if pendingMergeTarget != nil,
           pendingMergeGeneration != store.storageGeneration {
            pendingMergeTarget = nil
            pendingMergeGeneration = nil
            pendingSelection = nil
            scope.settle(confirmed: false)
            showCopyNotice(NoteMergeError.libraryChanged.localizedDescription, severity: .failure)
            return
        }
        // The alert settled the Markdown question. The notes field is still
        // owed a write before the pane holding it is replaced; its words
        // outlive the view either way, so a refusal is reported rather than
        // blocking the selection the user already confirmed.
        if let failure = personalNotesDraft.saveIfNeeded(store: store) {
            showCopyNotice(failure, severity: .failure)
            if scope.pendingTodayOnly != nil || pendingMergeTarget != nil {
                scope.settle(confirmed: false)
                pendingSelection = nil
                pendingMergeTarget = nil
                pendingMergeGeneration = nil
                return
            }
        }
        if let identity = pendingMergeTarget {
            pendingMergeTarget = nil
            pendingMergeGeneration = nil
            pendingSelection = nil
            scope.settle(confirmed: false)
            openPreparedMergePicker(for: identity)
            return
        }
        // Saving can publish a different library snapshot. Resolve the range
        // again instead of selecting a file removed while the alert was open.
        let next: LibrarySelection?
        if let requestedScope = scope.pendingTodayOnly {
            next = selectionForScope(requestedScope)
        } else {
            next = pendingSelection
        }
        scope.settle(confirmed: true)
        refreshLibraryCacheIfNeeded()
        selection = next
        pendingSelection = nil
    }

    private func synchronizeSelectionWithSearch() {
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !searchController.isSearching
        else {
            return
        }
        if case .note(let selectedID) = selection,
           filteredNotes.contains(where: { $0.libraryIdentity == selectedID }) {
            return
        }
        requestSelection(filteredNotes.first.map { .note($0.libraryIdentity) })
    }

    private func showCopyNotice(
        _ message: String,
        severity: CopyConfirmationBanner.Severity = .success
    ) {
        let id = withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
            copyNotice.show(message, severity: severity)
        }
        guard let dwell = copyNotice.current?.expirationDelay else { return }
        Task {
            do { try await Task.sleep(for: .seconds(dwell)) }
            catch { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                copyNotice.expire(id: id)
            }
        }
    }

    private func createBlankNote() {
        createNote(from: .blank)
    }

    private func createNote(from template: NoteTemplate) {
        do {
            let note = try store.createTemplatedNote(from: template)
            requestSelection(.note(note.libraryIdentity))
        } catch {
            store.lastError = error.localizedDescription
        }
    }

    /// Compiles the week's meetings into one digest note and opens it.
    ///
    /// A week with nothing in it produces a file whose every count is zero,
    /// so the action refuses and says so instead of saving an empty digest.
    /// Clicking again for the same week updates that digest in place rather
    /// than leaving a new, near-duplicate file behind each time.
    private func createWeeklyDigest() {
        let now = Date()
        let notes = store.notes
        let libraryURL = store.storageURL.standardizedFileURL
        let omittedCount = DigestBuilder.omittedMeetingCount(from: notes, now: now)
        guard !DigestBuilder.coveredMeetings(from: notes, now: now).isEmpty else {
            showCopyNotice(
                omittedCount > 0
                    ? "No meetings can be included until the copies with a shared ID are reviewed."
                    : "No meetings from the last seven days to include yet.",
                severity: .info
            )
            return
        }
        let existing: MeetingNote?
        do {
            existing = try DigestBuilder.replacement(in: notes, now: now)
        } catch {
            showCopyNotice(error.localizedDescription, severity: .failure)
            return
        }
        Task {
            let digest = await DigestBuilder.build(
                from: notes,
                now: now,
                id: existing?.id ?? UUID(),
                fileURL: existing?.fileURL,
                replacing: existing
            )
            do {
                guard store.storageURL.standardizedFileURL == libraryURL else {
                    throw DigestBuildError.changedReplacement
                }
                try DigestBuilder.validateReplacement(existing, in: store.notes, now: now)
                let saved = try store.save(digest)
                requestSelection(.note(saved.libraryIdentity))
                if omittedCount > 0 {
                    showCopyNotice(LibraryNoteAggregation.omissionMessage, severity: .info)
                }
            } catch {
                showCopyNotice(
                    error.localizedDescription,
                    severity: .failure
                )
            }
        }
    }

    private func requestMergePicker(for note: MeetingNote) {
        guard mergeTask == nil, !showsUnsavedChangesAlert,
              libraryIsReadyForSheet() else { return }
        if markdownDraft.hasChanges {
            pendingMergeTarget = note.libraryIdentity
            pendingMergeGeneration = store.storageGeneration
            pendingSelection = nil
            showsUnsavedChangesAlert = true
            return
        }
        openPreparedMergePicker(for: note.libraryIdentity)
    }

    private func openPreparedMergePicker(for identity: LibraryNoteIdentity) {
        guard mergeTask == nil, libraryIsReadyForSheet() else { return }
        do {
            try NoteMergeWorkflow.settleDrafts(
                store: store, markdown: markdownDraft, personal: personalNotesDraft
            )
            guard let current = store.uniqueNote(id: identity.noteID),
                  current.libraryIdentity == identity else {
                throw NoteMergeError.sourceChanged
            }
            try store.validateMergeSource(
                current, directory: store.storageURL, generation: store.storageGeneration
            )
            // Saving an editor may have changed either merge input. Capture
            // the picker target only once those exact writes have completed.
            mergeTarget = current
        } catch {
            showCopyNotice(error.localizedDescription, severity: .failure)
        }
    }

    private func mergeNotes(_ absorbed: MeetingNote, into target: MeetingNote) {
        guard mergeTask == nil else { return }
        let generation = store.storageGeneration
        mergeIsStopping = false
        mergeTask = Task { @MainActor in
            defer {
                mergeTask = nil
                mergeIsStopping = false
            }
            do {
                let completion = try await mergeWorkflow.merge(
                    absorbed, into: target, store: store,
                    markdown: markdownDraft, personal: personalNotesDraft,
                    expectedGeneration: generation
                )
                if generation == store.storageGeneration,
                   store.note(matching: completion.saved.libraryIdentity) != nil {
                    requestSelection(.note(completion.saved.libraryIdentity))
                }
                showCopyNotice(
                    completion.notice,
                    severity: completion.hasPartialSuccess ? .failure : .success
                )
            } catch is CancellationError {
                showCopyNotice("Merge cancelled before the combined note was saved.", severity: .info)
            } catch {
                showCopyNotice(error.localizedDescription, severity: .failure)
            }
        }
    }

    private func cancelMerge() {
        guard let mergeTask else { return }
        mergeIsStopping = true
        mergeTask.cancel()
    }

    /// Picks a note when there is nothing else to show yet.
    ///
    /// Deliberately does not check `presentsLiveActivity` here: at the
    /// moment this runs, `MeetingPhaseObserver` may not have synced
    /// `currentPhase` from the coordinator yet, and reading it early would
    /// race. If a meeting really is already live, the observer's own
    /// `onAppear` sets `currentPhase` moments later, which is itself a
    /// change from its `.idle` default and fires
    /// `.onChange(of: currentPhase)` below, moving the selection to `.live`
    /// exactly the way any later phase transition does.
    private func chooseInitialSelection() {
        // Reopening the library restores its own dirty editor without asking
        // to leave it, but must not redirect an already presented question.
        guard !showsUnsavedChangesAlert else { return }
        if case .copies(let id) = selection,
           let unique = store.uniqueNote(id: id) {
            selection = .note(unique.libraryIdentity)
        }
        guard selection == nil else { return }
        selection = restoredOrFirstSelection(in: store.notes)
    }

    private func restoredOrFirstSelection(
        in notes: [MeetingNote]
    ) -> LibrarySelection? {
        let visible = LibraryNoteGrouping.filter(
            notes, todayOnly: todayOnly, matchingIDs: searchController.matchingIDs
        )
        if markdownDraft.hasChanges,
           let identity = markdownDraft.libraryIdentity,
           notes.contains(where: { $0.libraryIdentity == identity }) {
            return .note(identity)
        }
        return visible.first.map { .note($0.libraryIdentity) }
    }
}

/// Mirrors `meeting.phase` and `meeting.localeIdentifier` into plain `@State`
/// values on `LibraryView`.
///
/// `MeetingCoordinator` is one `ObservableObject` that publishes phase
/// alongside `isPaused`, `panelMode`, `liveNotes` and the live summary
/// state while a meeting records (its audio level, elapsed clock and live
/// transcript have since moved to `MeetingLiveSignals`, which only the leaf
/// views drawing them observe). Holding `@EnvironmentObject` directly on
/// `LibraryView` subscribes to all of that at once, since Combine's
/// `objectWillChange` does not distinguish which published property
/// changed: every keystroke in the live notes would invalidate the whole
/// view, including the sidebar's note grouping and filtering, for a phase
/// that changes only a handful of times per meeting. This bridge is the one
/// place that pays that rate; its own body does nothing but compare and
/// store a value, so the cost of absorbing those changes here is negligible.
///
/// Anything else `LibraryView` needs from the coordinator must come through
/// this bridge too, never through a subscription on the view itself. 1.19.0
/// added one back to read the transcription locale and the Library window
/// spent most of a recording re-laying itself out for meter ticks.
private struct MeetingPhaseObserver: View {
    @EnvironmentObject private var meeting: MeetingCoordinator
    @Binding var phase: MeetingPhase
    @Binding var localeIdentifier: String

    var body: some View {
        Color.clear
            .onAppear {
                phase = meeting.phase
                localeIdentifier = meeting.localeIdentifier
            }
            .onChange(of: meeting.phase) { _, newValue in phase = newValue }
            .onChange(of: meeting.localeIdentifier) { _, newValue in
                localeIdentifier = newValue
            }
    }
}

/// The toolbar's recording controls, isolated into their own view so only
/// this small piece re-renders on the coordinator's meter ticks; `LibraryView`
/// itself no longer holds `MeetingCoordinator` at all (see
/// `MeetingPhaseObserver`).
private struct LibraryRecordingToolbar: View {
    @EnvironmentObject private var meeting: MeetingCoordinator
    @EnvironmentObject private var shortcuts: ShortcutStore
    let createNote: (NoteTemplate) -> Void

    var body: some View {
        if meeting.phase.isRecording {
            Button {
                meeting.togglePause()
            } label: {
                Label(
                    meeting.isPaused ? "Resume" : "Pause",
                    systemImage: meeting.isPaused
                        ? "play.fill"
                        : "pause.fill"
                )
            }
            .disabled(meeting.pauseTransitionInFlight)

            Button {
                meeting.stopRecording()
            } label: {
                Label("Finish", systemImage: "stop.fill")
            }
            .foregroundStyle(NookPalette.danger)
            .disabled(meeting.pauseTransitionInFlight)
            .help("Stop recording and create notes")
        } else {
            Menu {
                ForEach(NoteTemplate.allCases) { template in
                    Button(template.menuTitle) {
                        createNote(template)
                    }
                }
            } label: {
                Label("New note", systemImage: "square.and.pencil")
            }
            .disabled(isProcessing)
            .keyboardShortcut(
                shortcuts.binding(for: .newNote).keyEquivalent,
                modifiers: shortcuts.binding(for: .newNote).eventModifiers
            )
            .help("Create a local note from a starting point")
        }
    }

    private var isProcessing: Bool {
        if case .processing = meeting.phase { return true }
        return false
    }
}

/// The sidebar's "Now" row, isolated into its own view so only this small
/// section re-renders on the coordinator's changes (phase, pause, live
/// notes) instead of the sidebar's note grouping and filtering above it.
/// The row's elapsed clock ticks once a second from `MeetingLiveSignals`,
/// which `LiveSidebarRow` observes on its own; this section must not read
/// the coordinator's `elapsed` forwarder, which does not subscribe a view.
private struct LibraryLiveSection: View {
    @EnvironmentObject private var meeting: MeetingCoordinator
    let selection: LibrarySelection?

    var body: some View {
        if meeting.phase.presentsLiveActivity {
            Section {
                LiveSidebarRow(
                    phase: meeting.phase,
                    live: meeting.live,
                    isPaused: meeting.isPaused,
                    isSelected: selection == .live
                )
                .tag(LibrarySelection.live)
                .listRowBackground(
                    selection == .live
                        ? NookPalette.sidebarSelection
                        : Color.clear
                )
            } header: {
                librarySidebarSectionHeader("Now")
            }
        }
    }
}

/// A quiet, actionable place for recordings that never became notes.
///
/// Recovery belongs beside the library's notes because that is where a person
/// will look for something that was kept but never written up. It remains a
/// small section, present only while there is something to act on, and keeps
/// its destructive confirmation local to the controls that can trigger it.
private struct LibraryRecoverySection: View {
    @ObservedObject var recovery: RecordingRecovery
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let localeIdentifier: String
    @State private var pendingDeletion: OrphanedRecording?
    @State private var showsAll = false

    private static let visibleOrphanLimit = 3

    @ViewBuilder
    var body: some View {
        if !recovery.orphans.isEmpty || !recovery.cleanupFailures.isEmpty {
            Section {
                ForEach(visibleOrphans) { orphan in
                    recoveryRow(for: orphan)
                }

                ForEach(recovery.cleanupFailures) { failure in
                    cleanupFailureRow(for: failure)
                }

                if recovery.orphans.count > visibleOrphans.count {
                    Button("Show \(recovery.orphans.count - visibleOrphans.count) more recordings") {
                        withAnimation(NookMotion.quickAnimation(reduceMotion: reduceMotion)) {
                            showsAll = true
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(NookPalette.accent)
                    .frame(minHeight: 28)
                    .contentShape(Rectangle())
                    .accessibilityHint("Shows the remaining recordings that need attention")
                } else if showsAll,
                          recovery.orphans.count > Self.visibleOrphanLimit {
                    Button("Show fewer recordings") {
                        withAnimation(NookMotion.quickAnimation(reduceMotion: reduceMotion)) {
                            showsAll = false
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(NookPalette.accent)
                    .frame(minHeight: 28)
                    .contentShape(Rectangle())
                }

                if let message = recovery.message {
                    Label {
                        Text(message)
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "info.circle")
                    }
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(message)
                }

                if recovery.isWorking {
                    HStack(spacing: NookSpacing.small) {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.7)
                        Text(
                            "Working through that recording locally. This can take a while."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: {
                HStack(spacing: NookSpacing.xSmall) {
                    Label(
                        "Recordings need attention",
                        systemImage: "waveform.badge.exclamationmark"
                    )
                    Spacer(minLength: NookSpacing.small)
                    Text(recovery.totalSizeLabel)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Recordings need attention")
                .accessibilityValue(recoverySummary)
            } footer: {
                Text(recoveryFooter)
            }
            .alert(
                "Move this recording to the Trash?",
                isPresented: Binding(
                    get: { pendingDeletion != nil },
                    set: { if !$0 { pendingDeletion = nil } }
                )
            ) {
                Button("Move to Trash", role: .destructive) {
                    if let orphan = pendingDeletion {
                        recovery.delete(orphan)
                    }
                    pendingDeletion = nil
                }
                Button("Cancel", role: .cancel) {
                    pendingDeletion = nil
                }
            } message: {
                Text(
                    "This recording is the only copy of that conversation. It moves to the Trash and can be restored from there, or you can recover it as a note first."
                )
            }
        }
    }

    private func recoveryRow(for orphan: OrphanedRecording) -> some View {
        VStack(alignment: .leading, spacing: NookSpacing.xSmall) {
            HStack(alignment: .firstTextBaseline, spacing: NookSpacing.small) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(orphan.dateLabel)
                        .font(.callout.weight(.medium))
                    HStack(spacing: NookSpacing.xSmall) {
                        Text(orphan.sizeLabel)
                        if orphan.isAudioOnly {
                            Text("·")
                            Text("Audio only")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: NookSpacing.xSmall)
            }

            HStack(spacing: NookSpacing.small) {
                Button("Recover") {
                    recovery.recover(
                        orphan,
                        localeIdentifier: localeIdentifier
                    )
                }
                .controlSize(.small)
                .disabled(recovery.isWorking)
                .help("Recover this recording as a note.")
                .accessibilityLabel(
                    "Recover recording from \(orphan.dateLabel) as a note"
                )

                Button("Reveal") {
                    recovery.reveal(orphan)
                }
                .controlSize(.small)
                .help("Reveal this recording in Finder.")
                .accessibilityLabel(
                    "Reveal recording from \(orphan.dateLabel) in Finder"
                )

                Button("Delete", role: .destructive) {
                    pendingDeletion = orphan
                }
                .controlSize(.small)
                .disabled(recovery.isWorking)
                .help("Move this recording to the Trash.")
                .accessibilityLabel(
                    "Move recording from \(orphan.dateLabel) to the Trash"
                )
            }
        }
        .padding(.vertical, NookSpacing.xSmall)
        .accessibilityElement(children: .contain)
    }

    private func cleanupFailureRow(
        for failure: RecoveryCleanupFailure
    ) -> some View {
        VStack(alignment: .leading, spacing: NookSpacing.xSmall) {
            HStack(alignment: .firstTextBaseline, spacing: NookSpacing.small) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(NookPalette.warning)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Saved note: \(failure.noteTitle)")
                        .font(.callout.weight(.medium))
                    Text(
                        "\(failure.dateLabel) · \(failure.sizeLabel) still in Nook"
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    Text("Some files could not be removed after recovery.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: NookSpacing.xSmall)
            }

            Button("Reveal files") {
                recovery.reveal(failure)
            }
            .controlSize(.small)
            .help("Reveal the files that could not be removed in Finder.")
            .accessibilityLabel(
                "Reveal files left after recovering \(failure.noteTitle) in Finder"
            )
        }
        .padding(.vertical, NookSpacing.xSmall)
        .accessibilityElement(children: .contain)
    }

    private var visibleOrphans: [OrphanedRecording] {
        showsAll
            ? recovery.orphans
            : Array(recovery.orphans.prefix(Self.visibleOrphanLimit))
    }

    private var recordingCountLabel: String {
        let count = recovery.orphans.count
        return "\(count) recording\(count == 1 ? "" : "s")"
    }

    private var recoverySummary: String {
        var parts: [String] = []
        if !recovery.orphans.isEmpty {
            parts.append("\(recordingCountLabel) without notes")
        }
        if !recovery.cleanupFailures.isEmpty {
            let count = recovery.cleanupFailures.count
            parts.append(
                "\(count) cleanup issue\(count == 1 ? "" : "s")"
            )
        }
        parts.append("\(recovery.totalSizeLabel) total")
        return parts.joined(separator: ", ")
    }

    private var recoveryContext: String {
        if !recovery.cleanupFailures.isEmpty {
            if recovery.orphans.isEmpty {
                return recovery.cleanupFailures.count == 1
                    ? "A note was saved, but one or more files from its recovery could not be removed."
                    : "Notes were saved, but some recovery files could not be removed."
            }
            return "Some recovered notes still have files that could not be removed."
        }
        if recovery.orphans.count == 1 {
            return "Nook has no matching note for this recording. Processing may have been interrupted, or the original note may have been deleted."
        }
        return "Nook has no matching notes for these recordings. Processing may have been interrupted, or the original notes may have been deleted."
    }

    private var recoveryFooter: String {
        var text = recoveryContext
        if !recovery.orphans.isEmpty {
            text += " Recover a recording as a note, reveal its files, or move it to the Trash."
        }
        if !recovery.cleanupFailures.isEmpty {
            text += " Reveal the remaining files to inspect them in Finder."
        }
        return text
    }
}

/// Shared header styling for `LibraryView`'s own sections and for
/// `LibraryLiveSection`, which cannot call a private method on the view.
private func librarySidebarSectionHeader(_ title: String) -> some View {
    Text(title)
        .font(.caption.weight(.semibold))
        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
        .textCase(nil)
}

private struct MeetingRow: View {
    let note: MeetingNote
    let isSelected: Bool
    var showsFileIdentity = false

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            sourceMark

            VStack(alignment: .leading, spacing: 4) {
                Text(note.title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(primaryTextColor)
                    .lineLimit(1)

                if showsFileIdentity, let file = note.fileURL {
                    Label(file.lastPathComponent, systemImage: "doc.on.doc")
                        .font(.caption)
                        .foregroundStyle(secondaryTextColor)
                        .lineLimit(2)
                        .help(file.path)
                }

                if !note.summary.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty {
                        Text(note.summary)
                            .font(NookType.caption)
                            .foregroundStyle(secondaryTextColor)
                            .lineLimit(1)
                }

                HStack(spacing: 5) {
                    Text(
                        note.startedAt,
                        format: .dateTime
                            .hour()
                            .minute()
                    )
                    Text("·")
                    Text(note.durationLabel)
                    if !note.sourceApp.isEmpty {
                        Text("·")
                        Text(note.sourceApp)
                            .lineLimit(1)
                    }
                }
                .font(.caption2.weight(.medium))
                .foregroundStyle(secondaryTextColor)
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }

    private var primaryTextColor: Color {
        Color(
            nsColor: isSelected
                ? .alternateSelectedControlTextColor
                : .labelColor
        )
    }

    private var secondaryTextColor: Color {
        if isSelected {
            return Color(nsColor: .alternateSelectedControlTextColor)
                .opacity(0.78)
        }
        return Color(nsColor: .secondaryLabelColor)
    }

    private var sourceMark: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(
                    isSelected
                        ? Color.white.opacity(0.14)
                        : sourceTint.opacity(0.12)
                )
            Image(systemName: sourceSymbol)
                .font(NookType.bodyEmphasized)
                .foregroundStyle(isSelected ? Color.white : sourceTint)
        }
        .frame(width: 29, height: 29)
        .accessibilityHidden(true)
    }

    private var sourceTint: Color {
        return NookPalette.accent
    }

    private var sourceSymbol: String {
        let source = note.sourceApp.lowercased()
        if source.contains("teams") { return "person.3.fill" }
        if source.contains("zoom") { return "video.fill" }
        if source.contains("meet") { return "video.bubble.fill" }
        return "quote.bubble.fill"
    }
}

/// Observes `MeetingLiveSignals` for the elapsed clock in its detail line,
/// so that object's meter, caption and clock publishes re-render this row
/// alone rather than the sidebar around it.
private struct LiveSidebarRow: View {
    let phase: MeetingPhase
    @ObservedObject var live: MeetingLiveSignals
    let isPaused: Bool
    let isSelected: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(
                        isSelected
                            ? Color.white.opacity(0.14)
                            : tint.opacity(0.14)
                    )
                Image(systemName: symbol)
                    .font(NookType.bodyEmphasized)
                    .foregroundStyle(isSelected ? Color.white : tint)
                    .symbolEffect(
                        .pulse,
                        isActive: phase.isRecording
                            && !isPaused
                            && !reduceMotion
                    )
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(NookType.control)
                    .foregroundStyle(
                        isSelected
                            ? Color.white
                            : Color(nsColor: .labelColor)
                    )
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(
                        isSelected
                            ? Color.white.opacity(0.82)
                            : Color(nsColor: .secondaryLabelColor)
                    )
            }
            Spacer()
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(detail)")
    }

    private var title: String {
        switch phase {
        case .recording(let title, _): title
        case .processing: "Creating your notes"
        case .failed: "Recording needs attention"
        default: "Live meeting"
        }
    }

    private var detail: String {
        if phase.isRecording {
            return "\(isPaused ? "Paused" : "Live") · \(NookElapsedTime.clock(live.elapsed))"
        }
        if case .processing(let step) = phase { return step.rawValue }
        return "Open for details"
    }

    private var symbol: String {
        switch phase {
        case .recording: isPaused ? "pause.fill" : "waveform"
        case .failed: "exclamationmark"
        default: "sparkles"
        }
    }

    private var tint: Color {
        switch phase {
        case .recording:
            isPaused ? NookPalette.warning : NookPalette.danger
        case .failed: NookPalette.accent
        default: NookPalette.voiceSelf
        }
    }
}

private struct EmptyLibraryView: View {
    let startRecording: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasAppeared = false

    var body: some View {
        ZStack {
            NookAmbientBackground()

            VStack(spacing: 20) {
                NookPresence(state: .resting, size: 68)

                VStack(spacing: 9) {
                    Text("Meetings, tucked away.")
                        .font(.title2.weight(.semibold))
                    Text("When a meeting begins, Nook keeps up with the words and tucks the useful parts into a local Markdown note.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                        .frame(maxWidth: 470)
                }

                Button(action: startRecording) {
                    Label("Record your first meeting", systemImage: "waveform.badge.mic")
                        .padding(.horizontal, 5)
                }
                .buttonStyle(
                    NookButtonStyle(
                        tint: NookPalette.accent,
                        isProminent: true
                    )
                )
                .controlSize(.large)
            }
            .padding(50)
            .opacity(hasAppeared ? 1 : 0)
            .offset(y: hasAppeared ? 0 : 8)
        }
        .onAppear {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.65)) {
                hasAppeared = true
            }
        }
    }
}

/// One unfinished action item in the sidebar: tickable, jumpable, exportable,
/// and datable so follow-through has a clock on it.
private struct OpenActionRow: View {
    let entry: OpenAction
    let exported: Bool
    let onToggle: () -> Void
    let onSelect: () -> Void
    let onSendToReminders: () -> Void
    let onSetDue: (Date) -> Void
    let onClearDue: () -> Void

    @State private var showsDuePicker = false
    @State private var pickerDate = Date().addingTimeInterval(86_400)

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Button(action: onToggle) {
                Image(systemName: "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(NookPalette.accent)
                    // The glyph stays small; the frame is the hit target.
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Mark as done")
            .accessibilityLabel("Mark \(entry.displayText) as done")

            // A real button, not a tap gesture on a stack. The gesture was
            // invisible to VoiceOver and to the keyboard, so the only way to
            // open the note from here was the pointer.
            Button(action: onSelect) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.displayText)
                        .font(.callout)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 6) {
                        Text(entry.noteTitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if !dueChip.text.isEmpty {
                            Text(dueChip.text)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(
                                    dueChip.isOverdue
                                        ? NookPalette.danger : .secondary
                                )
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(
                                    Capsule().fill(
                                        (dueChip.isOverdue
                                            ? NookPalette.danger
                                            : Color.secondary).opacity(0.12)
                                    )
                                )
                                .accessibilityLabel(
                                    dueChip.isOverdue
                                        ? "Overdue: \(dueChip.text)"
                                        : dueChip.text
                                )
                        }
                    }
                }
                .frame(minHeight: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open note")
        }
        .padding(.vertical, 3)
        .contextMenu {
            Button {
                onSendToReminders()
            } label: {
                Label(
                    exported ? "Sent to Reminders" : "Send to Reminders",
                    systemImage: exported
                        ? "checkmark.circle" : "square.and.arrow.up"
                )
            }
            .disabled(exported)

            Divider()
            Button("Due today") { onSetDue(Calendar.current.startOfDay(for: Date())) }
            Button("Due tomorrow") { onSetDue(tomorrow()) }
            Button("Due next week") { onSetDue(nextWeek()) }
            Button("Choose date…") {
                pickerDate = entry.dueDate ?? tomorrow()
                showsDuePicker = true
            }
            if entry.dueDate != nil {
                Button("Remove due date", role: .destructive) {
                    onClearDue()
                }
            }
        }
        .popover(isPresented: $showsDuePicker) {
            VStack(alignment: .leading, spacing: 12) {
                DatePicker(
                    "Due",
                    selection: $pickerDate,
                    displayedComponents: [.date]
                )
                HStack {
                    Spacer()
                    Button("Cancel") { showsDuePicker = false }
                    Button("Set due date") {
                        showsDuePicker = false
                        onSetDue(Calendar.current.startOfDay(for: pickerDate))
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(14)
            .frame(width: 260)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the meeting note")
        // The row reads as one element, so VoiceOver reaches the tick, the
        // note, and the export through actions instead of a flattened,
        // unlabeled blob.
        .accessibilityAction(named: "Open note") { onSelect() }
        .accessibilityAction(named: "Mark as done") { onToggle() }
        .accessibilityAction(named: "Send to Reminders") {
            onSendToReminders()
        }
    }

    private var dueChip: (text: String, isOverdue: Bool) {
        entry.dueChip()
    }

    private func tomorrow() -> Date {
        Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))!
    }

    private func nextWeek() -> Date {
        Calendar.current.date(byAdding: .day, value: 7, to: Calendar.current.startOfDay(for: Date()))!
    }
}

/// Picks which saved note folds into the merge target.
///
/// Deliberately plain: a list, a selection, and two verbs. The destructive
/// half is stated in the button, and the confirmation copy after the merge
/// reports anything the user should know about kept audio.
private struct NoteMergePickerView: View {
    let target: MeetingNote
    let candidates: [MeetingNote]
    let onMerge: (MeetingNote) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: MeetingNote.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Merge into \"\(target.title)\"")
                    .font(NookType.title)
                    .lineLimit(2)
                Text(
                    "Both notes become one. Transcripts, moments, personal notes, and action items are combined, kept audio is joined into a single recording, and the summary is written again from everything. A title you typed is kept. The combined note is filed under whichever meeting started first, and the other note moves to the Trash."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            List(candidates, selection: $selectedID) { candidate in
                HStack(spacing: 9) {
                    Image(systemName: candidate.kind.symbol)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(candidate.title)
                            .lineLimit(1)
                        Text(
                            candidate.startedAt.formatted(
                                date: .abbreviated,
                                time: .shortened
                            )
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .tag(candidate.id)
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .frame(minHeight: 220)

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Merge Note") {
                    guard
                        let absorbed = candidates.first(
                            where: { $0.id == selectedID }
                        )
                    else { return }
                    dismiss()
                    onMerge(absorbed)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedID == nil)
            }
        }
        .padding(22)
        .frame(width: 460)
    }
}
