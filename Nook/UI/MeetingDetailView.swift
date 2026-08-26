import AppKit
import SwiftUI

enum DetailTab: String, CaseIterable, Identifiable {
    case notes = "Notes"
    case transcript = "Transcript"
    case markdown = "Markdown"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .notes: "sparkles"
        case .transcript: "quote.bubble"
        case .markdown: "chevron.left.forwardslash.chevron.right"
        }
    }
}

struct MeetingDetailView: View {
    @EnvironmentObject private var store: MarkdownStore
    @EnvironmentObject private var markdownDraft: MarkdownDraftController
    @EnvironmentObject private var personalNotes: PersonalNotesDraftController
    @EnvironmentObject private var shortcuts: ShortcutStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let note: MeetingNote

    @State private var tab: DetailTab = .notes
    @State private var transcriptSearch = ""
    /// A moment the user asked to see; consumed by the transcript scroll.
    @State private var requestedMomentOffset: TimeInterval?
    /// Kept audio for this note, if any, enabling transcript playback.
    @State private var playback = AudioPlaybackController()
    @State private var positionTick: Task<Void, Never>?
    @State private var copyNotice: String?
    @State private var copyNoticeSeverity: CopyConfirmationBanner.Severity = .success
    @State private var titleDraft: String
    /// Rename is an intentional mode, rather than a field that is live in
    /// every note. The title that was visible when the mode began is the
    /// cancel target, even if the draft has since been edited.
    @State private var isEditingTitle = false
    @State private var titleAtEditStart: String
    /// Whether the My notes field has the keyboard. Leaving it writes what is
    /// there, for the same reason the title field does: waiting for a button
    /// meant every other way out of the field threw the words away.
    @FocusState private var personalNotesFocused: Bool
    /// The title field is focused only after the user explicitly chooses
    /// Rename. The read-only title shown when a note opens never requests it.
    @FocusState private var titleFieldFocused: Bool
    /// The Markdown length, recomputed when the draft changes rather than on
    /// every pass through `body`. Counting a long note's characters during
    /// layout ran the whole string for a label nobody was reading.
    ///
    /// Counted as characters, not UTF-8 bytes, because that is what the label
    /// says: an accented or emoji-bearing note would otherwise report a
    /// number larger than anything a person could count in it.
    @State private var markdownCharacterCount = 0
    /// Whether the regeneration pass over this note's transcript is running,
    /// and which stage it has reached, so waiting reads as progress instead
    /// of a dead button.
    @State private var regenerationStage: SummaryStage?
    /// Button-driven work is kept explicitly so navigation can cancel it.
    /// Without this handle, the old detail view could finish after another
    /// note had taken over the shared Markdown draft controller.
    @State private var regenerationTask: Task<Void, Never>?
    /// The note's checkbox lines as they exist on disk right now. Checkbox
    /// state is deliberately absent from the decoded model, so ticking from
    /// here needs the file's own truth to stay aligned with the sidebar.
    @State private var checklistLines: [ActionItemLine] = []
    /// Words across the note's primary source, computed once when the note
    /// changes rather than inside the header. Spoken notes keep their prose
    /// in `summary`; recorded meetings keep words in transcript segments.
    @State private var contentWordCount = 0
    /// The first row and every meaningful source/session transition keep a
    /// badge. Rows whose badge is hidden still name their source through the
    /// row's accessibility label below.
    @State private var transcriptSourceBadgeIDs: Set<UUID>

    init(note: MeetingNote, initialTab: DetailTab = .notes) {
        self.note = note
        let startingTab = note.kind == .spoken
            && note.transcript.isEmpty
            && initialTab == .transcript
            ? .notes
            : initialTab
        _tab = State(initialValue: startingTab)
        _titleDraft = State(initialValue: note.title)
        _titleAtEditStart = State(initialValue: note.title)
        _transcriptSourceBadgeIDs = State(
            initialValue: TranscriptBadgeGroupingPolicy.visibleBadgeIDs(
                in: note.transcript,
                sessions: note.sessions
            )
        )
    }

    var body: some View {
        ZStack {
            NookAmbientBackground()

            VStack(spacing: 0) {
                documentHeader
                SoftDivider()

                ZStack {
                    switch tab {
                    case .notes:
                        notesView
                            .transition(tabTransition)
                    case .transcript:
                        transcriptView
                            .transition(tabTransition)
                    case .markdown:
                        markdownView
                            .transition(tabTransition)
                    }
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
            markdownDraft.prepare(for: note, store: store)
            personalNotes.prepare(for: note, store: store)
            markdownCharacterCount = markdownDraft.rawMarkdown.count
            contentWordCount = note.detailContentWordCount
            transcriptSourceBadgeIDs = TranscriptBadgeGroupingPolicy.visibleBadgeIDs(
                in: filteredTranscript,
                sessions: note.sessions
            )
            reloadChecklist()
        }
        .onChange(of: markdownDraft.rawMarkdown) { _, markdown in
            markdownCharacterCount = markdown.count
        }
        .onChange(of: note) { _, newValue in
            contentWordCount = newValue.detailContentWordCount
            transcriptSourceBadgeIDs = TranscriptBadgeGroupingPolicy.visibleBadgeIDs(
                in: Self.filteredTranscript(
                    from: newValue,
                    matching: transcriptSearch
                ),
                sessions: newValue.sessions
            )
            reloadChecklist()
            if newValue.kind == .spoken,
               newValue.transcript.isEmpty,
               tab == .transcript {
                tab = .notes
            }
        }
        .onChange(of: transcriptSearch) { _, _ in
            // Group the rows that are actually visible. A search can make a
            // later segment the first row; it must not inherit a hidden
            // predecessor's suppressed source badge.
            transcriptSourceBadgeIDs = TranscriptBadgeGroupingPolicy.visibleBadgeIDs(
                in: filteredTranscript,
                sessions: note.sessions
            )
        }
        .onChange(of: note.personalNotes) { _, _ in
            personalNotes.refresh(for: note)
        }
        .onChange(of: note.title) { oldValue, newValue in
            guard !isEditingTitle else { return }
            if titleDraft == oldValue {
                titleDraft = newValue
            }
            titleAtEditStart = newValue
        }
        .onChange(of: titleFieldFocused) { _, focused in
            guard !focused, isEditingTitle else { return }
            // Clicking another control commits the draft. That keeps typed
            // words from disappearing on a focus change, and is also stated
            // in the editor's help and accessibility hint.
            saveTitle()
        }
        .onChange(of: personalNotesFocused) { _, focused in
            guard !focused else { return }
            savePersonalNotes()
        }
        // Backstop for navigation that races focus loss: the view keeps its
        // own note, so committing here always writes the right file.
        .onDisappear {
            cancelSummaryRegeneration()
            saveTitle()
            savePersonalNotes()
        }
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.24),
            value: tab
        )
    }

