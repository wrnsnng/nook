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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let note: MeetingNote

    @State private var tab: DetailTab = .notes
    @State private var transcriptSearch = ""
    @State private var copyNotice: String?
    @State private var titleDraft: String
    @State private var personalNotesDraft: String
    @State private var personalNotesStatus: String?
    @FocusState private var personalNotesFocused: Bool

    init(note: MeetingNote, initialTab: DetailTab = .notes) {
        self.note = note
        _tab = State(initialValue: initialTab)
        _titleDraft = State(initialValue: note.title)
        _personalNotesDraft = State(initialValue: note.personalNotes)
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
                CopyConfirmationBanner(message: copyNotice)
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .onAppear {
            markdownDraft.prepare(for: note, store: store)
        }
        .onChange(of: note.personalNotes) { oldValue, newValue in
            if personalNotesDraft == oldValue {
                personalNotesDraft = newValue
            }
        }
        .onChange(of: note.title) { oldValue, newValue in
            if titleDraft == oldValue {
                titleDraft = newValue
            }
        }
        .onChange(of: personalNotesDraft) { _, _ in
            if personalNotesStatus == "Saved" {
                personalNotesStatus = nil
            }
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
                .onSubmit(saveTitle)
                .help("Edit the title and press Return to save")
                .accessibilityLabel("Meeting title")
                .accessibilityHint("Edit the title and press Return to save")
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
                    title: "\(note.transcriptWordCount) words",
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
                                    Text(String(format: "%02d", index + 1))
                                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(NookPalette.accent)
                                        .frame(width: 24, alignment: .leading)
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
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(NookPalette.accent)
                                        .frame(width: 20, height: 20)
                                        .background(
                                            NookPalette.accent.opacity(0.10),
                                            in: Circle()
                                        )
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

                if !note.actionItems.isEmpty {
                    EditorialSection(
                        title: "Action items",
                        symbol: "checklist",
                        tint: NookPalette.accent
                    ) {
                        VStack(spacing: 0) {
                            ForEach(Array(note.actionItems.enumerated()), id: \.offset) { index, action in
                                HStack(alignment: .top, spacing: 13) {
                                    Image(systemName: "circle")
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(NookPalette.accent)
                                        .frame(width: 22, height: 22)
                                        .accessibilityHidden(true)
                                    Text(action)
                                        .font(NookType.transcript)
                                        .lineSpacing(4)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .padding(.vertical, 14)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel("Action item: \(action)")

                                if index < note.actionItems.count - 1 {
                                    Divider()
                                        .padding(.leading, 35)
                                }
                            }
                        }
                    }
                }

                if note.keyPoints.isEmpty,
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

    private var personalNotesSection: some View {
        EditorialSection(
            title: "My notes",
            symbol: "square.and.pencil",
            tint: NookPalette.accent
        ) {
            VStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    if personalNotesDraft.isEmpty {
                        Text("Add context, a follow-up, or something you want to remember…")
                            .font(NookType.body)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 9)
                            .allowsHitTesting(false)
                    }

                    TextEditor(text: $personalNotesDraft)
                        .font(NookType.body)
                        .lineSpacing(5)
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 2)
                        .padding(.vertical, 1)
                        .focused($personalNotesFocused)
                        .disabled(markdownDraft.hasChanges)
                        .accessibilityLabel("Personal meeting notes")
                        .accessibilityHint(
                            "Saved into the My notes section of this meeting’s Markdown file"
                        )
                }
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
                    } else if let personalNotesStatus {
                        Label(
                            personalNotesStatus,
                            systemImage: personalNotesStatus == "Saved"
                                ? "checkmark.circle.fill"
                                : "exclamationmark.circle"
                        )
                        .font(NookType.caption)
                        .foregroundStyle(
                            personalNotesStatus == "Saved"
                                ? NookPalette.success
                                : NookPalette.danger
                        )
                    } else {
                        Text("Stored locally in this Markdown file")
                            .font(NookType.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("Save notes") {
                        savePersonalNotes()
                    }
                    .disabled(
                        !hasPersonalNotesChanges
                            || markdownDraft.hasChanges
                    )
                    .keyboardShortcut("s", modifiers: .command)
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

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            NookSectionLabel(
                title: "The gist",
                symbol: "text.alignleft",
                tint: NookPalette.accent
            )

            Text(note.summary)
                .font(NookType.editorialSummary)
                .lineSpacing(7)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var filteredTranscript: [TranscriptSegment] {
        guard !transcriptSearch.isEmpty else { return note.transcript }
        return note.transcript.filter {
            $0.text.localizedCaseInsensitiveContains(transcriptSearch)
                || $0.source.label.localizedCaseInsensitiveContains(transcriptSearch)
        }
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
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filteredTranscript) { segment in
                            TranscriptRow(segment: segment)
                        }
                    }
                    .padding(.horizontal, 44)
                    .padding(.vertical, 16)
                    .frame(maxWidth: 880)
                    .frame(maxWidth: .infinity)
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

            Text("\(filteredTranscript.count) of \(note.transcript.count) passages")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())

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
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Text("\(markdownDraft.rawMarkdown.count) characters")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())

                if let statusMessage = markdownDraft.statusMessage {
                    Label(
                        statusMessage,
                        systemImage: statusMessage == "Saved" ? "checkmark.circle.fill" : "exclamationmark.circle"
                    )
                    .font(.system(size: 10, weight: .semibold))
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
                .keyboardShortcut("s", modifiers: .command)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 13)

            SoftDivider()

            TextEditor(text: $markdownDraft.rawMarkdown)
                .font(NookType.code)
                .lineSpacing(3)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 28)
                .padding(.vertical, 20)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.66))
        }
    }

    private var hasMarkdownChanges: Bool {
        markdownDraft.noteID == note.id && markdownDraft.hasChanges
    }

    private var hasPersonalNotesChanges: Bool {
        personalNotesDraft != note.personalNotes
    }

    private func savePersonalNotes() {
        personalNotesFocused = false
        let normalized = personalNotesDraft.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        personalNotesDraft = normalized
        do {
            let saved = try store.updatePersonalNotes(
                normalized,
                for: note
            )
            markdownDraft.refresh(for: saved, store: store)
            personalNotesStatus = "Saved"
            Task {
                try? await Task.sleep(for: .seconds(2))
                guard personalNotesStatus == "Saved" else { return }
                withAnimation(.easeOut(duration: 0.18)) {
                    personalNotesStatus = nil
                }
            }
        } catch {
            personalNotesStatus = error.localizedDescription
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
            showCopyNotice("Title couldn’t be saved")
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
        let markdown = markdownDraft.noteID == note.id
            ? markdownDraft.rawMarkdown
            : store.rawMarkdown(for: note)
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
        }
        .padding(.vertical, 16)
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
