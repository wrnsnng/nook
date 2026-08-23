import AppKit
import SwiftUI

private enum LibrarySelection: Hashable {
    case live
    case note(MeetingNote.ID)
    case prep
}

private struct LibraryNoteGroup: Identifiable {
    let title: String
    let notes: [MeetingNote]
    var id: String { title }
}

struct LibraryView: View {
    @EnvironmentObject private var store: MarkdownStore
    @EnvironmentObject private var meeting: MeetingCoordinator
    @EnvironmentObject private var markdownDraft: MarkdownDraftController
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

    init(initialNoteID: MeetingNote.ID? = nil) {
        _selection = State(
            initialValue: initialNoteID.map(LibrarySelection.note)
        )
    }

    private var filteredNotes: [MeetingNote] {
        guard let matchingIDs = searchController.matchingIDs else { return store.notes }
        return store.notes.filter { matchingIDs.contains($0.id) }
    }

    private var selectedNote: MeetingNote? {
        guard case .note(let id) = selection else { return nil }
        return store.notes.first(where: { $0.id == id })
    }

    private var groupedNotes: [LibraryNoteGroup] {
        var orderedTitles: [String] = []
        var values: [String: [MeetingNote]] = [:]

        for note in filteredNotes {
            let title = groupTitle(for: note.startedAt)
            if values[title] == nil {
                orderedTitles.append(title)
            }
            values[title, default: []].append(note)
        }
        return orderedTitles.map {
            LibraryNoteGroup(title: $0, notes: values[$0] ?? [])
        }
    }