    private var tabTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.995)),
            removal: .opacity
        )
    }

    /// Spoken notes already expose their original wording in `summary`, so a
    /// second empty Transcript surface would only suggest meeting capture
    /// happened. Keep a transcript tab when a caller supplies transcript
    /// segments, so an unusual but valid model value never becomes unreachable.
    private var showsTranscriptTab: Bool {
        note.kind != .spoken || !note.transcript.isEmpty
    }

    private var documentHeader: some View {
        VStack(alignment: .leading, spacing: 22) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .bottom, spacing: 28) {
                    titleBlock
                    Spacer(minLength: 24)
                    DetailTabBar(
                        selection: $tab,
                        showsTranscript: showsTranscriptTab
                    )
                    detailActions
                }

                VStack(alignment: .leading, spacing: 18) {
                    titleBlock
                    HStack {
                        DetailTabBar(
                            selection: $tab,
                            showsTranscript: showsTranscriptTab
                        )
                        Spacer()
                        detailActions
                    }
                }
            }
        }
        .padding(.horizontal, 42)
        .padding(.top, 32)
        .padding(.bottom, 24)
    }

    private var detailActions: some View {
        Menu {
            Button {
                copyMarkdown()
            } label: {
                Label("Copy Markdown", systemImage: "doc.on.doc")
            }

            Button {
                store.reveal(note)
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }

            Button {
                renameManagedFile()
            } label: {
                Label(
                    "Rename File to Match Title",
                    systemImage: "arrow.triangle.2.circlepath"
                )
            }
            .disabled(!canRenameManagedFile)
            .help(
                renameFileHelp
            )
            .accessibilityHint(renameFileHelp)

            if SummaryRegenerator.isAvailable(for: note) {
                Button {
                    regenerateSummary()
                } label: {
                    Label(
                    isRegenerating ? "Regenerating summary…" : "Regenerate summary",
                    systemImage: "arrow.clockwise"
                )
                }
                .disabled(markdownDraft.hasChanges || isRegenerating)
                .help(
                    markdownDraft.hasChanges
                        ? "Save or revert Markdown edits before regenerating"
                        : "Runs the on-device summary again over this transcript"
                )
            }

            if note.kind != .digest {
                Divider()
                RecordIntoNoteMenuItem(note: note)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(NookType.control)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(detailActionsLabel)
        .accessibilityLabel(detailActionsLabel)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isEditingTitle {
                TextField(titleLabel, text: $titleDraft)
                    .textFieldStyle(.plain)
                    .font(NookType.title)
                    .tracking(-0.45)
                    .lineLimit(2)
                    .focused($titleFieldFocused)
                    .onSubmit(saveTitle)
                    .onExitCommand(perform: cancelTitleEditing)
                    .onAppear(perform: focusAndSelectTitle)
                    .help(
                        "Press Return to save, Escape to cancel, or click away to save"
                    )
                    .accessibilityLabel("\(titleLabel), editing")
                    .accessibilityValue(titleDraft)
                    .accessibilityHint(
                        "Press Return to save, Escape to cancel, or click away to save"
                    )
                    .accessibilityAddTraits(.isHeader)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(note.title)
                        .font(NookType.title)
                        .tracking(-0.45)
                        .lineLimit(2)
                        .textSelection(.enabled)
                        .accessibilityLabel("\(titleLabel): \(note.title)")
                        .accessibilityHint(
                            titleReadOnlyHint
                        )
                        .accessibilityAddTraits(.isHeader)

                    Button {
                        beginTitleEditing()
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .disabled(!canRenameTitle)
                    .help(titleRenameHelp)
                    .accessibilityLabel(renameLabel)
                    .accessibilityHint(titleRenameHelp)
                }
            }

            detailMetadata
        }
    }

    private var detailMetadata: some View {
        HStack(spacing: 15) {
            if note.kind == .spoken {
                NookMetadataLabel(
                    title: "Spoken note",
                    symbol: "waveform.badge.mic",
                    tint: NookPalette.accent
                )
                NookMetadataLabel(
                    title: "Created "
                        + note.startedAt.formatted(
                            date: .abbreviated,
                            time: .shortened
                        ),
                    symbol: "calendar"
                )
            } else {
                NookMetadataLabel(
                    title: note.startedAt.formatted(
                        date: .abbreviated,
                        time: .shortened
                    ),
                    symbol: "calendar"
                )
                NookMetadataLabel(title: note.durationLabel, symbol: "clock")
                if !note.sourceApp.isEmpty {
                    NookMetadataLabel(title: note.sourceApp, symbol: "macbook")
                }
            }

            NookMetadataLabel(
                title: "\(contentWordCount) words",
                symbol: "text.word.spacing"
            )
        }
    }

    private var titleLabel: String {
        note.kind == .spoken ? "Note title" : "Meeting title"
    }

    private var renameLabel: String {
        note.kind == .spoken ? "Rename note" : "Rename meeting"
    }

    private var canRenameTitle: Bool {
        DetailRenamePolicy.allowsTitleRename(
            hasMarkdownChanges: markdownDraft.hasChanges
        )
    }

    private var titleRenameHelp: String {
        canRenameTitle
            ? "Enter title editing mode"
            : DetailRenamePolicy.markdownDraftBlockedMessage
    }

    private var titleReadOnlyHint: String {
        canRenameTitle
            ? "Read-only title. Activate \(renameLabel) to edit."
            : "Read-only title. Save or revert Markdown edits before renaming."
    }

    private var renameFileHelp: String {
        if markdownDraft.hasChanges {
            return DetailRenamePolicy.markdownDraftBlockedMessage
        }
        return canRenameManagedFile
            ? "Rename this saved Markdown file to match the title"
            : "Only saved notes in Nook’s notes folder can be renamed"
    }

    private var detailActionsLabel: String {
        switch note.kind {
        case .spoken: "Note actions"
        case .meeting: "Meeting actions"
        case .digest: "Digest actions"
        }
    }

    private var notesView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 38) {
                if hasPrimaryContent {
                    summarySection
                }

                if note.kind != .spoken, !note.moments.isEmpty {
                    momentsSection
                }

                if note.kind != .spoken {
                    personalNotesSection
                }

                if note.kind != .spoken, !note.keyPoints.isEmpty {
                    EditorialSection(
                        title: "Key points",
                        symbol: "sparkles",
                        tint: NookPalette.accent
                    ) {
                        VStack(alignment: .leading, spacing: 17) {
                            ForEach(Array(note.keyPoints.enumerated()), id: \.offset) { index, item in
                                HStack(alignment: .firstTextBaseline, spacing: 14) {
                                    NookBullet()
                                    Text(item)
                                        .font(NookType.transcript)
                                        .lineSpacing(4)
                                        .textSelection(.enabled)
                                }
                                .accessibilityElement(children: .combine)
                                .accessibilityLabel("Key point \(index + 1): \(item)")
                            }
                        }
                    }
                }

                if note.kind != .spoken, !note.decisions.isEmpty {
                    EditorialSection(
                        title: "Decisions",
                        symbol: "checkmark.seal",
                        tint: NookPalette.accent
                    ) {
                        VStack(alignment: .leading, spacing: 16) {
                            ForEach(Array(note.decisions.enumerated()), id: \.offset) { _, decision in
                                HStack(alignment: .top, spacing: 13) {
                                    // Not a tick in a circle. That is exactly
                                    // the action-item control one section
                                    // below, and a decision read as a task
                                    // somebody had already completed.
                                    Image(systemName: "arrow.turn.down.right")
                                        .font(NookType.caption.weight(.semibold))
                                        .foregroundStyle(NookPalette.accent)
                                        .frame(width: 20, height: 20)
                                        .accessibilityHidden(true)
                                    Text(decision)
                                        .font(NookType.transcriptEmphasized)
                                        .lineSpacing(4)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .padding(.vertical, 2)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel("Decision: \(decision)")
                            }
                        }
                    }
                }

                if !checklistLines.isEmpty {
                    actionItemsSection
                }

                if note.kind != .spoken,
                   checklistLines.isEmpty,
                   note.keyPoints.isEmpty,
                   note.decisions.isEmpty,
                   note.actionItems.isEmpty {
                    Label(
                        "This conversation didn’t produce any explicit decisions or action items.",
                        systemImage: "leaf"
                    )
                    .font(NookType.body)
                    .foregroundStyle(.secondary)
                    .padding(.top, -16)
                }
            }
            .padding(.horizontal, 48)
            .padding(.vertical, 42)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    /// Tickable action items, wired to the same one-line file rewrite the
    /// sidebar uses. Closing out a task while rereading its note is the most
    /// natural moment, so the affordance belongs here too.
    private var actionItemsSection: some View {
        EditorialSection(
            title: "Action items",
            symbol: "checklist",
            tint: NookPalette.accent
        ) {
            VStack(spacing: 0) {
                if markdownDraft.hasChanges {
                    Label(
                        "Save or revert Markdown edits before ticking items",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(NookType.caption)
                    .foregroundStyle(NookPalette.warning)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 10)
                }

                ForEach(
                    Array(checklistLines.enumerated()),
                    id: \.element
                ) { index, line in
                    HStack(alignment: .top, spacing: 13) {
                        Button {
                            toggleChecklistLine(line)
                        } label: {
                            Image(
                                systemName: line.isChecked
                                    ? "checkmark.circle.fill" : "circle"
                            )
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(
                                line.isChecked
                                    ? NookPalette.success : NookPalette.accent
                            )
                            // The glyph stays small; the frame is the hit target.
                            .frame(width: 30, height: 30)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(markdownDraft.hasChanges)
                        .help(line.isChecked ? "Reopen item" : "Mark as done")
                        .accessibilityLabel(
                            "\(line.isChecked ? "Reopen" : "Complete"): \(line.displayText)"
                        )

                        Text(line.displayText)
                            .font(NookType.transcript)
                            .lineSpacing(4)
                            .strikethrough(line.isChecked)
                            .foregroundStyle(
                                line.isChecked ? .secondary : Color(nsColor: .labelColor)
                            )
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if let dueDate = line.dueDate {
                            Text("Due \(dueDate.formatted(.dateTime.month().day()))")
                                .font(NookType.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 8)
                    .accessibilityElement(children: .contain)

                    if index < checklistLines.count - 1 {
                        Divider()
                            .padding(.leading, 43)
                    }
                }
            }
        }
    }

    /// Re-reads checkbox truth from the file. The store republishes after a
    /// toggle anywhere (sidebar, palette, here), which recreates `note` and
    /// lands here, so every surface converges on the same state.
    private func reloadChecklist() {
        let lines: [ActionItemLine]
        if let markdown = try? store.rawMarkdown(for: note) {
            lines = note.kind == .spoken
                ? MarkdownCodec.spokenCheckboxLines(in: markdown)
                : MarkdownCodec.actionItemLines(in: markdown)
        } else if note.kind == .spoken {
            // An unsaved or unreadable file still shows its own words.
            lines = MarkdownCodec.spokenCheckboxLines(in: note.summary)
        } else {
            lines = []
        }
        checklistLines = lines
    }

    /// Toggles by rewriting exactly one line of the file, the same discipline
    /// the sidebar uses, so an externally edited file is reported stale
    /// instead of overwritten from a remembered model.
    private func toggleChecklistLine(_ line: ActionItemLine) {
        do {
            let markdown = try store.rawMarkdown(for: note)
            let rewritten: String?
            if note.kind == .spoken {
                rewritten = MarkdownCodec.markdownBySettingSpokenCheckbox(
                    line,
                    checked: !line.isChecked,
                    in: markdown
                )
            } else {
                rewritten = MarkdownCodec.markdownBySettingActionItem(
                    line,
                    checked: !line.isChecked,
                    in: markdown
                )
            }
            guard let rewritten else {
                showCopyNotice("That item changed on disk.", severity: .info)
                return
            }
            try store.saveRawMarkdown(rewritten, for: note)
            reloadChecklist()
        } catch {
            showCopyNotice(error.localizedDescription, severity: .failure)
        }
    }

    /// The instants the user flagged while recording, as jumps into the
    /// transcript.
    private var momentsSection: some View {
        EditorialSection(
            title: "Flagged moments",
            symbol: "flag",
            tint: NookPalette.accent
        ) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 110), spacing: 10)],
                alignment: .leading,
                spacing: 10
            ) {
                ForEach(note.moments, id: \.offset) { moment in
                    Button {
                        requestedMomentOffset = moment.offset
                        transcriptSearch = ""
                        tab = .transcript
                    } label: {
                        Label(moment.timestamp, systemImage: "flag.fill")
                            .font(.system(
                                size: 11,
                                weight: .medium,
                                design: .monospaced
                            ))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(
                        Capsule().fill(NookPalette.accent.opacity(0.14))
                    )
                    .help("Show this moment in the transcript")
                    .accessibilityLabel(
                        "Flagged moment at \(moment.timestamp)"
                    )
                }
            }
        }
    }

    private var personalNotesSection: some View {
        EditorialSection(
            title: "My notes",
            symbol: "square.and.pencil",
            tint: NookPalette.accent
        ) {
            VStack(spacing: 0) {
                NookNotesEditor(
                    text: $personalNotes.text,
                    placeholder: "Add context, a follow-up, or something you want to remember…",
                    isFocused: Binding(
                        get: { personalNotesFocused },
                        set: { personalNotesFocused = $0 }
                    ),
                    contentInsets: EdgeInsets(
                        top: 9,
                        leading: 9,
                        bottom: 9,
                        trailing: 9
                    ),
                    lineSpacing: 5
                )
                .disabled(markdownDraft.hasChanges)
                .accessibilityHint(
                    "Saved into the My notes section of this meeting’s Markdown file"
                )
                .frame(minHeight: 118)

                SoftDivider()

                HStack(spacing: 10) {
                    if markdownDraft.hasChanges {
                        Label(
                            "Save or revert Markdown edits before changing notes",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(NookType.caption)
                        .foregroundStyle(NookPalette.warning)
                    } else if let status = personalNotes.statusMessage {
                        Label(
                            status,
                            systemImage: status == "Saved"
                                ? "checkmark.circle.fill"
                                : "exclamationmark.circle"
                        )
                        .font(NookType.caption)
                        .foregroundStyle(
                            status == "Saved"
                                ? NookPalette.success
                                : NookPalette.danger
                        )
                    } else if personalNotes.hasChanges {
                        Text("Saves when you click away")
                            .font(NookType.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Stored locally in this Markdown file")
                            .font(NookType.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    // Kept even though the field now saves itself. Cmd-S is
                    // what a person reaches for when they want to be sure, and
                    // an autosaving field with no way to ask is a promise you
                    // cannot check. It confirms rather than being the only
                    // path, so forgetting it costs nothing.
                    Button("Save notes") {
                        savePersonalNotes()
                    }
                    .disabled(
                        !personalNotes.hasChanges
                            || markdownDraft.hasChanges
                    )
                    .keyboardShortcut(
                        shortcuts.binding(for: .saveNote).keyEquivalent,
                        modifiers: shortcuts.binding(for: .saveNote)
                            .eventModifiers
                    )
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 42)
            }
            .background(
                NookPalette.paper,
                in: RoundedRectangle(
                    cornerRadius: NookRadius.surface,
                    style: .continuous
                )
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: NookRadius.surface,
                    style: .continuous
                )
                    .stroke(
                        Color(nsColor: .separatorColor).opacity(0.52),
                        lineWidth: 0.7
                    )
            }
        }
    }

    /// The prose a person reads: for a spoken note, checkbox lines are
    /// lifted out and rendered as the tickable list above, so no sentence
    /// appears twice on the page. The file itself is untouched by this.
    private var displaySummary: String {
        Self.displaySummaryText(for: note)
    }

    private static func displaySummaryText(for note: MeetingNote) -> String {
        guard note.kind == .spoken else { return note.summary }
        let source = note.summary.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty
            ? note.transcript.map(\.text).joined(separator: " ")
            : note.summary
        return source
            .split(separator: "\n", omittingEmptySubsequences: true)
            .filter { line in
                !line.trimmingCharacters(in: .whitespaces).hasPrefix("- [")
            }
            .joined(separator: "\n")
    }

    private var hasPrimaryContent: Bool {
        !displaySummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The note value is the source of truth. Deriving these lightweight
    /// presentation-only boundaries here prevents SwiftUI from retaining a
    /// previous note's paragraph state when the detail view is reused.
    private var summaryParagraphs: [String] {
        DetailSummaryParagraphPolicy.paragraphs(for: displaySummary)
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            NookSectionLabel(
                title: note.kind == .spoken ? "Spoken words" : "The gist",
                symbol: note.kind == .spoken
                    ? "waveform" : "text.alignleft",
                tint: NookPalette.accent
            )

            if isRegenerating {
                regenerationStatusCard
            } else {
                summaryProse
            }
        }
    }

    @ViewBuilder
    private var summaryProse: some View {
        if summaryParagraphs.count < 2 {
            summaryParagraphText(summaryParagraphs.first ?? displaySummary)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(
                    Array(summaryParagraphs.enumerated()),
                    id: \.offset
                ) { _, paragraph in
                    summaryParagraphText(paragraph)
                }
            }
            // Combining the individual selectable Text values keeps
            // VoiceOver's reading order identical to the source prose while
            // the visible spacing makes long summaries easier to scan.
            .accessibilityElement(children: .combine)
        }
    }

    private func summaryParagraphText(_ paragraph: String) -> some View {
        Text(paragraph)
            .font(
                note.kind == .spoken
                    ? NookType.spoken : NookType.editorialSummary
            )
            .lineSpacing(7)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var filteredTranscript: [TranscriptSegment] {
        Self.filteredTranscript(from: note, matching: transcriptSearch)
    }

    private static func filteredTranscript(
        from note: MeetingNote,
        matching search: String
    ) -> [TranscriptSegment] {
        guard !search.isEmpty else { return note.transcript }
        return note.transcript.filter {
            $0.text.localizedCaseInsensitiveContains(search)
                || $0.source.label.localizedCaseInsensitiveContains(search)
        }
    }

    /// Segments the user flagged. A moment belongs to the last line that had
    /// begun when it was flagged, which also works for saved transcripts
    /// whose durations are zero.
    private var flaggedSegmentIDs: Set<UUID> {
        Set(note.moments.compactMap { moment in
            segmentCovering(offset: moment.offset)?.id
        })
    }

    private func segmentCovering(offset: TimeInterval) -> TranscriptSegment? {
        note.transcript.last { $0.startTime <= offset + 0.001 }
    }

    private var keptAudioURL: URL? {
        AudioPlaybackController.audioURL(for: note)
    }

    /// Whether this row is the one playback is currently inside.
    private func isPlayingSegment(_ segment: TranscriptSegment) -> Bool {
        guard let offset = playback.activeOffset else { return false }
        guard
            let covering = segmentCovering(offset: offset),
            covering.id == segment.id
        else { return false }
        return true
    }

    /// Small transport shown above the transcript while kept audio exists.
    private func playbackBar(url: URL) -> some View {
        HStack(spacing: 12) {
            Button {
                if playback.isPlaying {
                    playback.stop()
                } else {
                    playback.start(url: url, at: 0)
                }
            } label: {
                Label(
                    playback.isPlaying ? "Stop" : "Play from start",
                    systemImage: playback.isPlaying
                        ? "stop.fill" : "play.fill"
                )
                .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                playback.isPlaying
                    ? "Stop playback"
                    : "Play recording from the beginning"
            )

            if let offset = playback.activeOffset {
                Text(
                    "\(Self.clock(offset)) / \(Self.clock(playback.duration))"
                )
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .accessibilityLabel("Playback position")
            }

            Spacer()

            Text("Kept audio, on this Mac")
                .font(NookType.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(NookPalette.accent.opacity(0.08))
        )
        .padding(.bottom, 12)
    }

    private static func clock(_ interval: TimeInterval) -> String {
        NookElapsedTime.clock(interval)
    }

    private var transcriptView: some View {
        VStack(spacing: 0) {
            transcriptSearchBar
            SoftDivider()

            if filteredTranscript.isEmpty {
                ContentUnavailableView {
                    Label("No matching words", systemImage: "text.magnifyingglass")
                } description: {
                    Text("Try a different phrase or speaker.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            if let audioURL = keptAudioURL {
                                playbackBar(url: audioURL)
                            }
                            ForEach(filteredTranscript) { segment in
                                TranscriptRow(
                                    segment: segment,
                                    showsSourceBadge: transcriptSourceBadgeIDs
                                        .contains(segment.id),
                                    isFlagged: flaggedSegmentIDs.contains(
                                        segment.id
                                    ),
                                    isPlaying: isPlayingSegment(segment),
                                    playAction: keptAudioURL.map { url in
                                        { playback.start(
                                            url: url,
                                            at: segment.startTime
                                        ) }
                                    }
                                )
                                .id(segment.id)
                            }
                        }
                        .padding(.horizontal, 44)
                        .padding(.vertical, 16)
                        .frame(maxWidth: 880)
                        .frame(maxWidth: .infinity)
                    }
                    .onChange(of: requestedMomentOffset) { _, newValue in
                        guard let offset = newValue,
                              let target = segmentCovering(offset: offset)
                        else { return }
                        withAnimation(.easeOut(duration: 0.25)) {
                            proxy.scrollTo(target.id, anchor: .center)
                        }
                    }
                    .onChange(of: playback.isPlaying) { _, playing in
                        guard playing else { return }
                        // Keep the published position fresh while playing.
                        positionTick?.cancel()
                        positionTick = Task {
                            while !Task.isCancelled {
                                try? await Task.sleep(for: .milliseconds(500))
                                playback.refreshPosition()
                            }
                        }
                    }
                    .onDisappear {
                        positionTick?.cancel()
                        playback.stop()
                    }
                }
            }
        }
    }

    private var transcriptSearchBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Find in transcript", text: $transcriptSearch)
                    .textFieldStyle(.plain)
                if !transcriptSearch.isEmpty {
                    Button {
                        transcriptSearch = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
                    .accessibilityLabel("Clear transcript search")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(
                .primary.opacity(0.055),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .frame(maxWidth: 360)

            // Only a search has a result count. With an empty field the line
            // read as a progress indicator through the transcript, which it
            // was not.
            if !transcriptSearch.isEmpty {
                Text("\(filteredTranscript.count) of \(note.transcript.count) passages")
                    .font(NookType.micro.weight(.medium))
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }

            Spacer()

            Button {
                copyTranscript()
            } label: {
                Label(
                    copyNotice == "Transcript copied" ? "Copied" : "Copy transcript",
                    systemImage: copyNotice == "Transcript copied" ? "checkmark" : "doc.on.doc"
                )
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 38)
        .padding(.vertical, 12)
    }

    private var markdownView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Plain Markdown source")
                        .font(NookType.control)
                    Text(note.fileURL?.lastPathComponent ?? "Unsaved note")
                        .font(NookType.code)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Text("\(markdownCharacterCount) characters")
                    .font(NookType.micro.weight(.medium))
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())

                if let statusMessage = markdownDraft.statusMessage {
                    Label(
                        statusMessage,
                        systemImage: statusMessage == "Saved" ? "checkmark.circle.fill" : "exclamationmark.circle"
                    )
                    .font(NookType.micro.weight(.semibold))
                    .foregroundStyle(statusMessage == "Saved" ? NookPalette.success : NookPalette.danger)
                    .lineLimit(2)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }

                Button("Revert") {
                    markdownDraft.discardChanges()
                }
                .buttonStyle(NookButtonStyle())
                .disabled(!hasMarkdownChanges)

                Button("Save") {
                    saveMarkdown()
                }
                .buttonStyle(
                    NookButtonStyle(
                        tint: NookPalette.accent,
                        isProminent: true
                    )
                )
                .disabled(!hasMarkdownChanges)
                .keyboardShortcut(
                    shortcuts.binding(for: .saveNote).keyEquivalent,
                    modifiers: shortcuts.binding(for: .saveNote).eventModifiers
                )
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 13)

            SoftDivider()

            // Source is still prose to read. Full-pane lines ran past 200
            // characters on a wide window, which no one tracks by eye, so the
            // column is capped near a hundred and centred like a page.
            TextEditor(text: $markdownDraft.rawMarkdown)
                .font(NookType.code)
                .lineSpacing(3)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 28)
                .padding(.vertical, 20)
                .frame(maxWidth: Self.markdownColumnWidth)
                .frame(maxWidth: .infinity)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.66))
        }
    }

    /// Roughly a hundred monospaced characters at `NookType.code`, plus the
    /// editor's own horizontal padding.
    private static let markdownColumnWidth: CGFloat = 716

    private var hasMarkdownChanges: Bool {
        markdownDraft.noteID == note.id && markdownDraft.hasChanges
    }

    /// Writes the My notes field, from the button, from leaving the field, or
    /// from the view going away.
    ///
    /// Called on every exit rather than only from the button. The words used
    /// to live in this view's own state, so a selection change, a meeting
    /// starting by itself, or a quit destroyed anything not explicitly saved,
    /// with no warning and nothing to undo.
    private func savePersonalNotes() {
        guard personalNotes.noteID == note.id, personalNotes.hasChanges else {
            return
        }
        do {
            let saved = try personalNotes.save(note: note, store: store)
            markdownDraft.refresh(for: saved, store: store)
            Task {
                try? await Task.sleep(for: .seconds(2))
                guard personalNotes.statusMessage == "Saved" else { return }
                withAnimation(.easeOut(duration: 0.18)) {
                    personalNotes.statusMessage = nil
                }
            }
        } catch {
            // Loud as well as inline: the field may already be off screen by
            // the time this runs, and a save that did not happen is the one
            // thing the user has to know about.
            personalNotes.statusMessage = error.localizedDescription
            showCopyNotice(error.localizedDescription, severity: .failure)
        }
    }

    /// Re-runs the structured summary over this note's own transcript.
    ///
    /// For every meeting whose write-up lost the model lottery: Apple
    /// Intelligence was off, busy, or declined, and the note saved with only
    /// transcript highlights. The failure named a cause; this is the remedy.
    private func regenerateSummary() {
        guard SummaryRegenerator.isAvailable(for: note),
              !markdownDraft.hasChanges,
              regenerationTask == nil
        else { return }

        // The save below rewrites the whole file from the store's freshest
        // copy of the note. Words still sitting in the My notes draft would
        // be overwritten by that copy, so they get their save first, and a
        // refused save stops everything rather than losing words.
        if personalNotes.noteID == note.id, personalNotes.hasChanges {
            do {
                _ = try personalNotes.save(note: note, store: store)
            } catch {
                showCopyNotice(
                    "My notes couldn’t be saved, so the summary was left unchanged.",
                    severity: .failure
                )
                return
            }
        }

        guard let current = store.notes.first(where: { $0.id == note.id }) else {
            showCopyNotice("This note is no longer in the library.", severity: .failure)
            return
        }

        // Something visible before the first part reports, which on a long
        // meeting takes a model round-trip.
        regenerationStage = .condensing(pass: 1, part: 0, total: 0)
        regenerationTask = Task { @MainActor in
            let stageHandler: SummaryStageHandler = { stage in
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    regenerationStage = stage
                }
            }
            let outcome = await SummaryRegenerator.regenerate(
                current,
                using: SummaryService(),
                onStage: stageHandler
            )
            guard !Task.isCancelled else { return }
            finishSummaryRegeneration(outcome, startingFrom: current)
        }
    }

    private var isRegenerating: Bool { regenerationStage != nil }

    /// The gist prose steps aside while the write-up runs; the lists below
    /// stay, so what the user had remains readable until the new one lands.
    @ViewBuilder
    private var regenerationStatusCard: some View {
        if let stage = regenerationStage {
            HStack(spacing: 14) {
                NookPresence(state: .thinking, size: 30)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(RegenerationCopy.headline(for: stage))
                        .font(NookType.bodyEmphasized)
                    Text(RegenerationCopy.detail(for: stage))
                        .font(NookType.caption)
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }

                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                NookPalette.accent.opacity(0.07),
                in: RoundedRectangle(
                    cornerRadius: NookRadius.surface,
                    style: .continuous
                )
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: NookRadius.surface,
                    style: .continuous
                )
                .stroke(NookPalette.accent.opacity(0.16), lineWidth: 0.7)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                RegenerationCopy.headline(for: stage) + ", "
                    + RegenerationCopy.detail(for: stage)
            )
        }
    }

    private func finishSummaryRegeneration(
        _ outcome: SummaryRegenerator.Outcome,
        startingFrom starting: MeetingNote
    ) {
        regenerationTask = nil
        regenerationStage = nil
        switch outcome {
        case .regenerated(let updated):
            do {
                guard let latest = store.notes.first(where: { $0.id == updated.id })
                else {
                    showCopyNotice(
                        "This note is no longer in the library.",
                        severity: .failure
                    )
                    return
                }
                let merged = SummaryRegenerator.mergingGeneratedFields(
                    from: updated,
                    startingFrom: starting,
                    into: latest
                )
                let saved = try store.save(merged)
                if markdownDraft.noteID == saved.id {
                    markdownDraft.refresh(for: saved, store: store)
                }
                reloadChecklist()
                showCopyNotice("Summary regenerated")
            } catch {
                showCopyNotice(error.localizedDescription, severity: .failure)
            }
        case .retained(let reason):
            if let reason {
                showCopyNotice(reason.userSentence, severity: .failure)
            } else {
                showCopyNotice(
                    "There is no transcript here to summarize.",
                    severity: .info
                )
            }
        }
    }

    private func cancelSummaryRegeneration() {
        regenerationTask?.cancel()
        regenerationTask = nil
        regenerationStage = nil
    }

    private func beginTitleEditing() {
        guard !isEditingTitle else { return }
        guard canRenameTitle else {
            showCopyNotice(
                DetailRenamePolicy.markdownDraftBlockedMessage,
                severity: .info
            )
            return
        }
        titleAtEditStart = note.title
        titleDraft = note.title
        isEditingTitle = true
    }

    /// Requests focus after the conditional editor has been inserted, then
    /// selects its text so a deliberate Rename starts ready to replace.
    private func focusAndSelectTitle() {
        titleFieldFocused = true
        Task { @MainActor in
            // The field editor is created after SwiftUI inserts the TextField.
            await Task.yield()
            guard isEditingTitle, titleFieldFocused else { return }
            guard let window = NSApp.keyWindow else { return }
            if let textView = window.firstResponder as? NSTextView,
               textView.isFieldEditor {
                textView.selectAll(nil)
            }
        }
    }

    private func cancelTitleEditing() {
        guard isEditingTitle else { return }
        titleDraft = titleAtEditStart
        endTitleEditing()
    }

    private func endTitleEditing() {
        // Leave edit mode before releasing focus. This prevents the focus
        // observer from treating our own exit as a second save request.
        isEditingTitle = false
        titleFieldFocused = false
    }

    private func saveTitle() {
        guard isEditingTitle else { return }

        // Markdown edits may have started after Rename was entered. Never
        // rewrite the file underneath that draft: require an explicit Save or
        // Revert first, then let the user intentionally begin again.
        guard canRenameTitle else {
            titleDraft = titleAtEditStart
            endTitleEditing()
            showCopyNotice(
                DetailRenamePolicy.markdownDraftBlockedMessage,
                severity: .info
            )
            return
        }

        let title = titleDraft.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !title.isEmpty else {
            titleDraft = titleAtEditStart
            endTitleEditing()
            showCopyNotice("Title cannot be empty", severity: .failure)
            return
        }
        guard title != titleAtEditStart else {
            endTitleEditing()
            return
        }

        var updatedNote = note
        updatedNote.title = title
        do {
            let saved = try store.save(updatedNote)
            titleDraft = saved.title
            titleAtEditStart = saved.title
            markdownDraft.refresh(for: saved, store: store)
            showCopyNotice("Title saved")
            endTitleEditing()
        } catch {
            titleDraft = titleAtEditStart
            // A failure in a success banner reads as a confirmation, and the
            // typed title has just been reverted under the user.
            showCopyNotice("Title couldn’t be saved", severity: .failure)
            endTitleEditing()
        }
    }

    private func saveMarkdown() {
        do {
            try markdownDraft.save(note: note, store: store)
            Task {
                try? await Task.sleep(for: .seconds(2))
                guard markdownDraft.statusMessage == "Saved" else { return }
                withAnimation(.easeOut(duration: 0.18)) {
                    markdownDraft.statusMessage = nil
                }
            }
        } catch {
            markdownDraft.statusMessage = error.localizedDescription
        }
    }

    /// File naming is a separate, explicit action from changing a note's
    /// display title. The store owns collision handling and keeps the move
    /// reversible through Finder, while this guard keeps unsaved or external
    /// paths out of the menu action.
    private var canRenameManagedFile: Bool {
        guard let fileURL = note.fileURL
            ?? store.notes.first(where: { $0.id == note.id })?.fileURL
        else { return false }
        let standardized = fileURL.standardizedFileURL
        let hasManagedFile = standardized.deletingLastPathComponent()
            == store.storageURL.standardizedFileURL
            && FileManager.default.fileExists(atPath: standardized.path)
        return DetailRenamePolicy.allowsFileRename(
            hasMarkdownChanges: markdownDraft.hasChanges,
            hasManagedFile: hasManagedFile
        )
    }

    private func renameManagedFile() {
        guard !markdownDraft.hasChanges else {
            showCopyNotice(
                DetailRenamePolicy.markdownDraftBlockedMessage,
                severity: .info
            )
            return
        }
        do {
            // A title save can publish just before this menu action runs.
            // Use the store's freshest copy so an explicit file rename uses
            // the title the user just committed, not the header's old value.
            let current = store.notes.first(where: { $0.id == note.id }) ?? note
            let saved = try store.renameManagedFile(for: current)
            if markdownDraft.noteID == saved.id {
                markdownDraft.refresh(for: saved, store: store)
            }
            showCopyNotice("File renamed to match title")
        } catch {
            showCopyNotice(error.localizedDescription, severity: .failure)
        }
    }

    private func copyMarkdown() {
        NSPasteboard.general.clearContents()
        let markdown = if markdownDraft.noteID == note.id {
            markdownDraft.rawMarkdown
        } else {
            // A clipboard copy may fall back to the in-memory form; only
            // something that can be saved back needs the file to be readable.
            (try? store.rawMarkdown(for: note)) ?? MarkdownCodec.encode(note)
        }
        NSPasteboard.general.setString(markdown, forType: .string)
        showCopyNotice("Markdown copied")
    }

    private func copyTranscript() {
        let transcript = note.transcript.map {
            "[\($0.timestamp)] \($0.source.label): \($0.text)"
        }.joined(separator: "\n\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcript, forType: .string)
        showCopyNotice("Transcript copied")
    }

    private func showCopyNotice(
        _ message: String,
        severity: CopyConfirmationBanner.Severity = .success
    ) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
            copyNotice = message
            copyNoticeSeverity = severity
        }
        // Failures name a problem worth reading carefully, so they dwell
        // longer than confirmations.
        let dwell = severity == .success ? 1.8 : 4.0
        Task {
            try? await Task.sleep(for: .seconds(dwell))
            guard copyNotice == message else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                copyNotice = nil
            }
        }
    }
}

