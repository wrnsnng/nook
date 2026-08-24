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
    /// The global shortcut that already runs this command, written the way
    /// the menus write it. Only ever a shortcut that genuinely exists: a
    /// hint for a key combination that does nothing is worse than no hint.
    var shortcut: String?
    let perform: () -> Void

    static func == (lhs: CommandPaletteItem, rhs: CommandPaletteItem) -> Bool {
        lhs.id == rhs.id
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
    let presentQuickNote: () -> Void

    @State private var query = ""
    @State private var selectedIndex = 0
    /// The sections as of the last refresh. `sections` used to be computed
    /// straight in the body, lowercasing every note on every hover
    /// (`selectedIndex` is `@State`, so a hover invalidated the view) and on
    /// every tick the coordinator publishes while the palette happens to be
    /// open during a recording. Recomputed only from `refreshSections()`,
    /// called when the query, the notes, or whether a meeting is recording
    /// actually changes.
    @State private var cachedSections: [CommandPaletteSection] = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            // A dim behind the panel, and a click anywhere on it closes.
            // Without one the palette floated over a fully lit library and
            // read as another pane rather than as the thing with focus.
            Rectangle()
                .fill(.black.opacity(0.18))
                .contentShape(Rectangle())
                .onTapGesture { isPresented = false }
                .accessibilityHidden(true)

            panel
        }
        .ignoresSafeArea()
        .transition(
            reduceMotion
                ? .opacity
                : .opacity.combined(with: .scale(scale: 0.98))
        )
    }

    private var panel: some View {
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
            refreshSections()
        }
        .onChange(of: query) { _, _ in
            selectedIndex = 0
            refreshSections()
        }
        .onChange(of: store.notes) { _, _ in
            refreshSections()
        }
        .onChange(of: meeting.phase) { _, _ in
            refreshSections()
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
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(sections) { section in
                        sectionHeader(section.title)
                        ForEach(section.items) { item in
                            let index = items.firstIndex(of: item) ?? 0
                            row(item, isSelected: index == selectedIndex)
                                .id(index)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: selectedIndex) { _, newIndex in
                proxy.scrollTo(newIndex, anchor: .center)
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
        run(items[selectedIndex])
    }

    private func run(_ item: CommandPaletteItem) {
        isPresented = false
        item.perform()
    }

    // MARK: - Items

    /// The sections as of the last `refreshSections()` call. See
    /// `cachedSections`.
    private var sections: [CommandPaletteSection] { cachedSections }

    /// Redoes the query match, the note search, and the open-actions list.
    /// Called from `refreshSections()`'s call sites rather than from `body`,
    /// so a hover or a meter tick that changes none of the query, the notes,
    /// or the recording state does not lowercase and filter every note again.
    private func refreshSections() {
        cachedSections = computeSections()
    }

    private func computeSections() -> [CommandPaletteSection] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .localizedLowercase

        let commands = verbs.filter {
            needle.isEmpty || $0.title.localizedLowercase.contains(needle)
        }

        let notes = orderedNotes(matching: needle).prefix(8).map { note in
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
                    // Matches the Meeting menu, which is where this shortcut
                    // is declared.
                    shortcut: "⇧⌘.",
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
                    shortcut: "⇧⌘R",
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
