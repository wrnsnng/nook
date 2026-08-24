import AppKit
import SwiftUI

private enum LibrarySelection: Hashable {
    case live
    case note(MeetingNote.ID)
    case prep
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
        matchingIDs: Set<MeetingNote.ID>?,
        calendar: Calendar = .current
    ) -> [MeetingNote] {
        var result = notes
        if todayOnly {
            result = result.filter { calendar.isDateInToday($0.startedAt) }
        }
        guard let matchingIDs else { return result }
        return result.filter { matchingIDs.contains($0.id) }
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
/// The fingerprint folds in `id`, `fileModified`, and `title`, not just the
/// newest `fileModified` across the library. The latest-modified-date alone
/// went stale whenever an edit's new timestamp did not change the overall
/// maximum: two saves landing in the same tick, or a volume whose
/// modification dates only carry second granularity, both leave the max
/// looking identical to the last one cached even though a note's title (say)
/// really did change. Folding every note's own triple in means a change to
/// *any* note is visible in the fingerprint regardless of where the library's
/// maximum sits.
struct LibraryGroupingCacheKey: Equatable {
    let noteCount: Int
    let notesFingerprint: Int
    let matchingIDs: Set<MeetingNote.ID>?
    let todayOnly: Bool
    let day: Date

    init(
        notes: [MeetingNote],
        matchingIDs: Set<MeetingNote.ID>?,
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
            hasher.combine(note.id)
            hasher.combine(note.fileModified)
            hasher.combine(note.title)
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

struct LibraryView: View {
    @EnvironmentObject private var store: MarkdownStore
    @EnvironmentObject private var markdownDraft: MarkdownDraftController
    @EnvironmentObject private var personalNotesDraft: PersonalNotesDraftController
    @EnvironmentObject private var prep: PrepBriefController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var searchController = LibrarySearchController()
    @StateObject private var openActions = OpenActionsController()
    @State private var selection: LibrarySelection?
    @State private var searchText = ""
    @State private var pendingSelection: LibrarySelection?
    @State private var showsUnsavedChangesAlert = false
    @State private var copyNotice: String?
    @State private var copyNoticeSeverity: CopyConfirmationBanner.Severity = .success
    @State private var showsAskSheet = false
    /// The note a second note is being merged into, when the picker shows.
    @State private var mergeTarget: MeetingNote?
    /// The note awaiting Trash confirmation.
    @State private var notePendingDeletion: MeetingNote?
    @State private var showsCommandPalette = false
    /// Sidebar scope: the whole library or just today's capture.
    @State private var todayOnly = false
    /// Mirrors `meeting.phase`, kept current by `MeetingPhaseObserver`. See
    /// that type for why this view reads a plain, rarely-changing `@State`
    /// value here rather than holding the coordinator itself.
    @State private var currentPhase: MeetingPhase = .idle
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
            initialValue: initialNoteID.map(LibrarySelection.note)
        )
    }

    /// The filtered notes as of the last cache refresh. See
    /// `LibraryGroupingCacheKey`.
    private var filteredNotes: [MeetingNote] { cachedFilteredNotes }

    /// The grouped notes as of the last cache refresh. See
    /// `LibraryGroupingCacheKey`.
    private var groupedNotes: [LibraryNoteGroup] { cachedGroupedNotes }

    private var selectedNote: MeetingNote? {
        guard case .note(let id) = selection else { return nil }
        return store.notes.first(where: { $0.id == id })
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

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 260, ideal: 304, max: 380)
        } detail: {
            detail
        }
        .tint(NookPalette.accent)
        .background {
            // See `MeetingPhaseObserver`: this is the only place in the view
            // that subscribes to the coordinator, so meter ticks land here
            // instead of on the sidebar's grouping and filtering.
            MeetingPhaseObserver(phase: $currentPhase)
            // A hidden accelerator so ⌘K reaches the palette from anywhere in
            // the window, toolbar focus included.
            Button("Command Palette") { showsCommandPalette = true }
                .keyboardShortcut("k", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .overlay {
            if showsCommandPalette {
                CommandPaletteView(
                    isPresented: $showsCommandPalette,
                    openActionEntries: Array(openActions.entries.prefix(6)),
                    createNote: { template in
                        createNote(from: template)
                    },
                    createWeeklyDigest: { createWeeklyDigest() },
                    showAskSheet: { showsAskSheet = true },
                    presentQuickNote: { AppModel.shared.quickNote.present() }
                )
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showsAskSheet = true
                } label: {
                    Label("Ask your library", systemImage: "sparkle.magnifyingglass")
                }
                .help("Ask a question across all your notes")

                Button {
                    createWeeklyDigest()
                } label: {
                    Label("Create weekly digest", systemImage: "newspaper")
                }
                .help("Compile this week's meetings into one note")

                LibraryRecordingToolbar(createNote: createNote)
            }
        }
        .overlay(alignment: .top) {
            if let copyNotice {
                CopyConfirmationBanner(message: copyNotice, severity: copyNoticeSeverity)
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .onAppear {
            store.reload()
            searchController.update(query: searchText, notes: store.notes)
            refreshLibraryCacheIfNeeded()
            chooseInitialSelection()
            Task { await openActions.refresh(store: store) }
        }
        .onChange(of: currentGroupingCacheKey) { _, _ in
            refreshLibraryCacheIfNeeded()
        }
        .onChange(of: store.notes) { _, _ in
            Task { await openActions.refresh(store: store) }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .nookOpenMeetingNote)
        ) { notification in
            guard let requestedID = notification.object as? MeetingNote.ID else {
                return
            }
            guard store.notes.contains(where: { $0.id == requestedID }) else {
                return
            }
            requestSelection(.note(requestedID))
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
                selection = restoredOrFirstSelection(in: store.notes)
            }
        }
        .onChange(of: store.notes) { _, notes in
            searchController.update(query: searchText, notes: notes)
            guard !notes.isEmpty else {
                if !presentsLiveActivity { selection = nil }
                return
            }
            if case .note(let id) = selection,
               !notes.contains(where: { $0.id == id }) {
                selection = restoredOrFirstSelection(in: notes)
            } else if selection == nil, !presentsLiveActivity {
                selection = restoredOrFirstSelection(in: notes)
            }
        }
        .onChange(of: searchText) { _, query in
            searchController.update(query: query, notes: store.notes)
        }
        .onChange(of: searchController.matchingIDs) { _, _ in
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
                    selection = restoredOrFirstSelection(in: store.notes)
                case .idle:
                    if selection == .live {
                        selection = restoredOrFirstSelection(in: store.notes)
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
        .sheet(item: $mergeTarget) { target in
            NoteMergePickerView(
                target: target,
                candidates: store.notes.filter {
                    $0.id != target.id && $0.kind != .digest
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
                "The Markdown file moves to the Trash and can be restored from there. Kept audio stays until its retention expires."
            )
        }
        .sheet(isPresented: $showsAskSheet) {
            LibraryAskView(
                notes: store.notes,
                onSelectNote: { noteID in
                    showsAskSheet = false
                    requestSelection(.note(noteID))
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
            }
        } message: {
            Text("This meeting has edits that haven’t been written to its Markdown file.")
        }
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

    private var sidebar: some View {
        List(selection: listSelection) {
            Section {
                Picker("Range", selection: $todayOnly) {
                    Text("All").tag(false)
                    Text("Today").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Show all notes or only today's")
            }

            prepSection
            openActionsSection

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

            ForEach(groupedNotes) { group in
                Section {
                    ForEach(group.notes) { note in
                        // Plain rows, not buttons: the List owns selection now,
                        // so arrow keys and type-select reach these the way
                        // they reach any other sidebar. A button in the row
                        // would swallow the click before the List saw it.
                        MeetingRow(
                            note: note,
                            isSelected: selection == .note(note.id)
                        )
                        .tag(LibrarySelection.note(note.id))
                        // Nook's own selection fill rather than the system's:
                        // it is a deeper blue chosen so white row text keeps
                        // AA contrast in an inactive window too.
                        .listRowBackground(
                            selection == .note(note.id)
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
                                )
                                .help(
                                    "Appends the next recording to this note instead of creating a new one"
                                )
                                Button("Merge another note into this") {
                                    mergeTarget = note
                                }
                                .disabled(isProcessing)
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
        .overlay {
            if searchController.isSearching {
                ProgressView("Searching…")
                    .controlSize(.small)
            } else if !searchText.isEmpty, filteredNotes.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
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
        if !pool.isEmpty {
            Section {
                if openActionsExpanded {
                    openActionRows(visible: visible, pool: pool)
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
                        requestSelection(.note(entry.noteID))
                    },
                    onSendToReminders: {
                        Task {
                            await openActions.sendToReminders(entry)
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
            if let message = openActions.lastError {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(NookPalette.danger)
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
                    requestSelection(.note(noteID))
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
            MeetingDetailView(note: selectedNote)
                .id(selectedNote.id)
        } else {
            EmptyLibraryView {
                AppModel.shared.meeting.startManualMeeting()
            }
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
    private func requestSelection(_ requestedSelection: LibrarySelection?) {
        guard requestedSelection != selection else { return }
        let selectedID: MeetingNote.ID?
        if case .note(let id) = selection {
            selectedID = id
        } else {
            selectedID = nil
        }

        switch LibraryLeaveGuard.decide(
            hasMarkdownChanges: markdownDraft.hasChanges
                && markdownDraft.noteID == selectedID,
            // Not `hasChanges`: a parked draft belongs to whichever note
            // refused it, which may not be `selectedID` at all, so leaving
            // must account for it explicitly rather than only for what is
            // live in the field right now.
            hasPersonalNotesChanges: personalNotesDraft.hasUnwrittenNotes
        ) {
        case .leave:
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
            selection = requestedSelection
        case .askAboutMarkdown:
            pendingSelection = requestedSelection
            showsUnsavedChangesAlert = true
        }
    }

    private func saveDraftAndContinue() {
        guard let noteID = markdownDraft.noteID,
              let note = store.notes.first(where: { $0.id == noteID })
        else {
            markdownDraft.statusMessage = "The original note is no longer in this folder."
            pendingSelection = nil
            return
        }
        do {
            try markdownDraft.save(note: note, store: store)
            applyPendingSelection()
        } catch {
            markdownDraft.statusMessage = error.localizedDescription
            pendingSelection = nil
        }
    }

    private func applyPendingSelection() {
        // The alert settled the Markdown question. The notes field is still
        // owed a write before the pane holding it is replaced; its words
        // outlive the view either way, so a refusal is reported rather than
        // blocking the selection the user already confirmed.
        if let failure = personalNotesDraft.saveIfNeeded(store: store) {
            showCopyNotice(failure, severity: .failure)
        }
        selection = pendingSelection
        pendingSelection = nil
    }

    private func synchronizeSelectionWithSearch() {
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !searchController.isSearching
        else {
            return
        }
        if case .note(let selectedID) = selection,
           filteredNotes.contains(where: { $0.id == selectedID }) {
            return
        }
        requestSelection(filteredNotes.first.map { .note($0.id) })
    }

    private func showCopyNotice(
        _ message: String,
        severity: CopyConfirmationBanner.Severity = .success
    ) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
            copyNotice = message
            copyNoticeSeverity = severity
        }
        // Failures name a problem the user may need to read carefully, so
        // they stay up longer than confirmations.
        let dwell = severity == .success ? 1.8 : 4.0
        Task {
            try? await Task.sleep(for: .seconds(dwell))
            guard copyNotice == message else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                copyNotice = nil
            }
        }
    }

    private func createBlankNote() {
        createNote(from: .blank)
    }

    private func createNote(from template: NoteTemplate) {
        do {
            let note = try store.createTemplatedNote(from: template)
            selection = .note(note.id)
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
        let window = DigestBuilder.period()
        guard !DigestBuilder.coveredMeetings(from: store.notes).isEmpty else {
            showCopyNotice(
                "No meetings from the last seven days to include yet.",
                severity: .info
            )
            return
        }
        let existing = store.notes.first {
            $0.kind == .digest
                && $0.startedAt >= window.start
                && $0.startedAt <= window.end
        }
        Task {
            let digest = await DigestBuilder.build(
                from: store.notes,
                id: existing?.id ?? UUID(),
                fileURL: existing?.fileURL
            )
            do {
                let saved = try store.save(digest)
                requestSelection(.note(saved.id))
            } catch {
                showCopyNotice(
                    error.localizedDescription,
                    severity: .failure
                )
            }
        }
    }

    /// Folds one saved note into another and removes what it absorbed.
    ///
    /// The merged note is saved before the absorbed file is trashed, so a
    /// failure anywhere leaves both originals on disk rather than half of one.
    private func mergeNotes(_ absorbed: MeetingNote, into target: MeetingNote) {
        Task {
            do {
                let result = try await NoteCombiner.merge(
                    absorbed,
                    into: target,
                    recordingsDirectory: store.recordingsDirectory(),
                    summarizer: SummaryService()
                )
                // Markdown first. Until the merged note is on disk every file
                // this touches can still be left exactly as it was, so a
                // failure up to here means the merge can simply be tried
                // again. Joining the audio is the irreversible half and runs
                // only once the text is safe.
                let saved = try store.save(result.merged)
                var audioProblem: String?
                do {
                    try await result.commitAudio()
                } catch {
                    audioProblem = error.localizedDescription
                }
                // The merge itself is done either way: leaving the absorbed
                // note behind would show the same conversation twice.
                store.delete(result.absorbed)
                requestSelection(.note(saved.id))
                if let audioProblem {
                    showCopyNotice(
                        "Merged into “\(saved.title)”, but the recordings could not be joined: \(audioProblem)",
                        severity: .failure
                    )
                } else {
                    showCopyNotice(mergeNotice(for: result.audioOutcome, title: saved.title))
                }
            } catch {
                store.lastError = error.localizedDescription
            }
        }
    }

    /// Names the note that survived, because it is not always the one the
    /// user picked: the combined note is filed under whichever meeting
    /// started first.
    private func mergeNotice(
        for audioOutcome: NoteCombiner.AudioOutcome,
        title: String
    ) -> String {
        switch audioOutcome {
        case .concatenated:
            "Merged into “\(title)”. Both recordings were joined into one, and the other note moved to the Trash."
        case .adoptedFromAbsorbed:
            "Merged into “\(title)”. The other note's recording came with it, and that note moved to the Trash."
        case .targetOnly, .none:
            "Merged into “\(title)”. The other note moved to the Trash."
        }
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
        guard selection == nil else { return }
        selection = restoredOrFirstSelection(in: store.notes)
    }

    private func restoredOrFirstSelection(
        in notes: [MeetingNote]
    ) -> LibrarySelection? {
        if markdownDraft.hasChanges,
           let noteID = markdownDraft.noteID,
           notes.contains(where: { $0.id == noteID }) {
            return .note(noteID)
        }
        return notes.first.map { .note($0.id) }
    }
}

/// Mirrors only `meeting.phase` into a plain `@State` value on `LibraryView`.
///
/// `MeetingCoordinator` is one `ObservableObject` that publishes phase
/// alongside audio level (up to ~12 Hz) and live transcript (up to ~10 Hz)
/// while a meeting records. Holding `@EnvironmentObject` directly on
/// `LibraryView` subscribes to all of that at once, since Combine's
/// `objectWillChange` does not distinguish which published property
/// changed: every tick would invalidate the whole view, including the
/// sidebar's note grouping and filtering, for a phase that changes only a
/// handful of times per meeting. This bridge is the one place that pays the
/// tick rate; its own body does nothing but compare and store a value, so
/// the cost of absorbing those ticks here is negligible.
private struct MeetingPhaseObserver: View {
    @EnvironmentObject private var meeting: MeetingCoordinator
    @Binding var phase: MeetingPhase

    var body: some View {
        Color.clear
            .onAppear { phase = meeting.phase }
            .onChange(of: meeting.phase) { _, newValue in phase = newValue }
    }
}

/// The toolbar's recording controls, isolated into their own view so only
/// this small piece re-renders on the coordinator's meter ticks; `LibraryView`
/// itself no longer holds `MeetingCoordinator` at all (see
/// `MeetingPhaseObserver`).
private struct LibraryRecordingToolbar: View {
    @EnvironmentObject private var meeting: MeetingCoordinator
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
            .keyboardShortcut("n", modifiers: .command)
            .help("Create a local note from a starting point")
        }
    }

    private var isProcessing: Bool {
        if case .processing = meeting.phase { return true }
        return false
    }
}

/// The sidebar's "Now" row, isolated into its own view so only this small
/// section re-renders on the coordinator's meter ticks (elapsed at ~1 Hz,
/// audio level at up to ~12 Hz while recording) instead of the sidebar's
/// note grouping and filtering above it.
private struct LibraryLiveSection: View {
    @EnvironmentObject private var meeting: MeetingCoordinator
    let selection: LibrarySelection?

    var body: some View {
        if meeting.phase.presentsLiveActivity {
            Section {
                LiveSidebarRow(
                    phase: meeting.phase,
                    elapsed: meeting.elapsed,
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

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            sourceMark

            VStack(alignment: .leading, spacing: 4) {
                Text(note.title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(primaryTextColor)
                    .lineLimit(1)

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

private struct LiveSidebarRow: View {
    let phase: MeetingPhase
    let elapsed: TimeInterval
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
            return "\(isPaused ? "Paused" : "Live") · \(NookElapsedTime.clock(elapsed))"
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