/// The "Record into this note" menu item, isolated into its own view so it
/// is the only piece of `MeetingDetailView` that observes the coordinator.
///
/// `MeetingCoordinator` publishes audio level (up to ~12 Hz) and live
/// transcript (up to ~10 Hz) while a meeting records. `MeetingDetailView`
/// used to hold `@EnvironmentObject var meeting` just for this one menu
/// item, which meant browsing any note while a meeting recorded in the
/// background re-ran the whole detail pane, `ViewThatFits` header and all,
/// at the meter's rate. Isolating the one thing that actually needs the
/// coordinator here means those ticks land on this small, rarely-visible
/// menu item instead.
private struct RecordIntoNoteMenuItem: View {
    @EnvironmentObject private var meeting: MeetingCoordinator
    let note: MeetingNote

    var body: some View {
        Button {
            meeting.continueRecording(into: note)
        } label: {
            Label("Record into this note", systemImage: "record.circle")
        }
        .disabled(!canRecordIntoThisNote)
        .help(
            note.kind == .spoken
                ? "Record a meeting into this note and keep its spoken words"
                : "Appends the next recording to this note instead of creating a new one"
        )
    }

    /// Recording can only join a note from a quiet state; the coordinator
    /// guards this too, and this keeps the menu item honest about it.
    private var canRecordIntoThisNote: Bool {
        if meeting.phase.isRecording { return false }
        if case .processing = meeting.phase { return false }
        return true
    }
}

