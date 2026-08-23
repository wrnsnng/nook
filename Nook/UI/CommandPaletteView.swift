import SwiftUI

/// One row of the command palette: a verb, a note, or an open action.
struct CommandPaletteItem: Identifiable, Equatable {
    enum Destination: Equatable {
        case verb
        case note(MeetingNote.ID)
    }

    let id: String
    let symbol: String
    let title: String
    let subtitle: String?
    let destination: Destination
    let perform: () -> Void

    static func == (lhs: CommandPaletteItem, rhs: CommandPaletteItem) -> Bool {
        lhs.id == rhs.id
    }
}

/// A `⌘K` launcher over everything the library can do.
///
/// Verbs stay visible so the palette teaches the app's actions while it
/// jumps between them; notes arrive through the same matcher the sidebar
/// search uses; open actions appear so follow-through is one keystroke away.
/// Deliberately a plain sheet-hosted panel with standard list semantics
/// rather than a custom window: focus handling and Escape belong to the
/// platform.
struct CommandPaletteView: View {
    @Binding var isPresented: Bool
    @EnvironmentObject private var store: MarkdownStore
    @EnvironmentObject private var meeting: MeetingCoordinator

    /// The sidebar's aggregated open items, so follow-through is one
    /// keystroke away.
    let openActionEntries: [OpenAction]
    let createNote: (NoteTemplate) -> Void
    let createWeeklyDigest: () -> Void
    let showAskSheet: () -> Void

    @State private var query = ""
    @State private var selectedIndex = 0

    var body: some View {
        VStack(spacing: 0) {
            searchHeader
            SoftDivider()

            if items.isEmpty {
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
        .shadow(color: .black.opacity(0.22), radius: 22, y: 10)
        .padding(40)
        // Arrow navigation must work while the query field holds focus, which
        // field-level key handling cannot promise; hidden accelerators can.
        .background {
            Button("Previous") {
                moveSelection(-1)
            }
            .keyboardShortcut(.upArrow, modifiers: [])
            .opacity(0)
            .accessibilityHidden(true)

            Button("Next") {
                moveSelection(1)
            }
            .keyboardShortcut(.downArrow, modifiers: [])
            .opacity(0)
            .accessibilityHidden(true)
        }
        .onExitCommand { isPresented = false }
        .onAppear {
            selectedIndex = 0
        }
        .onChange(of: query) { _, _ in
            selectedIndex = 0
        }
        .accessibilityLabel("Command palette")
    }

    private var searchHeader: some View {
        HStack(spacing: NookSpacing.small) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(
                "Type a command or search notes",
                text: $query
            )
            .textFieldStyle(.plain)
            .font(NookType.body)
            .onSubmit(runSelected)

            Text("esc")
                .font(NookType.micro)
                .foregroundStyle(.tertiary)
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
                LazyVStack(spacing: 0) {
                    ForEach(
                        Array(items.enumerated()),
                        id: \.element.id
                    ) { index, item in
                        row(item, isSelected: index == selectedIndex)
                            .id(index)
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: selectedIndex) { _, newIndex in
                proxy.scrollTo(newIndex, anchor: .center)
            }
        }
        .frame(maxHeight: 320)
    }

    private func row(
        _ item: CommandPaletteItem,
        isSelected: Bool
    ) -> some View {
        Button(action: runSelected) {
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
                    }
                }
                Spacer()
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
            if let index = items.firstIndex(where: { $0.id == item.id }) {
                selectedIndex = index
            }
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func moveSelection(_ direction: Int) {
        guard !items.isEmpty else { return }
        let next = selectedIndex + direction
        selectedIndex = min(max(next, 0), items.count - 1)
    }

    private func runSelected() {
        guard items.indices.contains(selectedIndex) else { return }
        let item = items[selectedIndex]
        isPresented = false
        item.perform()
    }

    // MARK: - Items

    private var items: [CommandPaletteItem] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .localizedLowercase
        var result: [CommandPaletteItem] = verbs.filter {
            needle.isEmpty || $0.title.localizedLowercase.contains(needle)
        }

        let notes = orderedNotes(matching: needle)
        result.append(
            contentsOf: notes.prefix(8).map { note in
                CommandPaletteItem(
                    id: "note-\(note.id.uuidString)",
                    symbol: note.kind.symbol,
                    title: note.title,
                    subtitle: note.startedAt.formatted(
                        date: .abbreviated,
                        time: .shortened
                    ),
                    destination: .note(note.id),
                    perform: {
                        NotificationCenter.default.post(
                            name: .nookOpenMeetingNote,
                            object: note.id
                        )
                    }
                )
            }
        )

        if needle.isEmpty || "actions".hasPrefix(needle) {
            for entry in openActionEntries.prefix(3) {
                result.append(
                    CommandPaletteItem(
                        id: "action-\(entry.id)",
                        symbol: "checklist",
                        title: entry.displayText,
                        subtitle: "Open action · \(entry.noteTitle)",
                        destination: .note(entry.noteID),
                        perform: {
                            NotificationCenter.default.post(
                                name: .nookOpenMeetingNote,
                                object: entry.noteID
                            )
                        }
                    )
                )
            }
        }

        return result
    }

    /// Title matches lead, then content matches, mirroring how a person
    /// scans their own library.
    private func orderedNotes(matching needle: String) -> [MeetingNote] {
        guard !needle.isEmpty else {
            return Array(store.notes.prefix(5))
        }
        let hits = store.notes.filter { note in
            note.title.localizedLowercase.contains(needle)
                || note.summary.localizedLowercase.contains(needle)
                || note.personalNotes.localizedLowercase.contains(needle)
        }
        return hits.sorted {
            let leftLeads = $0.title.localizedLowercase.hasPrefix(needle)
            let rightLeads = $1.title.localizedLowercase.hasPrefix(needle)
            if leftLeads != rightLeads { return leftLeads }
            return $0.startedAt > $1.startedAt
        }
    }

    private var verbs: [CommandPaletteItem] {
        var list: [CommandPaletteItem] = []
        if meeting.phase.isRecording {
            list.append(
                CommandPaletteItem(
                    id: "verb-finish",
                    symbol: "stop.fill",
                    title: "Finish meeting",
                    subtitle: nil,
                    destination: .verb,
                    perform: { meeting.stopRecording() }
                )
            )
        } else {
            list.append(
                CommandPaletteItem(
                    id: "verb-record",
                    symbol: "waveform.badge.mic",
                    title: "Start recording",
                    subtitle: nil,
                    destination: .verb,
                    perform: { meeting.startManualMeeting() }
                )
            )
        }
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
                    id: "verb-ask",
                    symbol: "sparkle.magnifyingglass",
                    title: "Ask your library",
                    subtitle: nil,
                    destination: .verb,
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