    private var presentsLiveActivity: Bool {
        switch meeting.phase {
        case .recording, .processing, .failed:
            true
        case .idle, .detected, .completed:
            false
        }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 260, ideal: 304, max: 380)
        } detail: {
            detail
        }
        .tint(NookPalette.accent)
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
                    Button {
                        createBlankNote()
                    } label: {
                        Label("New note", systemImage: "square.and.pencil")
                    }
                    .disabled(isProcessing)
                    .keyboardShortcut("n", modifiers: .command)
                    .help("Create a blank local note")
                }
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
            chooseInitialSelection()
            Task { await openActions.refresh(store: store) }
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
        .onChange(of: meeting.phase) { _, phase in
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.34)) {
                switch phase {
                case .recording, .processing, .failed:
                    selection = .live
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

    private var sidebar: some View {
        List {
            prepSection
            openActionsSection

            if presentsLiveActivity {
                Section {
                    Button {
                        requestSelection(.live)
                    } label: {
                        LiveSidebarRow(
                            phase: meeting.phase,
                            elapsed: meeting.elapsed,
                            isPaused: meeting.isPaused,
                            isSelected: selection == .live
                        )
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(
                        selection == .live
                            ? NookPalette.sidebarSelection
                            : Color.clear
                    )
                    .accessibilityAddTraits(
                        selection == .live ? .isSelected : []
                    )
                } header: {
                    sidebarSectionHeader("Now")
                }
            }

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
                            Button("Open Folder") {
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
                        Button {
                            requestSelection(.note(note.id))
                        } label: {
                            MeetingRow(
                                note: note,
                                isSelected: selection == .note(note.id)
                            )
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(
                            selection == .note(note.id)
                                ? NookPalette.sidebarSelection
                                : Color.clear
                        )
                        .accessibilityAddTraits(
                            selection == .note(note.id)
                                ? .isSelected
                                : []
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
                                    meeting.continueRecording(into: note)
                                }
                                .disabled(
                                    meeting.phase.isRecording || isProcessing
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
                            Button("Delete", role: .destructive) {
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
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            .textCase(nil)
    }

    /// A quiet pointer at the next sitting of a series with history. Time-
    /// sensitive, so it leads the sidebar; tapping opens the brief.
    @ViewBuilder
    private var prepSection: some View {
        if let brief = prep.current {
            Section {
                PrepCard(
                    brief: brief,
                    isOpen: selection == .prep,
                    onOpen: { requestSelection(.prep) }
                )
            } header: {
                sidebarSectionHeader("Prep")
            }
        }
    }

    /// Unfinished action items across the library, closest first.
    @ViewBuilder
    private var openActionsSection: some View {
        let visible = openActions.entries.prefix(8)
        if !visible.isEmpty {
            Section {
                ForEach(Array(visible)) { entry in
                    OpenActionRow(
                        entry: entry,
                        exported: openActions.exportedIDs.contains(entry.id),
                        onToggle: {
                            Task {
                                await openActions.toggle(
                                    entry,
                                    store: store
                                )
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
                if openActions.entries.count > visible.count {
                    Text("\(openActions.entries.count - visible.count) more in the notes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let message = openActions.lastError {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(NookPalette.danger)
                }
            } header: {
                sidebarSectionHeader("Open actions")
            } footer: {
                Text("Unfinished items from your meeting notes.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if selection == .live {
            LiveMeetingView()
        } else if selection == .prep, let brief = prep.current {
            PrepBriefView(brief: brief) { noteID in
                requestSelection(.note(noteID))
            }
        } else if let selectedNote {
            MeetingDetailView(note: selectedNote)
                .id(selectedNote.id)
        } else {
            EmptyLibraryView {
                meeting.startManualMeeting()
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
        if case .processing = meeting.phase { return true }
        return false
    }

    private func requestSelection(_ requestedSelection: LibrarySelection?) {
        guard requestedSelection != selection else { return }
        let isLeavingEditedNote: Bool
        if case .note(let selectedID) = selection {
            isLeavingEditedNote = markdownDraft.noteID == selectedID
                && markdownDraft.hasChanges
        } else {
            isLeavingEditedNote = false
        }

        guard isLeavingEditedNote else {
            selection = requestedSelection
            return
        }
        pendingSelection = requestedSelection
        showsUnsavedChangesAlert = true
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
        do {
            let note = try store.createBlankNote()
            selection = .note(note.id)
        } catch {
            store.lastError = error.localizedDescription
        }
    }

    private func groupTitle(for date: Date) -> String {
        let calendar = Calendar.autoupdatingCurrent
        if calendar.isDateInToday(date) {
            return "Today"
        }
        if calendar.isDateInYesterday(date) {
            return "Yesterday"
        }
        if let currentWeek = calendar.dateInterval(
            of: .weekOfYear,
            for: Date()
        ), currentWeek.contains(date) {
            return "This Week"
        }
        return date.formatted(
            .dateTime
                .month(.wide)
                .year()
        )
    }

    /// Compiles the week's meetings into one digest note and opens it.
    ///
    /// A week with nothing in it produces a file whose every count is zero,
    /// so the action refuses and says so instead of saving an empty digest.
    private func createWeeklyDigest() {
        let window = DigestBuilder.period()
        let covered = store.notes.filter { note in
            note.kind == .meeting
                && note.startedAt >= window.start
                && note.startedAt <= window.end
        }
        guard !covered.isEmpty else {
            showCopyNotice(
                "No meetings from the last seven days to include yet.",
                severity: .info
            )
            return
        }
        Task {
            let digest = await DigestBuilder.build(from: store.notes)
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
                let saved = try store.save(result.merged)
                store.delete(result.absorbed)
                requestSelection(.note(saved.id))
                if result.audioOutcome == .targetOnly {
                    showCopyNotice(
                        "Merged. Kept audio from the other note stayed in your recordings folder."
                    )
                } else {
                    showCopyNotice("Notes merged")
                }
            } catch {
                store.lastError = error.localizedDescription
            }
        }
    }

    private func chooseInitialSelection() {
        if presentsLiveActivity {
            selection = .live
        } else if selection == nil {
            selection = restoredOrFirstSelection(in: store.notes)
        }
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
                    Text("A quiet place for every conversation")
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
            .contentShape(Rectangle())
            .onTapGesture(perform: onSelect)
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
            Button("Next week") { onSetDue(nextWeek()) }
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
                    Button("Set Due Date") {
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
        // The row reads as one element, so VoiceOver reaches the tick and
        // export through actions instead of a flattened, unlabeled blob.
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
                    "The other note's transcript, moments, and personal notes join this one, and its summary is rewritten over everything."
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