private struct DetailTabBar: View {
    @Binding var selection: DetailTab
    let showsTranscript: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        selection: Binding<DetailTab>,
        showsTranscript: Bool = true
    ) {
        _selection = selection
        self.showsTranscript = showsTranscript
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(DetailTab.allCases.filter { tab in
                showsTranscript || tab != .transcript
            }) { tab in
                Button {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                        selection = tab
                    }
                } label: {
                    Label(tab.rawValue, systemImage: tab.symbol)
                        .font(NookType.control)
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .foregroundStyle(
                            selection == tab
                                ? Color(nsColor: .labelColor)
                                : Color(nsColor: .secondaryLabelColor)
                        )
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(
                                    selection == tab
                                        ? NookPalette.accent
                                        : Color.clear
                                )
                                .frame(height: 2)
                        }
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .accessibilityAddTraits(selection == tab ? .isSelected : [])
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(.primary.opacity(0.08))
                .frame(height: 0.5)
        }
    }
}

private struct EditorialSection<Content: View>: View {
    let title: String
    let symbol: String
    let tint: Color
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            NookSectionLabel(title: title, symbol: symbol, tint: tint)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TranscriptRow: View {
    let segment: TranscriptSegment
    /// Adjacent rows often come from the same source. The timestamp keeps
    /// its column even when this badge is hidden, so every row remains a
    /// stable target for search, moments, and playback.
    var showsSourceBadge = true
    var isFlagged = false
    var isPlaying = false
    /// Present only when kept audio exists; tapping plays this line.
    var playAction: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .trailing, spacing: 7) {
                if showsSourceBadge {
                    SourceBadge(source: segment.source)
                } else {
                    Color.clear
                        .frame(height: 16)
                        .accessibilityHidden(true)
                }
                Text(segment.timestamp)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 94, alignment: .trailing)

