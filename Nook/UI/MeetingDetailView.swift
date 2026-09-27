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

/// Separate progress text and Cancel retain their own accessibility elements.
/// The existing write-up returns immediately when the request is canceled.
struct SummaryRegenerationProgressCard: View {
    let stage: SummaryStage
    let onCancel: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// A status line, as Mail and Music report background work: a small
    /// spinner, what is happening, and a way to stop it. No card around it.
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(RegenerationCopy.headline(for: stage))
                    .font(.headline)
                Text(RegenerationCopy.detail(for: stage))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(reduceMotion ? .identity : .numericText())
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            Button("Cancel Summary", action: onCancel)
                .controlSize(.small)
                .accessibilityLabel("Cancel summary regeneration")
                .help("Keep the saved transcript and notes, and stop accepting this summary result.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

struct MeetingDetailView: View {
    @EnvironmentObject private var store: MarkdownStore
    @EnvironmentObject private var markdownDraft: MarkdownDraftController
    @EnvironmentObject private var personalNotes: PersonalNotesDraftController
    @EnvironmentObject private var shortcuts: ShortcutStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let note: MeetingNote
    private let keepsSummaryOnNavigation: Bool

    @State private var tab: DetailTab = .notes
    @State private var transcriptSearch = ""
    /// A moment the user asked to see; consumed by the transcript scroll.
    @State private var requestedMomentOffset: TimeInterval?
    /// Kept audio for this note, if any, enabling transcript playback.
    @StateObject private var playback = AudioPlaybackController()
    @State private var copyNotice = CopyNoticeState()
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
    /// Request identity protects progress and saves even when cancellation or
    /// a folder change reaches this view after the underlying model returns.
    @StateObject private var regeneration = SummaryRegenerationSession()
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
    @State private var reviewingSummaryItem: SummaryItemReviewSession?
    @State private var showsFollowUpDraft = false
    /// The speaker being named, and the name being typed for them.
    @State private var namingSpeaker: String?
    @State private var speakerNameDraft = ""
    @State private var lastSummaryReview: SummaryItemReviewSession?
    @State private var reviewSentences: [SummaryReviewItem] = []
    @FocusState private var summaryReviewFocus: String?
    @AccessibilityFocusState private var summaryReviewAccessibilityFocus: String?

    init(
        note: MeetingNote,
        initialTab: DetailTab = .notes,
        initialTranscriptSearch: String = "",
        summarySession: SummaryRegenerationSession? = nil
    ) {
        self.note = note
        keepsSummaryOnNavigation = summarySession != nil
        _regeneration = StateObject(wrappedValue: summarySession ?? SummaryRegenerationSession())
        let startingTab = note.kind == .spoken
            && note.transcript.isEmpty
            && initialTab == .transcript
            ? .notes
            : initialTab
        _tab = State(initialValue: startingTab)
        _transcriptSearch = State(initialValue: initialTranscriptSearch)
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
                savedSummaryStatus

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
        .nookNotice(copyNotice.current) { id in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                copyNotice.dismiss(id: id)
            }
        }
        .onAppear {
            reviewSentences = SummaryReviewItem.sentences(in: note.summary)
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
            reviewSentences = SummaryReviewItem.sentences(in: newValue.summary)
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
        .onChange(of: store.storageGeneration) { _, _ in
            regeneration.cancel()
            reviewingSummaryItem?.cancel()
            reviewingSummaryItem = nil
            lastSummaryReview = nil
        }
        .onChange(of: note.libraryIdentity) { _, _ in
            regeneration.cancel()
            reviewingSummaryItem?.cancel()
            reviewingSummaryItem = nil
            lastSummaryReview = nil
        }
        .onChange(of: regeneration.completion?.id) { _, _ in
            if let completion = regeneration.completion {
                finishSummaryRegeneration(completion.result)
            }
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
            reviewingSummaryItem?.cancel()
            if !keepsSummaryOnNavigation { regeneration.cancel() }
            saveTitle()
            savePersonalNotes()
        }
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.24),
            value: tab
        )
        .toolbar { detailToolbar }
        .sheet(isPresented: $showsFollowUpDraft) {
            FollowUpDraftView(note: note)
        }
        .alert(
            "Name \(namingSpeaker ?? "Speaker")",
            isPresented: Binding(
                get: { namingSpeaker != nil },
                set: { if !$0 { namingSpeaker = nil } }
            )
        ) {
            TextField("Name", text: $speakerNameDraft)
            Button("Cancel", role: .cancel) { namingSpeaker = nil }
            Button("Save") { saveSpeakerName() }
        } message: {
            Text("Every line this person said in this meeting will use the name. It is saved in the note.")
        }
        .sheet(item: $reviewingSummaryItem, onDismiss: returnFromSummaryReview) { session in
            SummaryItemReviewView(session: session)
        }
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

    /// Title and metadata only. The view switcher and actions live in the
    /// window toolbar, where every Mac document window keeps them.
    private var documentHeader: some View {
        titleBlock
            .nookReadableColumn()
            .padding(.top, 28)
            .padding(.bottom, 4)
    }

    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            DetailTabBar(selection: $tab, showsTranscript: showsTranscriptTab)
        }
        ToolbarItem(placement: .automatic) {
            // The note itself: a portable Markdown file that opens anywhere.
            if let fileURL = note.fileURL {
                ShareLink(item: fileURL, preview: SharePreview(note.title)) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .help("Share this note")
            }
        }
        ToolbarItem(placement: .automatic) {
            detailActions
        }
    }

    private var detailActions: some View {
        Menu {
            Button {
                beginTitleEditing()
            } label: {
                Label("Rename…", systemImage: "pencil")
            }
            .disabled(!canRenameTitle || isEditingTitle)
            .help(titleRenameHelp)

            Divider()

            if note.kind != .digest {
                Button {
                    showsFollowUpDraft = true
                } label: {
                    Label("Draft Follow-up…", systemImage: "envelope")
                }
                .help("Write a recap of this meeting to review and send yourself")
            }

            ShareLink(
                item: FollowUpDraft.make(from: note, format: .chat).body,
                subject: Text(note.title),
                preview: SharePreview(note.title)
            ) {
                Label("Share Summary…", systemImage: "text.bubble")
            }

            if let fileURL = note.fileURL {
                ShareLink(item: fileURL, preview: SharePreview(note.title)) {
                    Label("Share Markdown File…", systemImage: "doc.text")
                }
            }

            Divider()

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
            Label(detailActionsLabel, systemImage: "ellipsis.circle")
        }
        .menuIndicator(.hidden)
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
                // Renamed the way Finder and Voice Memos rename: double-click
                // the name, or choose Rename from the actions menu. A pencil
                // beside every title was chrome for a rare action.
                Text(note.title)
                    .font(NookType.title)
                    .tracking(-0.45)
                    .lineLimit(2)
                    // Not selectable: double-click belongs to rename here, and
                    // word selection would compete for the same gesture.
                    .onTapGesture(count: 2) {
                        if canRenameTitle { beginTitleEditing() }
                    }
                    .help(canRenameTitle ? "Double-click to rename" : titleRenameHelp)
                    .accessibilityLabel("\(titleLabel): \(note.title)")
                    .accessibilityHint(titleReadOnlyHint)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityAction(named: renameLabel) {
                        if canRenameTitle { beginTitleEditing() }
                    }
            }

            detailMetadata
        }
    }

    /// One quiet line with middle dots, the way Photos and Music write
    /// details, rather than a row of separately spaced labels.
    private var detailMetadata: some View {
        Text(metadataParts.joined(separator: " · "))
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
    }

    private var metadataParts: [String] {
        var parts: [String] = []
        if note.kind == .spoken {
            parts.append("Spoken note")
            parts.append(
                "Created " + note.startedAt.formatted(date: .abbreviated, time: .shortened)
            )
        } else {
            parts.append(note.startedAt.formatted(date: .abbreviated, time: .shortened))
            parts.append(note.durationLabel)
            if !note.sourceApp.isEmpty { parts.append(note.sourceApp) }
        }
        parts.append("\(contentWordCount) words")
        return parts
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
                if hasPrimaryContent || (note.kind == .meeting && !note.transcript.isEmpty) {
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
                                    summaryReviewButton(.list(.keyPoint, index: index, in: note))
                                }
                                .accessibilityElement(children: .contain)
                                .modifier(PublishesRowHover())
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
                            ForEach(Array(note.decisions.enumerated()), id: \.offset) { index, decision in
                                HStack(alignment: .top, spacing: 13) {
                                    // Not a tick in a circle. That is exactly
                                    // the action-item control one section
                                    // below, and a decision read as a task
                                    // somebody had already completed.
                                    Image(systemName: "arrow.turn.down.right")
                                        .font(NookType.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 20, height: 20)
                                        .accessibilityHidden(true)
                                    Text(decision)
                                        .font(NookType.transcript)
                                        .lineSpacing(4)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    summaryReviewButton(.list(.decision, index: index, in: note))
                                }
                                .padding(.vertical, 2)
                                .accessibilityElement(children: .contain)
                                .modifier(PublishesRowHover())
                            }
                        }
                    }
                }

                if !checklistLines.isEmpty {
                    actionItemsSection
                }

                if note.kind == .meeting, !note.openQuestions.isEmpty {
                    EditorialSection(title: "Open questions", symbol: "questionmark.bubble",
                                     tint: NookPalette.accent) {
                        VStack(alignment: .leading, spacing: 16) {
                            ForEach(Array(note.openQuestions.enumerated()), id: \.offset) { index, question in
                                HStack(alignment: .top) {
                                    Text(question)
                                        .font(NookType.transcript)
                                        .textSelection(.enabled)
                                        .accessibilityLabel("Open question \(index + 1): \(question)")
                                    Spacer(minLength: 0)
                                    summaryReviewButton(.list(.question, index: index, in: note))
                                }
                                .modifier(PublishesRowHover())
                            }
                        }
                    }
                }

                if note.kind != .spoken,
                   checklistLines.isEmpty,
                   note.keyPoints.isEmpty,
                   note.decisions.isEmpty,
                   note.actionItems.isEmpty {
                    Label(
                        SummaryFallback.emptyStructuredMessage(provenance: note.summaryProvenance, pending: note.summaryPending),
                        systemImage: "leaf"
                    )
                    .font(NookType.body)
                    .foregroundStyle(.secondary)
                    .padding(.top, -16)
                }
            }
            .padding(.vertical, 28)
            .nookReadableColumn()
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
                            .font(.system(size: 15))
                            .foregroundStyle(
                                line.isChecked
                                    ? AnyShapeStyle(NookPalette.accent)
                                    : AnyShapeStyle(.secondary)
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

                        let parsed = ActionItemOwner.parse(line.displayText)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(parsed.displayTask)
                                .font(NookType.transcript)
                                .lineSpacing(4)
                                .strikethrough(line.isChecked)
                                .foregroundStyle(
                                    line.isChecked ? .secondary : Color(nsColor: .labelColor)
                                )
                                .textSelection(.enabled)
                            // The owner, read from the item's own wording.
                            if let owner = parsed.owner {
                                Label(owner, systemImage: "person.fill")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .labelStyle(.titleAndIcon)
                                    .accessibilityLabel("Owner: \(owner)")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        if let dueDate = line.dueDate {
                            Text("Due \(dueDate.formatted(.dateTime.month().day()))")
                                .font(NookType.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        // File line indices can differ from decoded list indices
                        // for hand-edited Markdown. Never target a different item.
                        if note.actionItems.indices.contains(line.index),
                           note.actionItems[line.index].utf8.elementsEqual(line.text.utf8) {
                            summaryReviewButton(.list(.action, index: line.index, in: note))
                        }
                    }
                    .padding(.vertical, 8)
                    .accessibilityElement(children: .contain)
                    .modifier(PublishesRowHover())

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
                        top: 4,
                        leading: 0,
                        bottom: 4,
                        trailing: 0
                    ),
                    lineSpacing: 5
                )
                .disabled(markdownDraft.hasChanges)
                .accessibilityHint(
                    "Saved into the My notes section of this meeting’s Markdown file"
                )
                .frame(minHeight: 44)

                // Nothing to report most of the time, so nothing is drawn.
                // Status and Save appear with an unsaved edit or a result.
                if markdownDraft.hasChanges || personalNotes.hasChanges
                    || personalNotes.statusMessage != nil {
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
                    }

                    Spacer()

                    // Kept even though the field now saves itself. Cmd-S is
                    // what a person reaches for when they want to be sure, and
                    // an autosaving field with no way to ask is a promise you
                    // cannot check. It confirms rather than being the only
                    // path, so forgetting it costs nothing.
                    Button("Save Notes") {
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
                .controlSize(.small)
                .frame(minHeight: 32)
                }
            }
            // No card: like Notes, the page itself is the writing surface.
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
            HStack(alignment: .firstTextBaseline) {
                NookSectionLabel(
                    title: note.kind == .spoken ? "Spoken words"
                        : note.summaryProvenance != nil ? "Fallback write-up" : "The gist",
                    symbol: note.kind == .spoken
                        ? "waveform" : "text.alignleft",
                    tint: NookPalette.accent
                )
                .focusable()
                // The heading is only where focus returns after a review
                // closes. A ring around it on every open read as a bug.
                .focusEffectDisabled()
                .focused($summaryReviewFocus, equals: "summary-section")
                .accessibilityFocused($summaryReviewAccessibilityFocus, equals: "summary-section")

                Spacer(minLength: 12)

                if SummaryRegenerator.isAvailable(for: note) {
                    SummaryRecipeControl(
                        recipe: Binding(get: { note.summaryRecipe }, set: { selectSummaryRecipe($0) }),
                        isEnabled: !markdownDraft.hasChanges && !isRegenerating,
                        regenerate: regenerateSummary
                    )
                }
            }
            summaryProse
        }
    }

    @ViewBuilder
    private var summaryProse: some View {
        if note.kind == .meeting, !reviewSentences.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(reviewSentences) { item in
                    HStack(alignment: .top, spacing: 12) {
                        summaryParagraphText(item.text)
                        summaryReviewButton(item)
                    }
                    .accessibilityElement(children: .contain)
                    .modifier(PublishesRowHover())
                }
            }
        } else if summaryParagraphs.count < 2 {
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
                    ? NookType.spoken
                    : note.summaryProvenance != nil ? NookType.transcript : NookType.editorialSummary
            )
            .lineSpacing(7)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func summaryReviewButton(_ item: SummaryReviewItem?) -> some View {
        if note.kind == .meeting, !note.transcript.isEmpty, let item, item.isCurrent(in: note) {
            Button { beginSummaryReview(item) } label: {
                Image(systemName: "text.quote")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .modifier(RevealedOnRowHover(isFocused: summaryReviewFocus == item.id))
            .accessibilityLabel("Show supporting transcript for \(item.label): \(item.text)")
            .help("Review transcript support or correct this item")
            .disabled(markdownDraft.hasChanges || isRegenerating || isEditingTitle)
            .focused($summaryReviewFocus, equals: item.id)
            .accessibilityFocused($summaryReviewAccessibilityFocus, equals: item.id)
        }
    }

    private func beginSummaryReview(_ item: SummaryReviewItem) {
        guard !markdownDraft.hasChanges, !isRegenerating, !isEditingTitle else { return }
        do {
            if personalNotes.noteID == note.id, personalNotes.hasExactChanges {
                _ = try personalNotes.save(note: note, store: store)
            }
            guard let current = store.uniqueNote(id: note.id),
                  current.libraryIdentity == note.libraryIdentity, item.isCurrent(in: current) else {
                throw SummaryReviewError.changed
            }
            let session = SummaryItemReviewSession(note: current, item: item, generation: store.storageGeneration)
            lastSummaryReview = session
            summaryReviewFocus = nil
            summaryReviewAccessibilityFocus = nil
            reviewingSummaryItem = session
        } catch { showCopyNotice(error.localizedDescription, severity: .failure) }
    }

    private func returnFromSummaryReview() {
        guard let session = lastSummaryReview else { return }
        session.cancel()
        // After removal the same index belongs to a different item. Return to
        // the section, never pretend that different item was the origin.
        let target = session.returnFocusID(in: note)
        summaryReviewFocus = target
        summaryReviewAccessibilityFocus = target
        lastSummaryReview = nil
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
                || $0.speakerLabel.localizedCaseInsensitiveContains(search)
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

    private var playingSegmentID: UUID? {
        guard let audioOffset = playback.activeOffset,
              let offset = AudioPlaybackController.transcriptOffset(
                  for: audioOffset,
                  in: note
              )
        else { return nil }
        guard let segment = segmentCovering(offset: offset),
              AudioPlaybackController.audioOffset(for: segment.startTime, in: note) != nil
        else { return nil }
        return segment.id
    }

    private func playAction(
        for segment: TranscriptSegment,
        audioURL: URL?
    ) -> (() -> Void)? {
        guard let audioURL,
              let offset = AudioPlaybackController.audioOffset(
                  for: segment.startTime,
                  in: note
              )
        else { return nil }
        return { playback.start(url: audioURL, at: offset) }
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

            if let audioOffset = playback.activeOffset,
               let offset = AudioPlaybackController.transcriptOffset(for: audioOffset, in: note),
               let end = AudioPlaybackController.transcriptOffset(for: playback.duration, in: note) {
                Text(
                    "\(Self.clock(offset)) / \(Self.clock(end))"
                )
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .accessibilityLabel("Playback position")
                .accessibilityValue(
                    "\(Self.clock(offset)) of \(Self.clock(end))"
                )
            }

            Spacer()

            Text(note.audioStart > 0
                 ? "Kept audio starts at \(Self.clock(note.audioStart))"
                 : "Kept audio, on this Mac")
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
        // Resolve note-wide state once per update rather than scanning the
        // transcript and touching the filesystem again for every visible row.
        let segments = filteredTranscript
        let flaggedIDs = flaggedSegmentIDs
        let sourceBadgeIDs = transcriptSourceBadgeIDs
        let activeID = playingSegmentID
        let audioURL = keptAudioURL
        return VStack(spacing: 0) {
            transcriptSearchBar
            speakersBar

            // Search filters passages, not the recording. Keep its transport
            // and failures reachable even when no passage matches.
            if let audioURL {
                VStack(alignment: .leading, spacing: 0) {
                    playbackBar(url: audioURL)
                    if let error = playback.lastError {
                        Label(error, systemImage: "exclamationmark.circle")
                            .font(NookType.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.bottom, 12)
                    }
                }
                .padding(.top, 16)
                .nookReadableColumn()
            }

            if segments.isEmpty {
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
                            ForEach(segments) { segment in
                                TranscriptRow(
                                    segment: segment,
                                    showsSourceBadge: sourceBadgeIDs
                                        .contains(segment.id),
                                    isFlagged: flaggedIDs.contains(segment.id),
                                    isPlaying: activeID == segment.id,
                                    playAction: playAction(
                                        for: segment,
                                        audioURL: audioURL
                                    ),
                                    nameSpeaker: beginNamingSpeaker
                                )
                                .id(segment.id)
                            }
                        }
                        .padding(.top, audioURL == nil ? 8 : 0)
                        .padding(.bottom, 16)
                        .nookReadableColumn()
                    }
                    .onChange(of: requestedMomentOffset, initial: true) { _, newValue in
                        guard let offset = newValue,
                              let target = segmentCovering(offset: offset)
                        else { return }
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
                            proxy.scrollTo(target.id, anchor: .center)
                        }
                        requestedMomentOffset = nil
                    }
                }
            }
        }
        .task(id: playback.isPlaying) {
            guard playback.isPlaying else { return }
            // The lifetime belongs to the whole transcript. Filtering down
            // to zero passages must not stop and restart the user's recording.
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(500))
                } catch { return }
                playback.refreshPosition()
            }
        }
        .onDisappear {
            playback.stop()
        }
    }

    private var transcriptSearchBar: some View {
        HStack(spacing: 12) {
            NativeSearchField(prompt: "Find in transcript", text: $transcriptSearch)
                .accessibilityLabel("Find in transcript")
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
                    copyNotice.current?.message == "Transcript copied" ? "Copied" : "Copy Transcript",
                    systemImage: copyNotice.current?.message == "Transcript copied" ? "checkmark" : "doc.on.doc"
                )
            }
            .buttonStyle(.borderless)
        }
        .nookReadableColumn()
        .padding(.vertical, 12)
    }

    private var markdownView: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    // The tab already says Markdown; the file and its size
                    // are the only facts worth a line.
                    Text("\(note.fileURL?.lastPathComponent ?? "Unsaved note") · \(markdownCharacterCount) characters")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .contentTransition(.numericText())

                    Spacer()

                    // Revert and Save appear once there is an edit to act on.
                    // They keep their place so the line does not jump, and
                    // Save keeps Command-S.
                    Button("Revert") {
                        markdownDraft.discardChanges()
                    }
                    .buttonStyle(.bordered)
                    .disabled(!hasMarkdownChanges)
                    .opacity(hasMarkdownChanges ? 1 : 0)
                    .accessibilityHidden(!hasMarkdownChanges)

                    Button("Save") {
                        saveMarkdown()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!hasMarkdownChanges)
                    .opacity(hasMarkdownChanges ? 1 : 0)
                    .accessibilityHidden(!hasMarkdownChanges)
                    .keyboardShortcut(
                        shortcuts.binding(for: .saveNote).keyEquivalent,
                        modifiers: shortcuts.binding(for: .saveNote).eventModifiers
                    )
                }
                .controlSize(.small)

                // The recovery instruction must not compete with the filename,
                // counter, and Save controls for a narrow window's last space.
                if let statusMessage = markdownDraft.statusMessage {
                    Label(
                        statusMessage,
                        systemImage: statusMessage == "Saved" ? "checkmark.circle.fill" : "exclamationmark.circle"
                    )
                    .font(NookType.micro.weight(.semibold))
                    .foregroundStyle(statusMessage == "Saved" ? NookPalette.success : NookPalette.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity.combined(with: .scale(
                        scale: NookMotion.savedStatusScale(reduceMotion: reduceMotion)
                    )))
                }
            }
            .nookReadableColumn()
            .padding(.vertical, 8)

            // Source is still prose to read. Full-pane lines ran past 200
            // characters on a wide window, which no one tracks by eye, so the
            // column is capped near a hundred and centred like a page.
            TextEditor(text: $markdownDraft.rawMarkdown)
                .accessibilityLabel("Markdown source")
                .accessibilityHint("Edit this note’s Markdown source. Use Save to write your changes or Revert to discard them.")
                .accessibilityIdentifier("markdownSourceEditor")
                .font(NookType.code)
                .lineSpacing(3)
                .scrollContentBackground(.hidden)
                // The text view insets its first glyph by its line fragment
                // padding; pull it back onto the column edge.
                .padding(.horizontal, -5)
                .padding(.bottom, 12)
                .nookReadableColumn()
        }
    }

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
                withAnimation(NookMotion.quickAnimation(reduceMotion: reduceMotion)) {
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
    private func selectSummaryRecipe(_ recipe: SummaryRecipe) {
        guard !markdownDraft.hasChanges, !isRegenerating,
              recipe != note.summaryRecipe else { return }
        do {
            if personalNotes.noteID == note.id, personalNotes.hasExactChanges {
                _ = try personalNotes.save(note: note, store: store)
            }
            guard var current = store.uniqueNote(id: note.id),
                  current.libraryIdentity == note.libraryIdentity else {
                showCopyNotice("This note is no longer in the library.", severity: .failure)
                return
            }
            current.summaryRecipe = recipe
            let saved = try store.save(current)
            if markdownDraft.libraryIdentity == saved.libraryIdentity {
                markdownDraft.refresh(for: saved, store: store)
            }
            showCopyNotice("Recipe saved. Regenerate Summary to apply it.")
        } catch {
            showCopyNotice("The recipe could not be saved. Your summary was kept.", severity: .failure)
        }
    }

    private func regenerateSummary() {
        guard SummaryRegenerator.isAvailable(for: note),
              !markdownDraft.hasChanges,
              !regeneration.isRunning
        else { return }

        // The save below rewrites the whole file from the store's freshest
        // copy of the note. Words still sitting in the My notes draft would
        // be overwritten by that copy, so they get their save first, and a
        // refused save stops everything rather than losing words.
        if personalNotes.noteID == note.id, personalNotes.hasExactChanges {
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

        guard let current = store.uniqueNote(id: note.id),
              current.libraryIdentity == note.libraryIdentity else {
            showCopyNotice("This note is no longer in the library.", severity: .failure)
            return
        }

        // Capture the store itself, not this view and its StateObject, so a
        // noncooperative runner cannot keep a disappeared editor alive.
        let store = store
        regeneration.start(
            note: current,
            purpose: .forRetry(of: current),
            library: { [weak store] in
                guard let store else {
                    return .init(directoryURL: URL(fileURLWithPath: "/"), generation: -1, notes: [])
                }
                return .init(directoryURL: store.storageURL, generation: store.storageGeneration, notes: store.notes)
            },
            commit: { [weak store] updated in
                guard let store else { throw CancellationError() }
                return try store.save(updated)
            }
        )
    }

    private var isRegenerating: Bool { regeneration.isRunning }

    /// The status sits above every tab rather than replacing the saved words.
    /// Reading, exporting, and editing remain available during enrichment.
    @ViewBuilder
    private var savedSummaryStatus: some View {
        if note.kind == .meeting, let provenance = note.summaryProvenance {
            SummaryFallbackCard(
                provenance: provenance, isRunning: isRegenerating,
                canRetry: SummaryRegenerator.isAvailable(for: note) && !markdownDraft.hasChanges,
                retry: regenerateSummary
            )
            .nookReadableColumn()
            .padding(.vertical, 8)
        }
        if let stage = regeneration.stage {
            SummaryRegenerationProgressCard(stage: stage, onCancel: regeneration.cancel)
                .nookReadableColumn()
                .padding(.vertical, 8)
        } else if SummaryRegenerator.isAvailable(for: note),
                  let message = regeneration.statusMessage(
                    summaryPending: note.summaryPending != nil && note.summaryProvenance == nil
                  ) {
            HStack(alignment: .top, spacing: 12) {
                // The existing notice component bounds very long filesystem
                // errors and makes their complete wording scrollable. A failed
                // save must not push Retry or the document out of the window.
                CopyConfirmationBanner(message: message, severity: .info, emphasizesMessage: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if note.summaryProvenance == nil {
                    Button("Retry Summary", action: regenerateSummary)
                        .buttonStyle(.bordered)
                        .fixedSize()
                        .disabled(markdownDraft.hasChanges)
                        .help(markdownDraft.hasChanges
                            ? "Save or revert Markdown edits before retrying"
                            : "Summarize the saved transcript on this Mac")
                }
            }
            .nookReadableColumn()
            .padding(.vertical, 8)
            .accessibilityElement(children: .contain)
        }
    }

    private func finishSummaryRegeneration(_ outcome: SummaryRegenerationSession.Result) {
        switch outcome {
        case .saved(let saved):
            guard saved.libraryIdentity == note.libraryIdentity,
                  saved.fileURL?.deletingLastPathComponent().standardizedFileURL
                    == store.storageURL.standardizedFileURL else { return }
            if markdownDraft.libraryIdentity == saved.libraryIdentity {
                markdownDraft.refresh(for: saved, store: store)
            }
            reloadChecklist()
            showCopyNotice("Summary regenerated")
        case .failed, .retained(.some):
            // The summary status card under the title already says what
            // happened, persistently and beside Retry. A banner saying the
            // same words at the top of the window was the same failure twice.
            break
        case .retained(.none):
            showCopyNotice("There is no transcript here to summarize.", severity: .info)
        }
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

    /// Separated speakers, as buttons to name them. Shown only on notes whose
    /// meeting side was separated; naming one updates every line they said.
    @ViewBuilder
    private var speakersBar: some View {
        let speakers = SpeakerNames.speakers(in: note.transcript)
        if !speakers.isEmpty {
            HStack(spacing: 8) {
                Text("Speakers")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                ForEach(speakers, id: \.self) { speaker in
                    Button {
                        beginNamingSpeaker(speaker)
                    } label: {
                        Label(speaker, systemImage: "person.fill")
                    }
                    .controlSize(.small)
                    .help(SpeakerNames.isPlaceholder(speaker) ? "Name this speaker" : "Rename this speaker")
                }
                Spacer(minLength: 0)
            }
            .nookReadableColumn()
            .padding(.bottom, 8)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Speakers")
        }
    }

    private func beginNamingSpeaker(_ speaker: String) {
        speakerNameDraft = SpeakerNames.isPlaceholder(speaker) ? "" : speaker
        namingSpeaker = speaker
    }

    private func saveSpeakerName() {
        guard let speaker = namingSpeaker else { return }
        namingSpeaker = nil
        // Same rule as renaming the title: never rewrite the file under an
        // unsaved Markdown draft.
        guard canRenameTitle else {
            showCopyNotice(DetailRenamePolicy.markdownDraftBlockedMessage, severity: .info)
            return
        }
        switch SpeakerNames.rename(speaker, to: speakerNameDraft, in: note.transcript) {
        case .invalidName:
            showCopyNotice("Choose a name other than You or Meeting", severity: .failure)
        case .nameInUse:
            showCopyNotice("Another speaker already has that name", severity: .failure)
        case .renamed(let transcript):
            var updated = note
            updated.transcript = transcript
            do {
                let saved = try store.save(updated)
                markdownDraft.refresh(for: saved, store: store)
                showCopyNotice("Speaker named")
            } catch {
                showCopyNotice("The name couldn’t be saved", severity: .failure)
            }
        }
    }

    private func saveMarkdown() {
        do {
            try markdownDraft.save(note: note, store: store)
            Task {
                try? await Task.sleep(for: .seconds(2))
                guard markdownDraft.statusMessage == "Saved" else { return }
                withAnimation(NookMotion.quickAnimation(reduceMotion: reduceMotion)) {
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
        guard !store.duplicateNoteIDs.contains(note.id) else { return false }
        guard let fileURL = note.fileURL
            ?? store.uniqueNote(id: note.id)?.fileURL
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
            var current = store.notes.first(where: {
                $0.id == note.id && $0.fileURL?.standardizedFileURL == note.fileURL?.standardizedFileURL
            }) ?? note
            // Commit even whitespace-only edits before changing their owner
            // path. A refused save must leave both the draft and file in place.
            if personalNotes.noteID == current.id, personalNotes.hasExactChanges {
                current = try personalNotes.save(note: current, store: store)
            }
            let saved = try store.renameManagedFile(for: current)
            // Only this explicit, successful move may rebind clean editors.
            // An external rename still leaves an unfinished draft at its
            // captured original path for recovery instead of redirecting it.
            markdownDraft.prepare(for: saved, store: store)
            personalNotes.prepare(for: saved, store: store)
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
            "[\($0.timestamp)] \($0.speakerLabel): \($0.text)"
        }.joined(separator: "\n\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcript, forType: .string)
        showCopyNotice("Transcript copied")
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
            Label("Record into This Note", systemImage: "record.circle")
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

    /// The system segmented control, as Finder and Xcode use for switching
    /// views of one document. It brings native keyboard, VoiceOver and
    /// Increased Contrast behaviour that the hand-drawn underline tabs lacked.
    var body: some View {
        Picker("View", selection: animatedSelection) {
            ForEach(DetailTab.allCases.filter { tab in
                showsTranscript || tab != .transcript
            }) { tab in
                Text(tab.rawValue).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    private var animatedSelection: Binding<DetailTab> {
        Binding(
            get: { selection },
            set: { tab in
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                    selection = tab
                }
            }
        )
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
    /// Present when this line has a separated speaker the user can name.
    var nameSpeaker: ((String) -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .trailing, spacing: 7) {
                if showsSourceBadge {
                    if let speaker = segment.speaker, let nameSpeaker {
                        Button { nameSpeaker(speaker) } label: {
                            SourceBadge(source: segment.source, speaker: speaker)
                        }
                        .buttonStyle(.plain)
                        .help(SpeakerNames.isPlaceholder(speaker) ? "Name this speaker" : "Rename this speaker")
                        .accessibilityLabel("\(speaker). Name this speaker")
                    } else {
                        // The row's own label already says who spoke.
                        SourceBadge(source: segment.source, speaker: segment.speaker)
                            .accessibilityHidden(true)
                    }
                } else {
                    Color.clear
                        .frame(height: 16)
                        .accessibilityHidden(true)
                }
                Text(segment.timestamp)
                    // SF with fixed-width digits, as Voice Memos writes times;
                    // a monospaced face made each stamp read as code.
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .frame(width: 94, alignment: .trailing)

            Text(segment.text)
                .font(NookType.transcript)
                .lineSpacing(5)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("\(segment.speakerLabel), \(segment.timestamp): \(segment.text)")
                .accessibilityValue(segment.timestamp)

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
                .accessibilityValue(isPlaying ? "Currently playing" : "")
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
        // Keep the passage together without hiding its playback control or
        // flagged state from VoiceOver.
        .accessibilityElement(children: .contain)
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
            if segment.source != previous.source || segment.speaker != previous.speaker
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

/// The system search field, with its own clear button, focus ring and
/// Increased Contrast treatment. SwiftUI's `.searchable` is already taken by
/// the sidebar in this window, so the AppKit control is used directly.
struct NativeSearchField: NSViewRepresentable {
    let prompt: String
    @Binding var text: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = prompt
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        let text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}

extension EnvironmentValues {
    /// Whether the pointer is over the summary row that contains a view.
    @Entry var summaryRowIsHovered = false
}

/// Tracks the pointer over one summary row for the evidence button inside it.
private struct PublishesRowHover: ViewModifier {
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .environment(\.summaryRowIsHovered, isHovered)
    }
}

/// Per-row actions appear on hover, as Reminders' info button does. Opacity
/// alone hides them, so they stay in the accessibility tree and in the key
/// view loop, and they show whenever they hold keyboard focus.
private struct RevealedOnRowHover: ViewModifier {
    let isFocused: Bool
    @Environment(\.summaryRowIsHovered) private var isHovered
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(isHovered || isFocused ? 1 : 0)
            .animation(reduceMotion ? nil : NookMotion.quick, value: isHovered)
    }
}
