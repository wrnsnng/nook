import SwiftUI

/// The floating window a spoken note lands in.
struct QuickNoteView: View {
    @EnvironmentObject private var note: QuickNoteController
    @EnvironmentObject private var dictation: DictationCoordinator
    @EnvironmentObject private var shortcuts: ShortcutStore
    /// The paragraph the user declined; it stays declined until the words
    /// change.
    @State private var dismissedSuggestion: String?
    @State private var showsFilingPicker = false
    /// The parsed task suggestion for the note's current words, recomputed
    /// only when `note.text` actually changes. The pad's body also
    /// re-evaluates on every dictation audio-level tick while listening
    /// (`isHearing`/`dictation.volatileText`); parsing the whole buffer for a
    /// due-date cue on each of those, when typing had not happened, was pure
    /// waste.
    @State private var cachedSuggestion: QuickCaptureTaskParser.Suggestion?

    private var taskSuggestion: QuickCaptureTaskParser.Suggestion? {
        guard let cachedSuggestion,
              cachedSuggestion.paragraph != dismissedSuggestion
        else {
            return nil
        }
        return cachedSuggestion
    }

    private func refreshTaskSuggestion() {
        cachedSuggestion = QuickCaptureTaskParser.suggestion(in: note.text)
    }

    /// What is worth saying above the bar right now, at most two things.
    private var rows: [QuickNotePadRow] {
        QuickNotePadLayout.rows(
            outboundProvider: note.engine.provider,
            notice: note.message,
            noticeIsFailure: !note.messageIsAdvisory,
            hearing: isHearing ? dictation.volatileText : nil,
            hasSuggestion: taskSuggestion != nil,
            hasAssistant: !note.availableEngines.isEmpty
        )
    }

    private var isHearing: Bool {
        dictation.phase == .listening && note.isFrontmost
            && !dictation.volatileText.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            editor
            bar
        }
        .background(NookPalette.paper)
        // One accent for the whole pad. Without this the system controls here
        // carry the user's system accent while Nook's own chrome carries the
        // brand colour, and the pad shows two different blues at once.
        .tint(NookPalette.accent)
        .background { closeShortcut }
        // Escape leaves the pad the way every other exit does, by saving.
        .onExitCommand { note.done() }
        .onAppear { refreshTaskSuggestion() }
        .onChange(of: note.text) { _, _ in
            note.scheduleSave()
            refreshTaskSuggestion()
        }
        .onChange(of: note.isContinuous) { _, continuous in
            guard note.isFrontmost else { return }
            if continuous {
                dictation.startContinuousSession()
            } else {
                dictation.stopContinuousSession()
            }
        }
        .onChange(of: dictation.phase) { _, phase in
            // A failed session leaves nothing listening, so a still-ticked box
            // would be claiming a session that is not running.
            if case .failed = phase { note.isContinuous = false }
        }
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

    // MARK: - Bar