            Text(segment.text)
                .font(NookType.transcript)
                .lineSpacing(5)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            if isFlagged {
                Image(systemName: "flag.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(NookPalette.accent)
                    .help("You flagged this moment")
                    .accessibilityLabel("Flagged moment")
            }

            if let playAction {
                Button(action: playAction) {
                    Image(
                        systemName: isPlaying
                            ? "speaker.wave.2.fill" : "play"
                    )
                    .font(.system(size: 11))
                    .foregroundStyle(
                        isPlaying ? NookPalette.accent : Color.secondary
                    )
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Play from here")
                .accessibilityLabel(
                    "Play recording from \(segment.timestamp)"
                )
            }
        }
        .padding(.vertical, 16)
        .padding(.horizontal, isPlaying ? 8 : 0)
        .background(
            RoundedRectangle(cornerRadius: 8).fill(
                isPlaying ? NookPalette.accent.opacity(0.08) : Color.clear
            )
        )
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            SoftDivider()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(segment.source.label): \(segment.text)")
        .accessibilityValue(segment.timestamp)
    }
}

/// Keeps file-backed rename actions away from a Markdown draft that is based
/// on the old file. Saving or reverting first gives the next rename a fresh
/// baseline and avoids silently discarding typed Markdown.
enum DetailRenamePolicy {
    static let markdownDraftBlockedMessage =
        "Save or revert Markdown edits before renaming"

