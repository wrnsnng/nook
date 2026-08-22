import AppKit
import SwiftUI

private enum LibrarySelection: Hashable {
    case live
    case note(MeetingNote.ID)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var searchController = LibrarySearchController()
    @State private var selection: LibrarySelection?
    @State private var searchText = ""
    @State private var pendingSelection: LibrarySelection?
    @State private var showsUnsavedChangesAlert = false
    @State private var copyNotice: String?

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
                CopyConfirmationBanner(message: copyNotice)
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .onAppear {
            store.reload()
            searchController.update(query: searchText, notes: store.notes)
            chooseInitialSelection()
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

    @ViewBuilder
    private var detail: some View {
        if selection == .live {
            LiveMeetingView()
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

    private func showCopyNotice(_ message: String) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
            copyNotice = message
        }
        Task {
            try? await Task.sleep(for: .seconds(1.8))
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
            .frame(width: 31, height: 31)

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
            let total = Int(elapsed)
            return "\(isPaused ? "Paused" : "Live") · \(String(format: "%02d:%02d", total / 60, total % 60))"
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