    /// Everything below the editor: at most two rows saying what is going on,
    /// then one row of controls.
    private var bar: some View {
        VStack(alignment: .leading, spacing: NookSpacing.xSmall) {
            ForEach(rows, id: \.self) { row in
                rowView(row)
            }
            controlRow
        }
        .padding(.horizontal, NookSpacing.large)
        .padding(.vertical, NookSpacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
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
        .animation(NookMotion.quick, value: rows)
    }

    @ViewBuilder
    private func rowView(_ row: QuickNotePadRow) -> some View {
        switch row {
        case .outbound(let provider):
            outboundRow(provider: provider)
        case .notice(let text, let isFailure):
            noticeRow(text, isFailure: isFailure)
        case .hearing(let text):
            hearingRow(text)
        case .suggestion:
            if let suggestion = taskSuggestion {
                suggestionRow(suggestion)
            }
        case .noAssistant:
            noAssistantRow
        }
    }

    // MARK: - Rows

    /// States plainly, and permanently, that actions will send this note away.
    ///
    /// The engine is remembered between notes, so the choice can easily have
    /// been made days ago. A marker that only appears on hover would leave a
    /// user believing Nook's usual promise still holds while it no longer does.
    /// One line rather than a bordered box: a standing fact drawn as an alert
    /// is an alarm that never stops, and those stop being read.
    private func outboundRow(provider: String) -> some View {
        HStack(spacing: NookSpacing.xSmall) {
            Image(systemName: "arrow.up.forward.app.fill")
                .foregroundStyle(NookPalette.warning)
                .accessibilityHidden(true)

            Text("Actions send this note to \(provider).")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityLabel(
                    "Warning. Actions send this note to \(provider)."
                )

            Button("Keep on this Mac") {
                note.selectEngine(.onDevice)
            }
            .buttonStyle(.borderless)
            .help("Switch back to the on-device model, which sends nothing.")

            Spacer(minLength: 0)
        }
        .font(NookType.caption)
    }

    /// A failure and a decision Nook made on the user's behalf are different
    /// things. Drawing the second one in warning colours told people something
    /// had gone wrong when nothing had.
    private func noticeRow(_ text: String, isFailure: Bool) -> some View {
        Label {
            Text(text)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(
                systemName: isFailure
                    ? "exclamationmark.triangle.fill"
                    : "info.circle"
            )
        }
        .font(NookType.caption)
        .foregroundStyle(
            isFailure
                ? AnyShapeStyle(NookPalette.warning)
                : AnyShapeStyle(.secondary)
        )
        .transition(.opacity)
    }

    /// The recognizer's live guess while the pad is where words are going.
    /// Revision stays here, where it costs nothing; only settled text enters
    /// the buffer.
    private func hearingRow(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: NookSpacing.xSmall + 2) {
            Circle()
                .fill(NookPalette.accent)
                .frame(width: 5, height: 5)
            Text(text)
                .font(NookType.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .transition(.opacity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Hearing: \(text)")
    }

    /// Deterministic-first assist: the date is in the user's own words, so the
    /// row only offers to write down what was already said.
    ///
    /// Inline and quiet, and Return is left to the editor. A suggestion that
    /// owns the default action gets accepted by people who were only trying to
    /// start a new line.
    private func suggestionRow(
        _ suggestion: QuickCaptureTaskParser.Suggestion
    ) -> some View {
        HStack(spacing: NookSpacing.xSmall) {
            Image(systemName: "calendar.badge.clock")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Text(suggestion.cueLabel)
            Text("Make this a task?")
                .foregroundStyle(.secondary)

            Button("Make task") {
                note.text = QuickCaptureTaskParser.applying(
                    suggestion,
                    to: note.text
                )
                dismissedSuggestion = suggestion.paragraph
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.return, modifiers: .command)
            .help(
                "Make this a task due \(suggestion.cueLabel). Command-Return."
            )

            Button("Not now") {
                dismissedSuggestion = suggestion.paragraph
            }
            .buttonStyle(.borderless)
            .help("Leave these words as they are.")

            Spacer(minLength: 0)
        }
        .font(NookType.caption)
        .accessibilityLabel("Make this a task due \(suggestion.cueLabel)?")
    }

    /// The empty state for note actions. Four dead chips said the same thing
    /// four times over and told nobody what to do about it.
    private var noAssistantRow: some View {
        Label(
            "No assistant on this Mac. Turn on Apple Intelligence in System Settings, or install Claude Code or Codex.",
            systemImage: "info.circle"
        )
        .font(NookType.caption)
        .foregroundStyle(.secondary)
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Controls

    /// One row, one vocabulary: bordered controls for everything the pad does,
    /// one prominent Done at the end, and the same target size for each.
    ///
    /// The ladder exists because the pad resizes down to 380pt and there is no
    /// honest way to fit every label there. Labels are given up in order of
    /// what they carry: the running total first, then the actions menu's
    /// title, then the engine's, which is a privacy statement and so goes last.
    private var controlRow: some View {
        ViewThatFits(in: .horizontal) {
            controls(
                BarDetail(
                    showsUtilityTitles: true,
                    status: .full
                )
            )
            // Keep the compact composer focused. Labels are offered only when
            // the whole bar can carry them without forcing the editor shorter.
            controls(BarDetail(status: .full))
            controls(BarDetail(status: .short))
            controls(BarDetail(showsActionsTitle: false, status: .short))
            controls(BarDetail(showsActionsTitle: false, status: .hidden))
            controls(
                BarDetail(
                    showsEngineTitle: false,
                    showsActionsTitle: false,
                    status: .hidden
                )
            )
        }
        .controlSize(.small)
        .frame(height: 32)
    }

    private struct BarDetail {
        var showsEngineTitle = true
        var showsActionsTitle = true
        var showsUtilityTitles = false
        var status: StatusDetail = .full
    }

    private enum StatusDetail {
        case full
        case short
        case hidden
    }

    private func controls(_ detail: BarDetail) -> some View {
        HStack(spacing: NookSpacing.xSmall) {
            engineControl(showsTitle: detail.showsEngineTitle)
            actionsMenu(showsTitle: detail.showsActionsTitle)
            checklistButton(showsTitle: detail.showsUtilityTitles)
            filingButton(showsTitle: detail.showsUtilityTitles)
            handsFreeToggle(showsTitle: detail.showsUtilityTitles)
            Spacer(minLength: NookSpacing.small)
            status(detail.status)
            Spacer(minLength: NookSpacing.small)
            discardButton(showsTitle: detail.showsUtilityTitles)
            doneButton
        }
    }

    /// One control for the engine, carrying its own privacy marker.
    ///
    /// The picker and a separate "On this Mac" label previously said the same
    /// thing twice, side by side. Where the work happens and whether it leaves
    /// the Mac are the same fact, so they belong to one control.
    @ViewBuilder
    private func engineControl(showsTitle: Bool) -> some View {
        if note.availableEngines.count > 1 {
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
                    .help(engine.detail)
                    .accessibilityValue(engine.detail)
                }
            } label: {
                engineLabel(showsTitle: showsTitle)
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .fixedSize()
            .help(note.engine.detail)
            .accessibilityLabel("Assistant: \(note.engine.title)")
            .accessibilityValue(note.engine.detail)
            .accessibilityHint("Choose which assistant runs note actions.")
        } else if !note.availableEngines.isEmpty {
            // With one engine there is no choice to offer. A disabled menu
            // would present a decision that does not exist, which reads as
            // something being broken rather than settled.
            engineLabel(showsTitle: showsTitle)
                .foregroundStyle(.secondary)
                .padding(.horizontal, NookSpacing.xSmall)
                .fixedSize()
                .help(note.engine.detail)
                .accessibilityLabel("Assistant: \(note.engine.title)")
                .accessibilityValue(note.engine.detail)
                .accessibilityHint("Only one assistant is available.")
        }
    }

    @ViewBuilder
    private func engineLabel(showsTitle: Bool) -> some View {
        let label = Label {
            Text(note.engine.title)
        } icon: {
            Image(systemName: symbol(for: note.engine))
                .foregroundStyle(
                    note.engine.leavesTheMac
                        ? AnyShapeStyle(NookPalette.warning)
                        : AnyShapeStyle(.secondary)
                )
        }
        .frame(height: Self.controlLabelHeight)

        if showsTitle {
            label.labelStyle(.titleAndIcon)
        } else {
            label.labelStyle(.iconOnly)
        }
    }

    /// Every note action in one place. They share an engine, a failure mode
    /// and a privacy consequence, so four separate chips only made the bar
    /// look like a toolbar for four unrelated things.
    @ViewBuilder
    private func actionsMenu(showsTitle: Bool) -> some View {
        if !note.availableEngines.isEmpty {
            Menu {
                Section("Using \(note.engine.title)") {
                    ForEach(NoteAction.allCases) { action in
                        Button {
                            note.run(action)
                        } label: {
                            Label(action.title, systemImage: action.symbol)
                        }
                        .help(helpText(for: action))
                    }
                }
            } label: {
                actionsLabel(showsTitle: showsTitle)
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .fixedSize()
            .disabled(!canAct)
            .help(actionsHelp)
            .accessibilityLabel("Note actions")
            .accessibilityValue("Using \(note.engine.title)")
            .accessibilityHint("Choose an action to change or add to this note.")
        }
    }

    @ViewBuilder
    private func actionsLabel(showsTitle: Bool) -> some View {
        let label = Label {
            Text("Actions")
        } icon: {
            // The running indicator lives on the menu button, because the
            // button is what stays on screen once the menu has closed.
            if note.isWorking {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "wand.and.sparkles")
            }
        }
        .frame(height: Self.controlLabelHeight)

        if showsTitle {
            label.labelStyle(.titleAndIcon)
        } else {
            label.labelStyle(.iconOnly)
        }
    }

    private var actionsHelp: String {
        if let running = note.runningAction {
            return "\(running.title) is running."
        }
        return "Tidy up, summarise, find actions, or expand, using "
            + "\(note.engine.title)."
    }

    @ViewBuilder
    private func utilityLabel(
        _ title: String,
        systemImage: String,
        showsTitle: Bool
    ) -> some View {
        if showsTitle {
            Label(title, systemImage: systemImage)
        } else {
            Image(systemName: systemImage)
        }
    }

    private func checklistButton(showsTitle: Bool) -> some View {
        Button {
            note.insertChecklistLine()
        } label: {
            utilityLabel(
                "Checklist",
                systemImage: "checklist",
                showsTitle: showsTitle
            )
                .frame(height: Self.controlLabelHeight)
        }
        .buttonStyle(.bordered)
        .keyboardShortcut(
            shortcuts.binding(for: .quickNoteChecklist).keyEquivalent,
            modifiers: shortcuts.binding(for: .quickNoteChecklist)
                .eventModifiers
        )
        .help(
            "Start a checklist line. "
                + shortcuts.binding(for: .quickNoteChecklist).spokenDescription
                + "."
        )
        .accessibilityLabel("Start a checklist line")
        .accessibilityHint("Inserts a checklist line at the cursor.")
    }

    /// Files the buffer somewhere deliberate instead of promotion being a
    /// discovery exercise later. A button rather than a menu holding one item,
    /// which only added a click in front of the choice that mattered.
    private func filingButton(showsTitle: Bool) -> some View {
        Button {
            showsFilingPicker = true
        } label: {
            utilityLabel(
                "File",
                systemImage: "text.badge.plus",
                showsTitle: showsTitle
            )
                .frame(height: Self.controlLabelHeight)
        }
        .buttonStyle(.bordered)
        .disabled(note.text.isEmpty)
        .help("Add to meeting, or open in Library.")
        .accessibilityLabel("Add to meeting, or open in Library")
        .accessibilityHint("Save this quick note to a recent meeting or open it in Library.")
        .popover(isPresented: $showsFilingPicker, arrowEdge: .bottom) {
            filingPicker
        }
    }

    /// Only offered when dictation is on. A toggle for something that cannot
    /// run is a promise the pad has no way to keep.
    @ViewBuilder
    private func handsFreeToggle(showsTitle: Bool) -> some View {
        if dictation.isEnabled {
            Toggle(isOn: $note.isContinuous) {
                utilityLabel(
                    "Hands-free",
                    systemImage: "waveform.badge.mic",
                    showsTitle: showsTitle
                )
                    .frame(height: Self.controlLabelHeight)
            }
            .toggleStyle(.button)
            .buttonStyle(.bordered)
            .help(
                "Hands-free. Keep listening after each thought until you turn this off."
            )
            .accessibilityLabel("Hands-free")
            .accessibilityValue(note.isContinuous ? "On" : "Off")
            .accessibilityHint("Keeps listening after each thought until turned off.")
        }
    }

    private func discardButton(showsTitle: Bool) -> some View {
        Button {
            note.discardWithConfirmation()
        } label: {
            utilityLabel(
                "Discard",
                systemImage: "trash",
                showsTitle: showsTitle
            )
                .frame(height: Self.controlLabelHeight)
        }
        .buttonStyle(.bordered)
        .keyboardShortcut(
            shortcuts.binding(for: .quickNoteDiscard).keyEquivalent,
            modifiers: shortcuts.binding(for: .quickNoteDiscard).eventModifiers
        )
        .disabled(note.text.isEmpty)
        .help(
            "Discard this note. "
                + shortcuts.binding(for: .quickNoteDiscard).spokenDescription
                + "."
        )
        .accessibilityLabel("Discard this note")
        .accessibilityHint("Remove this quick note. Longer notes ask for confirmation.")
    }

    /// Saves and closes. Return belongs to the editor, so this is on
    /// Command-Return, and it steps aside to Shift-Command-Return while the
    /// suggestion row is showing and has claimed Command-Return.
    private var doneButton: some View {
        Button {
            note.done()
        } label: {
            Text("Done")
                .frame(height: Self.controlLabelHeight)
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(
            .return,
            modifiers: rows.contains(.suggestion)
                ? [.command, .shift]
                : [.command]
        )
        .help(
            rows.contains(.suggestion)
                ? "Save and close. Shift-Command-Return while a suggestion is showing."
                : "Save and close. Command-Return."
        )
    }

    /// Every control in the bar is sized from its label, so one height here
    /// keeps them level and keeps each of them a target worth aiming at: 22pt
    /// of label plus the small control's own padding lands just under the
    /// 32pt row.
    private static let controlLabelHeight: CGFloat = 22

    /// Command-W has to close the pad like any other window, and this panel is
    /// built by hand rather than declared as a scene, so the pad carries the
    /// shortcut itself. It leaves the way every other exit does, by saving.
    private var closeShortcut: some View {
        Button("Close Quick Note") {
            note.done()
        }
        .keyboardShortcut("w", modifiers: .command)
        .hidden()
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private var filingPicker: some View {
        VStack(alignment: .leading, spacing: NookSpacing.xSmall) {
            Text("Add these words to")
                .font(NookType.control)
            if note.recentMeetingTargets.isEmpty {
                Text("No meetings have been recorded yet.")
                    .font(NookType.caption)
                    .foregroundStyle(.secondary)
            }
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
                .buttonStyle(QuickNotePickerRowStyle())
            }

            Divider()
                .padding(.vertical, 2)

            Button("Open in Library") {
                showsFilingPicker = false
                note.saveAndOpenInLibrary()
            }
            .buttonStyle(.borderless)
            .help("Save this note and show it in the library.")
        }
        .padding(NookSpacing.medium + 2)
        .frame(width: 280)
    }

    @ViewBuilder
    private func status(_ detail: StatusDetail) -> some View {
        let text = statusText(detail)
        if !text.isEmpty {
            Text(text)
                .font(NookType.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .accessibilityLabel(statusText(.full))
                .animation(NookMotion.quick, value: text)
        }
    }

    /// The running total, and whether the words are safe yet. "Saved" is only
    /// shown once a save has actually landed and nothing has been typed since,
    /// so it is a fact rather than a reassurance.
    private func statusText(_ detail: StatusDetail) -> String {
        guard note.wordCount > 0 else { return "" }
        let saved = note.lastSavedAt != nil && !note.hasUnsavedEdits
        let words = "\(note.wordCount) word\(note.wordCount == 1 ? "" : "s")"
        switch detail {
        case .full: return saved ? "\(words) · Saved" : words
        case .short: return saved ? "Saved" : words
        case .hidden: return ""
        }
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

/// The meeting rows in the filing popover, which are the pad's only piece of
/// custom chrome. They owe the user the same states as every system control
/// beside them: something under the pointer, something when pressed, and a
/// focus ring for anyone who never touches the pointer at all.
private struct QuickNotePickerRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RowBody(configuration: configuration)
    }

    private struct RowBody: View {
        let configuration: Configuration
        @State private var isHovering = false
        @Environment(\.isFocused) private var isFocused

        private var shape: RoundedRectangle {
            RoundedRectangle(
                cornerRadius: NookRadius.control,
                style: .continuous
            )
        }

        var body: some View {
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, NookSpacing.small)
                .padding(.vertical, NookSpacing.xSmall + 1)
                .background { shape.fill(fill) }
                .nookFocusRing(shape, isVisible: isFocused)
                .contentShape(.rect)
                .onHover { isHovering = $0 }
                .animation(NookMotion.quick, value: isHovering)
        }

        private var fill: Color {
            if configuration.isPressed {
                return NookPalette.accent.opacity(0.18)
            }
            return isHovering ? NookPalette.accent.opacity(0.10) : .clear
        }
    }
}

/// One thing the pad has to say above its bar.
enum QuickNotePadRow: Hashable {
    /// Persistent while an off-device engine is chosen. A privacy fact, not a
    /// hint, so it is never traded away for something more recent.
    case outbound(provider: String)
    case notice(text: String, isFailure: Bool)
    case hearing(text: String)
    case suggestion
    case noAssistant
}

/// Which of those rows are shown, and in what order.
///
/// A reducer rather than a stack of `if`s in the view: five things can want
/// that space, there is only ever room for two, and which two win is a product
/// decision worth being able to read and test on its own. The pad grew three
/// stacked banners the last time this lived inline.
enum QuickNotePadLayout {
    /// Above this the bar stops being a bar and the editor starts shrinking
    /// under a wall of notices.
    static let maximumRows = 2

    static func rows(
        outboundProvider: String?,
        notice: String?,
        noticeIsFailure: Bool,
        hearing: String?,
        hasSuggestion: Bool,
        hasAssistant: Bool
    ) -> [QuickNotePadRow] {
        var rows: [QuickNotePadRow] = []
        // Order is priority. The privacy warning is first because it is the
        // only one whose absence would mislead, and last to be dropped.
        if let outboundProvider {
            rows.append(.outbound(provider: outboundProvider))
        }
        if let notice, !notice.isEmpty {
            rows.append(.notice(text: notice, isFailure: noticeIsFailure))
        }
        if let hearing, !hearing.isEmpty {
            rows.append(.hearing(text: hearing))
        }
        if hasSuggestion {
            rows.append(.suggestion)
        }
        if !hasAssistant {
            rows.append(.noAssistant)
        }
        return Array(rows.prefix(maximumRows))
    }
}