    static func allowsTitleRename(hasMarkdownChanges: Bool) -> Bool {
        !hasMarkdownChanges
    }

    static func allowsFileRename(
        hasMarkdownChanges: Bool,
        hasManagedFile: Bool
    ) -> Bool {
        hasManagedFile && !hasMarkdownChanges
    }
}

/// Builds visual breaks for long prose without changing the words a note
/// contains. A generated summary that is short, sparse, or difficult to split
/// safely remains one exact string; paragraphing is only a reading aid.
enum DetailSummaryParagraphPolicy {
    /// Summaries under this size stay visually identical to the existing
    /// single Text. The threshold avoids introducing a break into a compact
    /// explanation where the extra whitespace would be distracting.
    static let minimumWordCount = 80
    /// At this size three balanced paragraphs are easier to scan than two
    /// dense blocks. The policy never forces a split without a safe sentence
    /// boundary, so a model output with unusual punctuation stays untouched.
    static let threeParagraphWordCount = 180
    static let minimumWordsPerParagraph = 18

    static func paragraphs(for text: String) -> [String] {
        let totalWords = wordCount(in: text)
        guard totalWords >= minimumWordCount else { return [text] }

        let paragraphCount = totalWords >= threeParagraphWordCount ? 3 : 2
        if let paragraphs = splitParagraphs(
            in: text,
            totalWords: totalWords,
            paragraphCount: paragraphCount,
            boundaries: sentenceBoundaries(in: text)
        ) {
            return paragraphs
        }

        // Some generated summaries contain one long sentence joined by
        // semicolons. Use those clause boundaries only after sentence
        // segmentation could not produce the requested paragraph count.
        return splitParagraphs(
            in: text,
            totalWords: totalWords,
            paragraphCount: paragraphCount,
            boundaries: semicolonBoundaries(in: text)
        ) ?? [text]
    }

