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
    /// Whether the My notes field has the keyboard. Leaving it writes what is
    /// there, for the same reason the title field does: waiting for a button
    /// meant every other way out of the field threw the words away.
    @FocusState private var personalNotesFocused: Bool
    /// Tracks the title field so leaving it commits the edit. Return-only
    /// saving silently discarded titles whenever the user clicked another
    /// note instead of pressing Return first.
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
    /// The note's checkbox lines as they exist on disk right now. Checkbox
    /// state is deliberately absent from the decoded model, so ticking from
    /// here needs the file's own truth to stay aligned with the sidebar.
    @State private var checklistLines: [ActionItemLine] = []
    /// Words across the whole transcript, computed once when the note
    /// changes rather than inside the header. `ViewThatFits` measures both of
    /// its candidate layouts, which ran this reduce over every transcript
    /// segment twice per body pass; a long meeting paid that cost at
    /// whatever rate anything else in the window invalidated this view.
    @State private var transcriptWordCount = 0

    init(note: MeetingNote, initialTab: DetailTab = .notes) {
        self.note = note
        _tab = State(initialValue: initialTab)
        _titleDraft = State(initialValue: note.title)
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
            transcriptWordCount = note.transcriptWordCount
            reloadChecklist()
        }
        .onChange(of: markdownDraft.rawMarkdown) { _, markdown in
            markdownCharacterCount = markdown.count
        }
        .onChange(of: note) { _, newValue in
            transcriptWordCount = newValue.transcriptWordCount
            reloadChecklist()
        }
        .onChange(of: note.personalNotes) { _, _ in
            personalNotes.refresh(for: note)
        }
        .onChange(of: note.title) { oldValue, newValue in
            if titleDraft == oldValue {
                titleDraft = newValue
            }
        }
        .onChange(of: titleFieldFocused) { _, focused in
            guard !focused else { return }
            saveTitle()
        }
        .onChange(of: personalNotesFocused) { _, focused in
            guard !focused else { return }
            savePersonalNotes()
        }
        // Backstop for navigation that races focus loss: the view keeps its
        // own note, so committing here always writes the right file.
        .onDisappear {
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

    private var documentHeader: some View {
        VStack(alignment: .leading, spacing: 22) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .bottom, spacing: 28) {
                    titleBlock
                    Spacer(minLength: 24)
                    DetailTabBar(selection: $tab)
                    detailActions
                }

                VStack(alignment: .leading, spacing: 18) {
                    titleBlock
                    HStack {
                        DetailTabBar(selection: $tab)
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
        .help("Meeting actions")
        .accessibilityLabel("Meeting actions")
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Meeting title", text: $titleDraft)
                .textFieldStyle(.plain)
                .font(NookType.title)
                .tracking(-0.45)
                .lineLimit(2)
                .focused($titleFieldFocused)
                .onSubmit(saveTitle)
                .help("Edits save when you press Return or click away")
                .accessibilityLabel("Meeting title")
                .accessibilityHint(
                    "Edits save when you press Return or leave the field"
                )
                .accessibilityAddTraits(.isHeader)

            HStack(spacing: 15) {
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
                NookMetadataLabel(
                    title: "\(transcriptWordCount) words",
                    symbol: "text.word.spacing"
                )
            }
        }
    }

    private var notesView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 38) {
                if !note.summary.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty {
                    summarySection
                }

                if !note.moments.isEmpty {
                    momentsSection
                }

                personalNotesSection

                if !note.keyPoints.isEmpty {
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

                if !note.decisions.isEmpty {
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

                if checklistLines.isEmpty,
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
        guard note.kind == .spoken else { return note.summary }
        return note.summary
            .split(separator: "\n", omittingEmptySubsequences: true)
            .filter { line in
                !line.trimmingCharacters(in: .whitespaces).hasPrefix("- [")
            }
            .joined(separator: "\n")
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            NookSectionLabel(
                title: "The gist",
                symbol: "text.alignleft",
                tint: NookPalette.accent
            )

            if isRegenerating {
                regenerationStatusCard
            } else {
                Text(displaySummary)
                    .font(NookType.editorialSummary)
                    .lineSpacing(7)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var filteredTranscript: [TranscriptSegment] {
        guard !transcriptSearch.isEmpty else { return note.transcript }
        return note.transcript.filter {
            $0.text.localizedCaseInsensitiveContains(transcriptSearch)
                || $0.source.label.localizedCaseInsensitiveContains(transcriptSearch)
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
              regenerationStage == nil
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
        Task {
            // A struct view outlives its own body captures badly under
            // weak; MainActor.run keeps ordering, and a stage landing after
            // navigation simply writes an unused field.
            let stageHandler: SummaryStageHandler = { stage in
                await MainActor.run { regenerationStage = stage }
            }
            let outcome = await SummaryRegenerator.regenerate(
                current,
                using: SummaryService(),
                onStage: stageHandler
            )
            finishSummaryRegeneration(outcome)
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
        _ outcome: SummaryRegenerator.Outcome
    ) {
        regenerationStage = nil
        switch outcome {
        case .regenerated(let updated):
            do {
                let saved = try store.save(updated)
                markdownDraft.refresh(for: saved, store: store)
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

    private func saveTitle() {
        let title = titleDraft.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !title.isEmpty else {
            titleDraft = note.title
            return
        }
        guard title != note.title else { return }

        var updatedNote = note
        updatedNote.title = title
        do {
            let saved = try store.save(updatedNote)
            markdownDraft.refresh(for: saved, store: store)
            showCopyNotice("Title saved")
        } catch {
            titleDraft = note.title
            // A failure in a success banner reads as a confirmation, and the
            // typed title has just been reverted under the user.
            showCopyNotice("Title couldn’t be saved", severity: .failure)
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
            "Appends the next recording to this note instead of creating a new one"
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            ForEach(DetailTab.allCases) { tab in
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
    var isFlagged = false
    var isPlaying = false
    /// Present only when kept audio exists; tapping plays this line.
    var playAction: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .trailing, spacing: 7) {
                SourceBadge(source: segment.source)
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

private extension MeetingNote {
    var transcriptWordCount: Int {
        transcript.reduce(0) { count, segment in
            count + segment.text.split(whereSeparator: \.isWhitespace).count
        }
    }
}
