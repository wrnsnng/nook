import SwiftUI

/// The floating window a spoken note lands in.
struct QuickNoteView: View {
    @EnvironmentObject private var note: QuickNoteController
    @EnvironmentObject private var dictation: DictationCoordinator
    /// The paragraph the user declined; it stays declined until the words
    /// change.
    @State private var dismissedSuggestion: String?

    private var taskSuggestion: QuickCaptureTaskParser.Suggestion? {
        let candidate = QuickCaptureTaskParser.suggestion(in: note.text)
        guard let candidate, candidate.paragraph != dismissedSuggestion else {
            return nil
        }
        return candidate
    }

    var body: some View {
        VStack(spacing: 0) {
            editor
            actionBar
        }
        .background(NookPalette.paper)
    }

    private var editor: some View {
        NookNotesEditor(
            text: $note.text,
            placeholder: "Type, or hold your dictation shortcut and talk.",
            contentInsets: EdgeInsets(
                top: NookSpacing.medium,
                leading: NookSpacing.large,
                bottom: NookSpacing.medium,
                trailing: NookSpacing.large
            ),
            lineSpacing: 2,
            accessibilityLabel: "Spoken note",
            insertionPort: note.editorPort
        )
    }

    /// The recognizer's live guess while the pad is where words are going.
    /// Revision stays here, where it costs nothing; only settled text enters
    /// the buffer.
    @ViewBuilder
    private var partialLine: some View {
        if dictation.phase == .listening, note.isFrontmost,
           !dictation.volatileText.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle()
                    .fill(NookPalette.accent)
                    .frame(width: 5, height: 5)
                Text(dictation.volatileText)
                    .font(NookType.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, NookSpacing.large)
            .padding(.bottom, 6)
            .transition(.opacity)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Hearing: \(dictation.volatileText)")
        }
    }

    // MARK: - Action bar

    private var actionBar: some View {
        VStack(alignment: .leading, spacing: NookSpacing.small) {
            if let provider = note.engine.provider {
                outboundBanner(provider: provider)
            }

            if let message = note.message {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(NookType.caption)
                    .foregroundStyle(NookPalette.warning)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }

            if let suggestion = taskSuggestion {
                taskSuggestionChip(suggestion)
            }

            partialLine

            HStack(spacing: NookSpacing.xSmall) {
                Button {
                    note.insertChecklistLine()
                } label: {
                    Image(systemName: "checklist")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 26, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .help("Start a checklist line")
                .accessibilityLabel("Start a checklist line")

                ForEach(NoteAction.allCases) { action in
                    NoteActionButton(
                        action: action,
                        isRunning: note.runningAction == action,
                        isEnabled: canAct,
                        help: helpText(for: action)
                    ) {
                        note.run(action)
                    }
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: NookSpacing.small) {
                continuousToggle
                engineControl
                Spacer(minLength: NookSpacing.small)
                status
                filingMenu
                Button("Open in Library") {
                    note.saveAndOpenInLibrary()
                }
                .controlSize(.small)
                .disabled(note.text.isEmpty)
            }
        }
        .padding(.horizontal, NookSpacing.large)
        .padding(.vertical, NookSpacing.medium)
        .background {
            // A distinct surface rather than a hairline, so the bar reads as a
            // place for controls instead of a stray row under the text.
            Rectangle()
                .fill(.quaternary.opacity(0.4))
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(.separator)
                        .frame(height: NookSpacing.hairline)
                }
        }
        .animation(NookMotion.quick, value: note.message)
        .animation(NookMotion.quick, value: note.engine)
        .animation(NookMotion.quick, value: dictation.phase == .listening)
        .onChange(of: note.isContinuous) { _, continuous in
            guard note.isFrontmost else { return }
            if continuous {
                dictation.startContinuousSession()
            } else {
                dictation.stopContinuousSession()
            }
        }
    }

    /// Deterministic-first assist: the date is in the user's own words, so
    /// the chip only offers to write down what was already said.
    private func taskSuggestionChip(
        _ suggestion: QuickCaptureTaskParser.Suggestion
    ) -> some View {
        HStack(spacing: NookSpacing.small) {
            Image(systemName: "calendar.badge.checkmark")
                .foregroundStyle(NookPalette.accent)
            Text("Make this a task due \(suggestion.cueLabel)?")
                .font(NookType.caption)
            Spacer(minLength: 0)
            Button("Make Task") {
                note.text = QuickCaptureTaskParser.applying(
                    suggestion,
                    to: note.text
                )
                dismissedSuggestion = suggestion.paragraph
            }
            .controlSize(.small)
            .keyboardShortcut(.defaultAction)
            Button("Not Now") {
                dismissedSuggestion = suggestion.paragraph
            }
            .controlSize(.small)
        }
        .padding(.horizontal, NookSpacing.small + 2)
        .padding(.vertical, NookSpacing.xSmall + 1)
        .background(
            RoundedRectangle(
                cornerRadius: NookRadius.control,
                style: .continuous
            )
            .fill(NookPalette.accent.opacity(0.10))
        )
        .accessibilityElement(children: .combine)
    }

    private var continuousToggle: some View {
        Toggle(isOn: $note.isContinuous) {
            Label("Hands-free", systemImage: "waveform.badge.mic")
                .font(NookType.micro.weight(.medium))
        }
        .toggleStyle(.checkbox)
        .help(
            "Keep listening after each thought until you turn this off"
        )
    }

    /// Files the buffer somewhere deliberate instead of promotion being a
    /// discovery exercise later.
    private var filingMenu: some View {
        Menu {
            Button("Append to a meeting's notes") {
                showsFilingPicker = true
            }
        } label: {
            Label("File into", systemImage: "text.badge.plus")
                .font(NookType.micro.weight(.medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(note.text.isEmpty || note.recentMeetingTargets.isEmpty)
        .help("Add these words to a meeting's personal notes")
        .popover(isPresented: $showsFilingPicker, arrowEdge: .bottom) {
            filingPicker
        }
    }

    @State private var showsFilingPicker = false

    private var filingPicker: some View {
        VStack(alignment: .leading, spacing: NookSpacing.xSmall) {
            Text("Append to which meeting?")
                .font(NookType.control)
            ForEach(note.recentMeetingTargets) { meeting in
                Button {
                    showsFilingPicker = false
                    note.fileIntoMeeting(meeting)
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(meeting.title)
                            .lineLimit(1)
                        Text(
                            meeting.startedAt.formatted(
                                date: .abbreviated,
                                time: .shortened
                            )
                        )
                        .font(NookType.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .padding(.vertical, 2)
            }
        }
        .padding(NookSpacing.medium + 2)
        .frame(width: 280)
    }

    /// States plainly, and permanently, that actions will send this note away.
    ///
    /// The engine is remembered between notes, so the choice can easily have
    /// been made days ago. A marker that only appears on hover would leave a
    /// user believing Nook's usual promise still holds while it no longer does.
    private func outboundBanner(provider: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: NookSpacing.small) {
            Image(systemName: "arrow.up.forward.app.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(NookPalette.warning)
                .accessibilityHidden(true)

            Text("Running an action sends this note to \(provider).")
                .font(NookType.micro)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            Button("Keep on this Mac") {
                note.selectEngine(.onDevice)
            }
            .buttonStyle(.link)
            .font(NookType.micro.weight(.medium))
        }
        .padding(.horizontal, NookSpacing.small + 2)
        .padding(.vertical, NookSpacing.xSmall + 2)
        .background {
            RoundedRectangle(cornerRadius: NookRadius.control, style: .continuous)
                .fill(NookPalette.warning.opacity(0.12))
                .overlay {
                    RoundedRectangle(
                        cornerRadius: NookRadius.control,
                        style: .continuous
                    )
                    .strokeBorder(
                        NookPalette.warning.opacity(0.3),
                        lineWidth: NookSpacing.hairline
                    )
                }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Warning. Running an action sends this note to \(provider)."
        )
    }

    /// One control for the engine, carrying its own privacy marker.
    ///
    /// The picker and a separate "On this Mac" label previously said the same
    /// thing twice, side by side. Where the work happens and whether it leaves
    /// the Mac are the same fact, so they belong to one control.
    @ViewBuilder
    private var engineControl: some View {
        if note.availableEngines.isEmpty {
            Label("No assistant available", systemImage: "sparkles.slash")
                .font(NookType.micro)
                .foregroundStyle(.secondary)
        } else {
            Menu {
                ForEach(note.availableEngines) { engine in
                    Button {
                        note.selectEngine(engine)
                    } label: {
                        // The provider is named in the menu itself, so the
                        // consequence is legible before the choice is made
                        // rather than only after it.
                        if let provider = engine.provider {
                            Label(
                                "\(engine.title), sends to \(provider)",
                                systemImage: symbol(for: engine)
                            )
                        } else {
                            Label(engine.title, systemImage: symbol(for: engine))
                        }
                    }
                }
            } label: {
                Label {
                    Text(note.engine.title)
                        .font(NookType.micro.weight(.medium))
                } icon: {
                    Image(systemName: symbol(for: note.engine))
                        .foregroundStyle(
                            note.engine.leavesTheMac
                                ? NookPalette.warning
                                : NookPalette.success
                        )
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(note.engine.detail)
            .disabled(note.availableEngines.count < 2)
        }
    }

    private var status: some View {
        Text(statusText)
            .font(NookType.micro)
            .foregroundStyle(.tertiary)
            .monospacedDigit()
            .animation(NookMotion.quick, value: statusText)
    }

    private var statusText: String {
        guard note.wordCount > 0 else { return "" }
        let words = "\(note.wordCount) word\(note.wordCount == 1 ? "" : "s")"
        return note.lastSavedAt == nil ? words : "\(words) · Saved"
    }

    private var canAct: Bool {
        !note.text.isEmpty && !note.isWorking && !note.availableEngines.isEmpty
    }

    private func symbol(for engine: NoteAssistantEngine) -> String {
        engine.leavesTheMac ? "arrow.up.forward.app.fill" : "lock.fill"
    }

    private func helpText(for action: NoteAction) -> String {
        guard !note.availableEngines.isEmpty else {
            return "No assistant is available on this Mac."
        }
        return action.replacesNote
            ? "\(action.title). Rewrites the note using \(note.engine.title)."
            : "\(action.title). Adds a section using \(note.engine.title)."
    }
}

/// One note action, styled as a quiet chip that lights up under the pointer.
private struct NoteActionButton: View {
    let action: NoteAction
    let isRunning: Bool
    let isEnabled: Bool
    let help: String
    let perform: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: perform) {
            HStack(spacing: NookSpacing.xSmall + 1) {
                Group {
                    if isRunning {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.55)
                    } else {
                        Image(systemName: action.symbol)
                            .font(.system(size: 11, weight: .semibold))
                    }
                }
                .frame(width: 13, height: 13)

                Text(action.title)
                    .font(NookType.micro.weight(.medium))
            }
            .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
            .padding(.horizontal, NookSpacing.small + 2)
            .padding(.vertical, NookSpacing.xSmall + 2)
            .background {
                RoundedRectangle(cornerRadius: NookRadius.control, style: .continuous)
                    .fill(fill)
                    .overlay {
                        RoundedRectangle(
                            cornerRadius: NookRadius.control,
                            style: .continuous
                        )
                        .strokeBorder(
                            NookPalette.accent.opacity(isHovering && isEnabled ? 0.35 : 0),
                            lineWidth: NookSpacing.hairline
                        )
                    }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || isRunning)
        .onHover { isHovering = $0 }
        .animation(NookMotion.quick, value: isHovering)
        .animation(NookMotion.quick, value: isRunning)
        .help(help)
        .accessibilityLabel(action.title)
        .accessibilityHint(help)
    }

    private var fill: Color {
        guard isEnabled else { return .clear }
        if isRunning { return NookPalette.accent.opacity(0.16) }
        return isHovering
            ? NookPalette.accent.opacity(0.12)
            : Color.primary.opacity(0.05)
    }
}