    private static func splitParagraphs(
        in text: String,
        totalWords: Int,
        paragraphCount: Int,
        boundaries: [String.Index]
    ) -> [String]? {
        guard boundaries.count >= paragraphCount - 1 else { return nil }

        var splitPoints: [String.Index] = []
        var start = text.startIndex
        for splitNumber in 1..<paragraphCount {
            let targetWordCount = totalWords * splitNumber / paragraphCount
            let paragraphsAfterSplit = paragraphCount - splitNumber
            let candidates = boundaries.filter { boundary in
                guard boundary != text.endIndex,
                      text.distance(from: start, to: boundary) > 0
                else { return false }

                let wordsBeforeBoundary = wordCount(in: text[start..<boundary])
                let wordsAfterBoundary = wordCount(in: text[boundary..<text.endIndex])
                return wordsBeforeBoundary >= minimumWordsPerParagraph
                    && wordsAfterBoundary
                        >= minimumWordsPerParagraph * paragraphsAfterSplit
            }
            guard let chosen = candidates.min(by: { lhs, rhs in
                let lhsDistance = abs(
                    wordCount(in: text[text.startIndex..<lhs])
                        - targetWordCount
                )
                let rhsDistance = abs(
                    wordCount(in: text[text.startIndex..<rhs])
                        - targetWordCount
                )
                return lhsDistance < rhsDistance
            }) else {
                return nil
            }
            splitPoints.append(chosen)
            start = chosen
        }

        var result: [String] = []
        var pieceStart = text.startIndex
        for splitPoint in splitPoints {
            result.append(String(text[pieceStart..<splitPoint]))
            pieceStart = splitPoint
        }
        result.append(String(text[pieceStart..<text.endIndex]))

        guard result.count == paragraphCount,
              result.allSatisfy({
                  wordCount(in: $0) >= minimumWordsPerParagraph
              }),
              result.joined() == text
        else {
            return nil
        }
        return result
    }

    private static func wordCount(in text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    private static func wordCount(in text: Substring) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    /// A break is accepted only after terminal punctuation, optional closing
    /// quotes/brackets, and whitespace followed by an uppercase or numeric
    /// sentence start. This deliberately favors leaving a dense paragraph
    /// intact over splitting a decimal, abbreviation, or lowercase fragment.
    private static func sentenceBoundaries(in text: String) -> [String.Index] {
        var boundaries: [String.Index] = []
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]
            guard ".!?".contains(character) else {
                index = text.index(after: index)
                continue
            }

            let previous = index > text.startIndex
                ? text[text.index(before: index)]
                : nil
            let immediateNext = text.index(after: index) < text.endIndex
                ? text[text.index(after: index)]
                : nil
            // Ellipses are not sentence boundaries on their own. A decimal
            // point is also not a sentence boundary when digits surround it.
            if character == ".",
               previous == "." || immediateNext == "."
            {
                index = text.index(after: index)
                continue
            }
            if isDecimalPoint(in: text, at: index) {
                index = text.index(after: index)
                continue
            }

            var afterPunctuation = text.index(after: index)
            while afterPunctuation < text.endIndex,
                  isClosingPunctuation(text[afterPunctuation])
            {
                afterPunctuation = text.index(after: afterPunctuation)
            }

            var afterWhitespace = afterPunctuation
            while afterWhitespace < text.endIndex,
                  text[afterWhitespace].isWhitespace
            {
                afterWhitespace = text.index(after: afterWhitespace)
            }

            if afterWhitespace == text.endIndex {
                boundaries.append(afterWhitespace)
            } else if afterWhitespace != afterPunctuation,
                      startsSentence(text[afterWhitespace]),
                      !isAbbreviation(in: text, at: index)
            {
                boundaries.append(afterWhitespace)
            }

            index = text.index(after: index)
        }
        return boundaries
    }

    /// Returns whitespace-separated clause starts after semicolons. These are
    /// a deliberately weaker fallback than sentence boundaries, used only
    /// when the prose has no usable sentence-level split.
    private static func semicolonBoundaries(in text: String) -> [String.Index] {
        var boundaries: [String.Index] = []
        var index = text.startIndex

        while index < text.endIndex {
            guard text[index] == ";" else {
                index = text.index(after: index)
                continue
            }

            var afterWhitespace = text.index(after: index)
            while afterWhitespace < text.endIndex,
                  text[afterWhitespace].isWhitespace
            {
                afterWhitespace = text.index(after: afterWhitespace)
            }
            if afterWhitespace != text.endIndex {
                boundaries.append(afterWhitespace)
            }
            index = text.index(after: index)
        }
        return boundaries
    }

    private static func startsSentence(_ character: Character) -> Bool {
        character.isUppercase || character.isNumber
    }

    private static func isClosingPunctuation(_ character: Character) -> Bool {
        ")]}»”’'\"".contains(character)
    }

    private static func isDecimalPoint(
        in text: String,
        at index: String.Index
    ) -> Bool {
        guard text[index] == ".",
              index > text.startIndex,
              text.index(after: index) < text.endIndex
        else { return false }
        return text[text.index(before: index)].isNumber
            && text[text.index(after: index)].isNumber
    }

    private static let commonAbbreviations: Set<String> = [
        "approx", "dept", "dr", "etc", "fig", "inc", "jan", "feb",
        "mar", "apr", "jun", "jul", "aug", "sep", "sept", "oct",
        "nov", "dec", "max", "min", "mr", "mrs", "ms", "mt", "no",
        "prof", "sr", "jr", "st", "vs"
    ]

    private static func isAbbreviation(
        in text: String,
        at punctuation: String.Index
    ) -> Bool {
        guard text[punctuation] == "." else { return false }
        let before = text[..<punctuation]
        let token = before.split { character in
            character.isWhitespace || character.isPunctuation
        }.last.map { String($0).lowercased() }
        if let token, commonAbbreviations.contains(token) {
            return true
        }

        let trimmed = String(before)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return ["e.g", "i.e", "u.s", "a.m", "p.m"].contains { dotted in
            trimmed == dotted || trimmed.hasSuffix(" " + dotted)
        }
    }
}

/// Decides which transcript rows need a repeated source badge. It works on
/// the rows being rendered, not the full note, so a search result always
/// introduces its own source context.
enum TranscriptBadgeGroupingPolicy {
    /// Transcript rows are already coalesced at a much shorter interval. This
    /// larger presentation window keeps natural consecutive utterances light
    /// while making a real pause visible again.
    static let maximumAdjacentGap: TimeInterval = 15

    static func visibleBadgeIDs(
        in segments: [TranscriptSegment],
        sessions: [MeetingSession] = []
    ) -> Set<UUID> {
        guard let first = segments.first else { return [] }
        var visible: Set<UUID> = [first.id]
        var previous = first
        let sessionBoundaryOffsets = sessionBoundaryOffsets(for: sessions)

        for segment in segments.dropFirst() {
            let crossesSessionBoundary = sessionBoundaryOffsets.contains { boundary in
                previous.startTime < boundary
                    && segment.startTime >= boundary
            }
            let startsAfterPrevious = segment.startTime >= previous.startTime
            let previousEnd = previous.startTime + max(0, previous.duration)
            let gap = segment.startTime - previousEnd
            let meaningfulGap = !startsAfterPrevious || gap > maximumAdjacentGap
            if segment.source != previous.source
                || meaningfulGap
                || crossesSessionBoundary
            {
                visible.insert(segment.id)
            }
            previous = segment
        }
        return visible
    }

    /// Session IDs are intentionally absent from the current model. Saved
    /// transcript lines use the same cumulative-duration clock as Markdown's
    /// session dividers, so those offsets are the only truthful boundary
    /// signal available to this presentation policy.
    private static func sessionBoundaryOffsets(
        for sessions: [MeetingSession]
    ) -> [TimeInterval] {
        guard sessions.count > 1 else { return [] }
        var offsets: [TimeInterval] = []
        var elapsed: TimeInterval = 0
        for session in sessions.dropLast() {
            elapsed += session.duration
            offsets.append(elapsed)
        }
        return offsets
    }
}

private extension MeetingNote {
    /// Spoken notes store their original wording in `summary`, while a
    /// recorded meeting stores its words in transcript segments. Counting
    /// the appropriate source keeps the header honest for both shapes.
    var detailContentWordCount: Int {
        let source: String
        if kind == .spoken,
           !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            source = summary
        } else {
            source = transcript.map(\.text).joined(separator: " ")
        }
        return source.split(whereSeparator: \.isWhitespace).count
    }
}
