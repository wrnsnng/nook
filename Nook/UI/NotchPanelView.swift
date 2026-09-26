import AppKit
import SwiftUI

/// The notch island.
///
/// One black shape, flush with the screen edge and joined to it by concave
/// shoulders, that grows out of the camera housing, springs between states,
/// and folds back into the housing when it is done. The window behind it is
/// only a stage: `NotchPanelCoordinator` enlarges it before the island grows
/// and trims it after the island settles, so every movement here runs on one
/// curve, in SwiftUI, with the content.
///
/// The shell observes `MeetingCoordinator` for its slow state only (phase,
/// captions on or off, panel mode, hidden). Audio level, elapsed time and the
/// live transcript are read exclusively by small leaf views that observe
/// `meeting.live` (`MeetingLiveSignals`); nothing in this body, its computed
/// views or its accessibility strings touches them. Before that split the
/// shape and layout re-ran on every 80 ms meter tick for the whole recording.
struct NotchPanelView: View {
    @EnvironmentObject private var meeting: MeetingCoordinator
    @EnvironmentObject private var geometry: NotchPanelGeometry
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Bumped when the user opens My notes, so the editor asks for the
    /// keyboard exactly once per open rather than polling a focus state
    /// that re-renders at the meter's rate.
    @State private var notesFocusToken = 0
    /// Which consent action holds keyboard focus. Assigned explicitly because
    /// the panel takes key focus to answer with Return, and a keyboard user
    /// must be able to see what Return will do before pressing it.
    @FocusState private var detectedAction: DetectedAction?
    /// What was on the island before it began to fold away, so the content
    /// leaves with the shape instead of switching to an empty state first.
    @State private var retainedPhase: MeetingPhase = .idle
    @State private var retainedMode: NotchIslandMode = .idle
    @State private var hoverTask: Task<Void, Never>?
    /// The shelf is a one-line note field instead of controls.
    @State private var isComposingNote = false
    @State private var noteDraft = ""
    @FocusState private var noteFieldFocused: Bool
    /// Bumped on each added line, to acknowledge it without a dialog.
    @State private var addedNoteCount = 0
    @Namespace private var island
    private let rendersForSnapshot: Bool

    init(rendersForSnapshot: Bool = false, showsNoteLine: Bool = false) {
        self.rendersForSnapshot = rendersForSnapshot
        _isComposingNote = State(initialValue: showsNoteLine)
        _noteDraft = State(initialValue: showsNoteLine ? "Ask Ana about the launch checklist" : "")
    }

    // MARK: - State

    private var liveMode: NotchIslandMode {
        NotchPanelMetrics.mode(
            for: meeting.phase,
            showsCaptions: meeting.showLiveCaptions,
            panelMode: meeting.panelMode,
            isHidden: meeting.topPanelHidden,
            detectionPromptIsCompact: geometry.detectionPromptIsCompact,
            isHovering: geometry.isHovering
        )
    }

    private var mode: NotchIslandMode {
        geometry.isTucking ? retainedMode : liveMode
    }

    private var phase: MeetingPhase {
        geometry.isTucking ? retainedPhase : meeting.phase
    }

    private var bodySize: CGSize {
        let preferred = NotchPanelMetrics.bodySize(
            for: mode,
            cameraHousingWidth: geometry.cameraHousingWidth
        )
        return CGSize(
            width: min(preferred.width, geometry.maximumPanelWidth),
            height: preferred.height
        )
    }

    private var islandHeight: CGFloat {
        bodySize.height + geometry.topInset
    }

    /// Hidden inside the camera housing at 0, fully open at 1. On a display
    /// without a housing the island grows down out of the top edge instead.
    private var revealedSize: CGSize {
        let progress = reduceMotion ? 1 : geometry.revealProgress
        let hasHousing = geometry.cameraHousingWidth > 1
        let closedWidth = hasHousing
            ? min(geometry.cameraHousingWidth, bodySize.width)
            : bodySize.width * 0.5
        let closedHeight = hasHousing ? geometry.topInset : 0
        return CGSize(
            width: closedWidth + (bodySize.width - closedWidth) * progress,
            height: closedHeight + (islandHeight - closedHeight) * progress
        )
    }

    /// Content arrives after the shape has opened most of the way, and
    /// leaves first when it folds.
    private var contentReveal: CGFloat {
        guard !reduceMotion else { return 1 }
        return min(1, max(0, (geometry.revealProgress - 0.35) / 0.65))
    }

    private var increaseContrast: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    private var morphAnimation: Animation? {
        reduceMotion ? nil : NookMotion.morph
    }

    // MARK: - Body

    var body: some View {
        Group {
            if mode == .hiddenRecording {
                hiddenRecordingIndicator
            } else {
                islandShell
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(morphAnimation, value: mode)
        // The physical camera housing is the material. Keeping this surface
        // edge-black in both app appearances makes it read as part of the
        // display bezel instead of another themed window.
        .environment(\.colorScheme, .dark)
        .tint(NookPalette.accentHighlight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            mode == .hiddenRecording
                ? "Nook recording indicator"
                : "Nook meeting panel"
        )
        .accessibilityIdentifier("nook.notchPanel")
        .onAppear(perform: retainCurrentState)
        .onChange(of: liveMode) { _, _ in retainCurrentState() }
        .onChange(of: meeting.phase) { _, _ in retainCurrentState() }
        .onChange(of: meeting.noteLineRequest) { _, _ in takeNote() }
    }

    private func retainCurrentState() {
        guard !geometry.isTucking else { return }
        retainedMode = liveMode
        retainedPhase = meeting.phase
    }

    private var islandShell: some View {
        let shape = NotchIslandShape(
            bottomRadius: NotchPanelMetrics.bottomRadius(for: mode),
            shoulder: NotchPanelMetrics.shoulder
        )
        let floats = mode.floatsAboveContent
        return ZStack(alignment: .top) {
            shape.fill(Color.black)

            IslandRimLight(
                style: rimStyle,
                live: meeting.live,
                bottomRadius: NotchPanelMetrics.bottomRadius(for: mode),
                increaseContrast: increaseContrast
            )

            islandContent
                .frame(width: bodySize.width, height: islandHeight, alignment: .top)
                .opacity(contentReveal)
                .blur(radius: (1 - contentReveal) * 6)
                .scaleEffect(0.9 + 0.1 * contentReveal, anchor: .top)
        }
        .frame(
            width: revealedSize.width + 2 * NotchPanelMetrics.shoulder,
            height: max(0, revealedSize.height),
            alignment: .top
        )
        .clipShape(shape)
        .compositingGroup()
        .shadow(
            color: .black.opacity(floats ? 0.38 : 0),
            radius: floats ? 18 : 0,
            y: floats ? 9 : 0
        )
        .contentShape(shape)
        .onHover(perform: hoverChanged)
    }

    private var rimStyle: IslandRimLight.Style {
        switch mode {
        case .recordingCompact, .recordingExpanded:
            .voice(isPaused: meeting.isPaused)
        case .processing:
            meeting.summaryProgress.map {
                .progress(Double($0.part) / Double(max(1, $0.total)))
            } ?? .sweep
        case .completed:
            .success
        case .failed:
            .attention
        case .detected:
            .invite
        default:
            .resting
        }
    }

    /// Opens the shelf once the pointer has settled and closes it once it
    /// has clearly left, so passing across the menu bar does not flap it.
    private func hoverChanged(_ hovering: Bool) {
        hoverTask?.cancel()
        guard !rendersForSnapshot else { return }
        guard hovering || !isComposingNote else { return }
        hoverTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(hovering ? 60 : 340))
            guard !Task.isCancelled else { return }
            withAnimation(morphAnimation) {
                geometry.isHovering = hovering
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var islandContent: some View {
        ZStack(alignment: .top) {
            switch phase {
            case .idle:
                cardLayout { idleContent }
            case .detected(let detection):
                if geometry.detectionPromptIsCompact {
                    cardLayout { compactDetectedContent(detection) }
                } else {
                    cardLayout { expandedDetectedContent(detection) }
                }
            case .recording(let title, _):
                if meeting.showLiveCaptions {
                    expandedRecordingContent(title: title)
                } else {
                    compactRecordingContent(title: title)
                }
            case .processing(let step):
                cardLayout { processingContent(step) }
            case .completed(let title):
                cardLayout { completedContent(title) }
            case .failed(let message):
                cardLayout { failedContent(message) }
            }
        }
        .id(mode.contentIdentity)
        .transition(.islandContent(reduceMotion: reduceMotion))
    }

    /// A card sits below the menu bar band, clear of the camera.
    private func cardLayout<Content: View>(
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: geometry.topInset)
                .accessibilityHidden(true)
            content()
                .padding(.horizontal, 16)
                .frame(height: bodySize.height)
        }
    }

    /// What the notch offers when nothing is happening: the next event if
    /// the calendar knows one, and the three things Nook starts from.
    private var idleContent: some View {
        HStack(spacing: 11) {
            NookPresence(
                state: .resting,
                size: 24,
                showsSurface: false
            )
            VStack(alignment: .leading, spacing: 1) {
                if let event = geometry.upcomingEvent {
                    Text(event.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    UpcomingEventTime(startDate: event.startDate)
                } else {
                    Text("Nook")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Ready when a meeting starts")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 6)

            Button {
                geometry.isPeeking = false
                meeting.startManualMeeting()
            } label: {
                IslandCapsuleLabel(title: "Record")
            }
            .buttonStyle(IslandCapsuleButtonStyle())
            .help("Start recording")

            if geometry.upcomingEvent != nil, geometry.upcomingHasPrep {
                IslandControl(symbol: "list.bullet.clipboard", label: "Prep for this meeting") {
                    geometry.isPeeking = false
                    AppModel.shared.openPrepBrief()
                }
            }
            IslandControl(symbol: "square.and.pencil", label: "Quick note") {
                geometry.isPeeking = false
                AppModel.shared.quickNote.present()
            }
            IslandControl(symbol: "rectangle.stack", label: "Open Library") {
                geometry.isPeeking = false
                AppModel.shared.openLibrary()
            }
        }
    }

    /// The prompt after it has been on screen for a while.
    ///
    /// It shrinks rather than disappearing. A prompt that vanishes has answered
    /// itself on the user's behalf, and the answer it picked was "not now":
    /// someone who looked away for a moment came back to an unrecorded meeting
    /// with no sign Nook had ever offered. Both answers stay one click away.
    private func compactDetectedContent(_ detection: DetectedMeeting) -> some View {
        HStack(spacing: 8) {
            MeetingAppMark(appName: detection.appName, size: 24)
                .matchedGeometryEffect(id: "live-mark", in: island)

            Button {
                meeting.startDetectedMeeting()
            } label: {
                IslandCapsuleLabel(title: "Record")
            }
            .buttonStyle(IslandCapsuleButtonStyle())
            .keyboardShortcut(.defaultAction)
            .focused($detectedAction, equals: .record)
            // The collapsed prompt has no room for the meeting title, so the
            // tooltip carries what the panel dropped.
            .help("Record \(detection.suggestedTitle) in \(detection.appName)")
            .accessibilityHint("Starts recording \(detection.suggestedTitle) locally")

            Button {
                meeting.dismissPrompt()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(IslandControlButtonStyle())
            .keyboardShortcut(.cancelAction)
            .focused($detectedAction, equals: .dismiss)
            .help("Not now")
            .accessibilityLabel("Not now")
            .accessibilityHint("Leaves this meeting unrecorded")
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Record \(detection.suggestedTitle) in \(detection.appName)?")
        .onAppear {
            guard !rendersForSnapshot else { return }
            // Return still answers the prompt, so focus stays on Record.
            detectedAction = .record
        }
    }

    private func expandedDetectedContent(_ detection: DetectedMeeting) -> some View {
        HStack(spacing: 11) {
            MeetingAppMark(appName: detection.appName, size: 30)
                .matchedGeometryEffect(id: "live-mark", in: island)

            VStack(alignment: .leading, spacing: 1) {
                Text(detection.suggestedTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text("\(detection.appName) · Record this meeting?")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            Button("Not Now") {
                meeting.dismissPrompt()
            }
            .buttonStyle(PanelTextButtonStyle())
            .keyboardShortcut(.cancelAction)
            .focused($detectedAction, equals: .dismiss)
            .help("Not now")
            .accessibilityHint("Leaves this meeting unrecorded")

            Button {
                meeting.startDetectedMeeting()
            } label: {
                IslandCapsuleLabel(title: "Record")
            }
            .buttonStyle(IslandCapsuleButtonStyle())
            .keyboardShortcut(.defaultAction)
            .focused($detectedAction, equals: .record)
            .accessibilityHint("Starts recording locally")
        }
        .onAppear {
            guard !rendersForSnapshot else { return }
            // Return answers the prompt, so focus opens on Record.
            detectedAction = .record
        }
    }

    // MARK: Recording

    /// Waveform and clock either side of the camera, and nothing below the
    /// menu bar until the pointer asks for the controls.
    private func compactRecordingContent(title: String) -> some View {
        let isPaused = meeting.isPaused
        let showsControls = mode == .recordingCompact(showsControls: true)
        return RecordingSpokenLabel(live: meeting.live, describe: { spokenElapsed in
            "\(isPaused ? "Paused" : "Recording") \(title), \(spokenElapsed)"
        }) {
            VStack(spacing: 0) {
                RecordingSpokenLabel(live: meeting.live, describe: { spokenElapsed in
                    "Expand \(title), \(spokenElapsed)"
                }) {
                    Button {
                        meeting.expandTopPanel()
                    } label: {
                        earsRow(isPaused: isPaused)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Expand meeting workspace")
                    // The shelf appears on hover, which VoiceOver and the
                    // keyboard cannot do. Every shelf control is also an
                    // action on this element, so none is pointer-only.
                    .accessibilityAction(named: isPaused ? "Resume recording" : "Pause recording") {
                        meeting.togglePause()
                    }
                    .accessibilityAction(named: "Take a note") {
                        takeNote()
                    }
                    .accessibilityAction(named: "Flag this moment") {
                        meeting.flagMoment()
                    }
                    .accessibilityAction(named: "Hide top panel") {
                        meeting.hideTopPanel()
                    }
                    .accessibilityAction(named: "Finish Meeting") {
                        meeting.stopRecording()
                    }
                }
                .frame(height: geometry.topInset)

                if showsControls {
                    ZStack {
                        if isComposingNote {
                            noteLine
                                .transition(.islandContent(reduceMotion: reduceMotion))
                        } else {
                            controlShelf
                                .transition(.islandContent(reduceMotion: reduceMotion))
                        }
                    }
                    .frame(height: bodySize.height)
                    .transition(.islandContent(reduceMotion: reduceMotion))
                }
            }
            .accessibilityElement(children: .contain)
        }
    }

    private func earsRow(isPaused: Bool) -> some View {
        let housing = geometry.cameraHousingWidth
        let ear = max(0, (bodySize.width - housing) / 2)
        return HStack(spacing: 0) {
            IslandWaveform(live: meeting.live, isPaused: isPaused)
                .frame(width: 34, height: 14)
                .matchedGeometryEffect(id: "live-mark", in: island)
                .padding(.leading, 16)
                .frame(width: ear, alignment: .leading)

            Color.clear
                .frame(width: housing)
                .accessibilityHidden(true)

            ZStack(alignment: .trailing) {
                if meeting.momentAcknowledgedAt != nil {
                    // The glyph alone: the ear is one clock wide, and the
                    // flag bounces in where the time was for three seconds.
                    IslandFlagMark()
                        .transition(.islandContent(reduceMotion: reduceMotion))
                } else {
                    NotchRecordingClock(live: meeting.live, isPaused: isPaused)
                        .transition(.islandContent(reduceMotion: reduceMotion))
                }
            }
            .padding(.trailing, 16)
            .frame(width: ear, alignment: .trailing)
            .animation(morphAnimation, value: meeting.momentAcknowledgedAt)
        }
    }

    /// The controls that hang below the ears while the pointer is on them.
    /// They arrive one after another, left to right, so the shelf reads as
    /// unfolding rather than appearing.
    private var controlShelf: some View {
        HStack(spacing: 10) {
            ForEach(Array(shelfControls.enumerated()), id: \.element.id) { index, control in
                control.view
                    .transition(
                        .islandContent(reduceMotion: reduceMotion)
                            .animation(
                                reduceMotion
                                    ? nil
                                    : NookMotion.morph.delay(0.03 * Double(index))
                            )
                    )
            }
        }
        .padding(.bottom, 4)
    }

    private struct ShelfControl: Identifiable {
        let id: String
        let view: AnyView
    }

    private var shelfControls: [ShelfControl] {
        [
            ShelfControl(id: "captions", view: AnyView(
                IslandControl(
                    symbol: "captions.bubble",
                    label: "Show live transcript",
                    action: meeting.expandTopPanel
                )
            )),
            ShelfControl(id: "note", view: AnyView(
                IslandControl(
                    symbol: "square.and.pencil",
                    label: "Take a note",
                    action: takeNote
                )
            )),
            ShelfControl(id: "pause", view: AnyView(
                IslandControl(
                    symbol: meeting.isPaused ? "play.fill" : "pause.fill",
                    label: meeting.isPaused ? "Resume recording" : "Pause recording",
                    tint: meeting.isPaused ? NookPalette.success : nil,
                    action: meeting.togglePause
                )
                .disabled(meeting.pauseTransitionInFlight)
            )),
            ShelfControl(id: "flag", view: AnyView(
                IslandControl(
                    symbol: meeting.momentAcknowledgedAt == nil ? "flag.fill" : "checkmark",
                    label: "Flag this moment",
                    tint: meeting.momentAcknowledgedAt == nil ? nil : NookPalette.accentHighlight,
                    bounceTrigger: meeting.momentAcknowledgedAt != nil,
                    action: meeting.flagMoment
                )
                .accessibilityValue(
                    meeting.momentAcknowledgedAt == nil ? "" : "Moment flagged"
                )
            )),
            ShelfControl(id: "hide", view: AnyView(
                IslandControl(
                    // Distinct from the chevron that collapses the expanded
                    // panel: hiding puts the whole surface away behind the
                    // camera, collapsing only takes the workspace down a size,
                    // and one glyph for both said they did the same thing.
                    symbol: "arrow.up.to.line",
                    label: "Hide top panel",
                    action: meeting.hideTopPanel
                )
            )),
            ShelfControl(id: "stop", view: AnyView(
                IslandControl(
                    symbol: "stop.fill",
                    label: "Finish Meeting",
                    tint: NookPalette.danger,
                    action: meeting.stopRecording
                )
                .disabled(meeting.pauseTransitionInFlight)
            )),
        ]
    }

    private func expandedRecordingContent(title: String) -> some View {
        VStack(spacing: 0) {
            workspaceShortcuts
            expandedRecordingChrome(title: title)
                .frame(height: geometry.topInset)
                .padding(.horizontal, 18)

            VStack(spacing: 8) {
                IslandModePicker(
                    selection: meeting.panelMode,
                    notesDetached: meeting.liveNotesDetached
                ) { mode in
                    meeting.selectPanelMode(mode)
                    if mode == .notes {
                        requestNotesFocus()
                    }
                }

                Group {
                    switch meeting.panelMode {
                    case .transcript:
                        // The waveform beside the title carries the live-audio
                        // motion for the expanded panel; a second animated
                        // thread here competed with it.
                        NotchCaptionStream(
                            live: meeting.live,
                            notice: meeting.liveCaptionNotice,
                            moments: meeting.liveMoments.map(\.offset)
                        )
                    case .summary:
                        LiveSummaryPanel(
                            insights: meeting.liveInsights,
                            isRefreshing: meeting.liveSummaryIsRefreshing,
                            updatedAt: meeting.liveSummaryUpdatedAt,
                            live: meeting.live,
                            refresh: meeting.refreshLiveSummary
                        )
                    case .notes:
                        if meeting.liveNotesDetached {
                            DetachedNotesPanel(
                                bringForward: {
                                    guard !rendersForSnapshot else { return }
                                    AppModel.shared.openLiveNotes()
                                },
                                bringBack: {
                                    guard !rendersForSnapshot else { return }
                                    AppModel.shared.returnLiveNotesToPanel()
                                    requestNotesFocus()
                                }
                            )
                        } else {
                            LiveNotesPanel(
                                notes: $meeting.liveNotes,
                                focusToken: notesFocusToken,
                                detach: {
                                    AppModel.shared.openLiveNotes()
                                }
                            )
                        }
                    }
                }
                .id(meeting.panelMode)
                .transition(.islandContent(reduceMotion: reduceMotion))
            }
            .padding(.horizontal, 22)
            .padding(.top, 6)
            .padding(.bottom, 12)
            .frame(height: bodySize.height, alignment: .top)
            .animation(morphAnimation, value: meeting.panelMode)
        }
    }

    /// Keys that work while the panel has focus: Esc takes the workspace down
    /// a size, and Command-1 to 3 switch views, as tabs do in any Mac app.
    private var workspaceShortcuts: some View {
        ZStack {
            Button("Collapse Top Panel", action: meeting.collapseTopPanel)
                .keyboardShortcut(.cancelAction)
            ForEach(Array(MeetingPanelMode.allCases.enumerated()), id: \.element) { index, mode in
                Button("Show \(mode.label)") {
                    meeting.selectPanelMode(mode)
                    if mode == .notes { requestNotesFocus() }
                }
                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
            }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func expandedRecordingChrome(title: String) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 9) {
                IslandWaveform(live: meeting.live, isPaused: meeting.isPaused)
                    .frame(width: 28, height: 13)
                    .matchedGeometryEffect(id: "live-mark", in: island)
                    .accessibilityLabel(meeting.isPaused ? "Recording paused" : "Recording live")

                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Color.clear
                .frame(width: geometry.cameraHousingWidth)
                .accessibilityHidden(true)

            HStack(spacing: 6) {
                NotchRecordingClock(live: meeting.live, isPaused: meeting.isPaused)

                recordingControls

                Button {
                    meeting.collapseTopPanel()
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(IslandControlButtonStyle(sideLength: 26))
                .help("Collapse top panel")
                .accessibilityLabel("Collapse top panel")
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    @ViewBuilder
    private var recordingControls: some View {
        if rendersForSnapshot {
            Image(systemName: "pause.fill")
                .font(.system(size: 10.5, weight: .bold))
                .frame(width: 26, height: 26)
                .background(.white.opacity(0.09), in: Circle())

            Image(systemName: "stop.fill")
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(NookPalette.danger)
                .frame(width: 26, height: 26)
                .background(.white.opacity(0.09), in: Circle())
        } else {
            Button {
                meeting.togglePause()
            } label: {
                Image(systemName: meeting.isPaused ? "play.fill" : "pause.fill")
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(
                IslandControlButtonStyle(
                    tint: meeting.isPaused ? NookPalette.success : nil,
                    sideLength: 26
                )
            )
            .disabled(meeting.pauseTransitionInFlight)
            .help(meeting.isPaused ? "Resume recording" : "Pause recording")
            .accessibilityLabel(
                meeting.isPaused ? "Resume recording" : "Pause recording"
            )

            Button {
                meeting.stopRecording()
            } label: {
                Image(systemName: "stop.fill")
            }
            .buttonStyle(
                IslandControlButtonStyle(tint: NookPalette.danger, sideLength: 26)
            )
            .disabled(meeting.pauseTransitionInFlight)
            .help("Stop and create notes")
            .accessibilityLabel("Stop recording and create notes")
        }
    }

    /// Opens My notes with the cursor in it, wherever the notes live: in the
    /// notch, or brought forward in their own window.
    private func takeNote() {
        guard !rendersForSnapshot else { return }
        if meeting.liveNotesDetached {
            AppModel.shared.openLiveNotes()
            return
        }
        if meeting.showLiveCaptions {
            meeting.selectPanelMode(.notes)
            requestNotesFocus()
            return
        }
        // Stay compact: the shelf becomes a note line. The panel takes key
        // status without activating Nook, so the meeting app stays in front.
        withAnimation(morphAnimation) {
            isComposingNote = true
            geometry.isHovering = true
        }
        NSApp.windows
            .first { $0.identifier?.rawValue == "nook.notchPanel" }?
            .makeKey()
        Task { @MainActor in
            await Task.yield()
            noteFieldFocused = true
        }
    }

    /// One line, straight into My notes. Return adds it and keeps the field
    /// open for the next; Esc or leaving an empty field puts the controls
    /// back.
    private var noteLine: some View {
        HStack(spacing: 8) {
            Image(systemName: addedNoteCount == 0 ? "square.and.pencil" : "checkmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(NookPalette.accentHighlight)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 18)
                .accessibilityHidden(true)

            TextField("Note for this meeting", text: $noteDraft, prompt: Text("Jot a note, then press Return"))
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($noteFieldFocused)
                .onSubmit(addNoteLine)
                .onExitCommand(perform: endNoteLine)
                .onChange(of: noteFieldFocused) { _, focused in
                    if !focused, noteDraft.isEmpty { endNoteLine() }
                }

            Button {
                if noteDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    endNoteLine()
                } else {
                    addNoteLine()
                }
            } label: {
                Image(systemName: noteDraft.isEmpty ? "xmark" : "return")
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(IslandControlButtonStyle(sideLength: 26))
            .help(noteDraft.isEmpty ? "Done" : "Add to My notes")
            .accessibilityLabel(noteDraft.isEmpty ? "Done taking notes" : "Add to My notes")
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(.white.opacity(0.07), in: Capsule())
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Quick note")
    }

    private func addNoteLine() {
        guard let notes = LiveNoteLine.appending(noteDraft, to: meeting.liveNotes) else {
            endNoteLine()
            return
        }
        meeting.liveNotes = notes
        noteDraft = ""
        withAnimation(morphAnimation) { addedNoteCount += 1 }
    }

    private func endNoteLine() {
        withAnimation(morphAnimation) {
            isComposingNote = false
            addedNoteCount = 0
            noteDraft = ""
        }
        noteFieldFocused = false
        hoverChanged(false)
    }

    private func requestNotesFocus() {
        Task { @MainActor in
            await Task.yield()
            notesFocusToken += 1
        }
    }

    // MARK: After the meeting

    private func processingContent(_ step: MeetingPhase.ProcessingStep) -> some View {
        HStack(spacing: 12) {
            IslandWritingMark()

            VStack(alignment: .leading, spacing: 1) {
                Text("Tucking this conversation away")
                    .font(.system(size: 13, weight: .semibold))
                Text(processingDetail(for: step))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .lineLimit(1)
            }

            Spacer()
            if step != .discarding, meeting.canCancelProcessing {
                Button("Cancel") {
                    meeting.requestProcessingCancellation()
                }
                .buttonStyle(PanelTextButtonStyle())
                .help("Cancel and discard recording")
                .accessibilityHint("Asks before permanently discarding this recording")
            }
        }
    }

    private func completedContent(_ title: String) -> some View {
        HStack(spacing: 12) {
            IslandCheckmark()

            VStack(alignment: .leading, spacing: 1) {
                Text("Tucked away")
                    .font(.system(size: 13, weight: .semibold))
                Text("\(title) · Saved as Markdown")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button(meeting.lastSavedNoteID == nil ? "Open Library" : "Open Note") {
                AppModel.shared.openLibrary(noteID: meeting.lastSavedNoteID)
                meeting.resetStatus()
            }
            // No defaultAction here: the completed panel never becomes key,
            // so the shortcut was a promise Return could not keep.
            .buttonStyle(PanelTextButtonStyle(isPrimary: true))
        }
    }

    private func failedContent(_ message: String) -> some View {
        HStack(spacing: 12) {
            IslandAttentionMark()

            VStack(alignment: .leading, spacing: 1) {
                Text("Nook needs a hand")
                    .font(.system(size: 13, weight: .semibold))
                Text(panelFailureMessage(message))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            Spacer(minLength: 8)

            if let permission = meeting.requiredPermission {
                Button(permission.primaryActionTitle) {
                    meeting.performPermissionPrimaryAction()
                }
                .buttonStyle(PanelTextButtonStyle())

                Button("Open Settings") {
                    meeting.revealPermissions()
                }
                .buttonStyle(IslandCapsuleButtonStyle())
            } else {
                Button("Dismiss") {
                    meeting.resetStatus()
                }
                .buttonStyle(PanelTextButtonStyle())
            }
        }
    }

    // MARK: Hidden

    private var hiddenRecordingIndicator: some View {
        let isPaused = meeting.isPaused
        let attachedToCamera = geometry.cameraHousingWidth > 1
        return RecordingSpokenLabel(live: meeting.live, describe: { spokenElapsed in
            "\(isPaused ? "Recording paused" : "Recording"), \(spokenElapsed). Show meeting panel"
        }) {
            Button {
                meeting.restoreTopPanel()
            } label: {
                HStack(spacing: 6) {
                    NotchRecordingClock(live: meeting.live, isPaused: isPaused, isSmall: true)

                    Circle()
                        .fill(isPaused ? NookPalette.warning : NookPalette.danger)
                        .frame(width: 6, height: 6)
                        .shadow(
                            color: (isPaused ? NookPalette.warning : NookPalette.danger)
                                .opacity(0.6),
                            radius: 3
                        )
                        .phaseAnimator(
                            reduceMotion || isPaused ? [1.0] : [1.0, 0.45]
                        ) { dot, opacity in
                            dot.opacity(opacity)
                        } animation: { _ in
                            .easeInOut(duration: 1.1)
                        }
                        .accessibilityHidden(true)
                }
                .frame(width: bodySize.width, height: geometry.topInset)
                .background {
                    UnevenRoundedRectangle(
                        topLeadingRadius: 0,
                        bottomLeadingRadius: attachedToCamera ? 0 : 9,
                        bottomTrailingRadius: 9,
                        topTrailingRadius: 0,
                        style: .continuous
                    )
                    .fill(Color.black)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(HiddenRecordingIndicatorStyle())
            .help("Show meeting panel")
        }
        .accessibilityHint("Restores the compact recording controls")
        .offset(
            x: rendersForSnapshot
                ? (geometry.cameraHousingWidth + bodySize.width) / 2
                : 0
        )
        .opacity(contentReveal)
        .scaleEffect(x: 0.6 + 0.4 * contentReveal, y: 1, anchor: .leading)
    }

    // MARK: - Copy

    private func panelFailureMessage(_ message: String) -> String {
        if let permission = meeting.requiredPermission {
            return permission.instruction
        }
        let normalized = message.lowercased()
        if normalized.contains("screen") || normalized.contains("system audio") {
            return "Allow Screen & System Audio Recording, then restart Nook."
        }
        if normalized.contains("microphone") {
            return "Allow Microphone access in Privacy & Security, then try again."
        }
        return message
    }

    private func processingDetail(for step: MeetingPhase.ProcessingStep) -> String {
        // One sentence source shared with the live workspace, so the same
        // step never reads two different ways. The coordinator's version adds
        // the part counter while a long meeting is being condensed, without
        // which several minutes of "Distilling the conversation" with nothing
        // moving reads as a hang.
        let detail = meeting.processingDetail
        return detail.isEmpty ? step.displaySentence : detail
    }

}

/// Which live caption lines carry a flag. A finished line does when a flag
/// fell while it was said, with a second of grace either side for the
/// recogniser's timing; the line still being heard does when a flag fell
/// after the last finished one.
enum LiveCaptionFlags {
    static func isFlagged(
        _ lineID: LiveCaptionLine.ID,
        segments: [TranscriptSegment],
        moments: [TimeInterval]
    ) -> Bool {
        guard !moments.isEmpty else { return false }
        switch lineID {
        case .segment(let id):
            guard let segment = segments.last(where: { $0.id == id }) else { return false }
            let said = (segment.startTime - 1)...(segment.startTime + segment.duration + 1)
            return moments.contains { said.contains($0) }
        case .partial:
            let lastEnd = segments.last.map { $0.startTime + $0.duration } ?? 0
            return moments.contains { $0 > lastEnd }
        }
    }
}

/// How a line typed into the notch joins My notes: as its own Markdown
/// bullet, never glued to the end of whatever was typed before it.
enum LiveNoteLine {
    /// The notes with `line` added, or nil when there is nothing to add.
    static func appending(_ line: String, to notes: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let separator = notes.isEmpty || notes.hasSuffix("\n") ? "" : "\n"
        return notes + separator + "- " + trimmed
    }
}

// MARK: - Shape

/// The island: flush with the top edge, concave shoulders where it meets the
/// bezel, and continuous corners below. Drawn slightly above its bounds so
/// no hairline can show along the physical screen edge.
struct NotchIslandShape: Shape {
    var bottomRadius: CGFloat
    var shoulder: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(bottomRadius, shoulder) }
        set {
            bottomRadius = newValue.first
            shoulder = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let left = rect.minX + shoulder
        let right = rect.maxX - shoulder
        let top = rect.minY
        let bottom = rect.maxY
        let bodyHeight = max(0, bottom - top)
        let join = min(shoulder, bodyHeight / 2)
        let radius = max(0, min(bottomRadius, (right - left) / 2, bodyHeight - join))

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: top - 2))
        path.addLine(to: CGPoint(x: rect.minX, y: top))
        path.addQuadCurve(
            to: CGPoint(x: left, y: top + join),
            control: CGPoint(x: left, y: top)
        )
        path.addLine(to: CGPoint(x: left, y: bottom - radius))
        // A cubic with its handles pulled in approximates the continuous
        // corner Apple uses for hardware, softer than a circular arc.
        path.addCurve(
            to: CGPoint(x: left + radius, y: bottom),
            control1: CGPoint(x: left, y: bottom - radius * 0.38),
            control2: CGPoint(x: left + radius * 0.38, y: bottom)
        )
        path.addLine(to: CGPoint(x: right - radius, y: bottom))
        path.addCurve(
            to: CGPoint(x: right, y: bottom - radius),
            control1: CGPoint(x: right - radius * 0.38, y: bottom),
            control2: CGPoint(x: right, y: bottom - radius * 0.38)
        )
        path.addLine(to: CGPoint(x: right, y: top + join))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: top),
            control: CGPoint(x: right, y: top)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: top - 2))
        path.closeSubpath()
        return path
    }
}

/// The island's sides and bottom, for the rim light. The top stays open so
/// the island reads as part of the bezel rather than a shape placed on it.
private struct NotchIslandRim: Shape {
    var bottomRadius: CGFloat
    var shoulder: CGFloat
    var inset: CGFloat = 0.6

    var animatableData: CGFloat {
        get { bottomRadius }
        set { bottomRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let left = rect.minX + shoulder + inset
        let right = rect.maxX - shoulder - inset
        let top = rect.minY + shoulder
        let bottom = rect.maxY - inset
        guard bottom > top else { return Path() }
        let radius = max(0, min(bottomRadius - inset, (right - left) / 2, bottom - top))
        var path = Path()
        path.move(to: CGPoint(x: left, y: top))
        path.addLine(to: CGPoint(x: left, y: bottom - radius))
        path.addCurve(
            to: CGPoint(x: left + radius, y: bottom),
            control1: CGPoint(x: left, y: bottom - radius * 0.38),
            control2: CGPoint(x: left + radius * 0.38, y: bottom)
        )
        path.addLine(to: CGPoint(x: right - radius, y: bottom))
        path.addCurve(
            to: CGPoint(x: right, y: bottom - radius),
            control1: CGPoint(x: right - radius * 0.38, y: bottom),
            control2: CGPoint(x: right, y: bottom - radius * 0.38)
        )
        path.addLine(to: CGPoint(x: right, y: top))
        return path
    }
}

// MARK: - Motion

/// Content changing on the island: the old content blurs and falls away
/// quickly; the new content waits for the shape to open, then focuses in.
private struct IslandContentEffect: ViewModifier {
    let progress: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(progress)
            .blur(radius: (1 - progress) * 8)
            .scaleEffect(0.9 + 0.1 * progress, anchor: .top)
    }
}

extension AnyTransition {
    fileprivate static func islandContent(reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .modifier(
                active: IslandContentEffect(progress: 0),
                identity: IslandContentEffect(progress: 1)
            )
            .animation(.spring(response: 0.42, dampingFraction: 0.86).delay(0.09)),
            removal: .modifier(
                active: IslandContentEffect(progress: 0),
                identity: IslandContentEffect(progress: 1)
            )
            .animation(.easeIn(duration: 0.13))
        )
    }
}

/// Follows a meter that publishes every 80 ms at the display's frame rate:
/// quick to rise with a voice, slower to fall, so the motion reads as
/// breathing rather than jitter.
@MainActor
private final class LevelSmoother {
    private var current = 0.0
    private var lastTime: TimeInterval?

    func value(toward target: Double, at time: TimeInterval) -> Double {
        let elapsed = min(0.1, max(0, time - (lastTime ?? time)))
        lastTime = time
        let rate = target > current ? 16.0 : 5.0
        current += (target - current) * (1 - exp(-rate * elapsed))
        return current
    }
}

// MARK: - Leaves that observe the meter

/// The live voice beside the camera: five bars that swell with the meeting
/// and flatten to amber dots while paused.
private struct IslandWaveform: View {
    @ObservedObject var live: MeetingLiveSignals
    let isPaused: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var smoother = LevelSmoother()

    private static let envelope: [Double] = [0.52, 0.84, 1, 0.78, 0.58]

    var body: some View {
        TimelineView(
            .animation(minimumInterval: 1 / 30, paused: isPaused || reduceMotion)
        ) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let target = isPaused ? 0 : live.audioLevel
            let level = reduceMotion ? target : smoother.value(toward: target, at: time)
            Canvas { canvas, size in
                let count = Self.envelope.count
                let barWidth = max(2, size.width / CGFloat(count * 2 - 1))
                let gap = (size.width - barWidth * CGFloat(count)) / CGFloat(count - 1)
                let energy = min(1, level * 1.7)
                canvas.addFilter(
                    .shadow(
                        color: (isPaused ? NookPalette.warning : NookPalette.accent)
                            .opacity(isPaused ? 0 : 0.55),
                        radius: 3
                    )
                )
                for index in 0..<count {
                    let wobble = reduceMotion || isPaused
                        ? 0.8
                        : 0.62 + 0.38 * (sin(time * 8.6 + Double(index) * 1.9) + 1) / 2
                    let height = isPaused
                        ? barWidth
                        : max(
                            barWidth,
                            size.height * (0.16 + 0.84 * energy * Self.envelope[index] * wobble)
                        )
                    let rect = CGRect(
                        x: CGFloat(index) * (barWidth + gap),
                        y: (size.height - height) / 2,
                        width: barWidth,
                        height: height
                    )
                    canvas.fill(
                        Path(roundedRect: rect, cornerRadius: barWidth / 2),
                        with: isPaused
                            ? .color(NookPalette.warning)
                            : .linearGradient(
                                Gradient(colors: [NookPalette.accentHighlight, NookPalette.accent]),
                                startPoint: CGPoint(x: 0, y: rect.minY),
                                endPoint: CGPoint(x: 0, y: rect.maxY)
                            )
                    )
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// Light along the island's lower edge. While recording it breathes with the
/// voice; while notes are being written a band sweeps across it; saving
/// flashes it once.
private struct IslandRimLight: View {
    enum Style: Equatable {
        case resting
        case invite
        case voice(isPaused: Bool)
        case sweep
        /// Known progress through a long meeting, filling the rim from the
        /// left, across the bottom and up the right.
        case progress(Double)
        case success
        case attention
    }

    let style: Style
    let live: MeetingLiveSignals
    let bottomRadius: CGFloat
    let increaseContrast: Bool

    var body: some View {
        ZStack {
            // The resting edge is what separates black glass from a dark
            // wallpaper. Increased Contrast makes it a clear boundary.
            rim.stroke(
                Color.white.opacity(increaseContrast ? 0.28 : 0.09),
                lineWidth: increaseContrast ? 1.2 : 0.8
            )

            switch style {
            case .voice(let isPaused):
                VoiceRim(live: live, isPaused: isPaused, rim: rim)
            case .sweep:
                SweepRim(rim: rim)
            case .progress(let fraction):
                rim
                    .trim(from: 0, to: max(0.02, min(1, fraction)))
                    .stroke(NookPalette.accentHighlight, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                    .shadow(color: NookPalette.accent.opacity(0.8), radius: 4)
                    .animation(.smooth(duration: 0.6), value: fraction)
            case .success:
                FlashRim(rim: rim, color: NookPalette.accent)
            case .attention:
                rim.stroke(NookPalette.warning.opacity(0.45), lineWidth: 1.2)
            case .invite:
                rim.stroke(NookPalette.accent.opacity(0.35), lineWidth: 1.1)
            case .resting:
                EmptyView()
            }
        }
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .white.opacity(0.35), location: 0.45),
                    .init(color: .white, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var rim: NotchIslandRim {
        NotchIslandRim(bottomRadius: bottomRadius, shoulder: NotchPanelMetrics.shoulder)
    }
}

private struct VoiceRim: View {
    @ObservedObject var live: MeetingLiveSignals
    let isPaused: Bool
    let rim: NotchIslandRim

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var smoother = LevelSmoother()

    var body: some View {
        TimelineView(
            .animation(minimumInterval: 1 / 30, paused: isPaused || reduceMotion)
        ) { context in
            let target = isPaused ? 0 : live.audioLevel
            let level = reduceMotion
                ? 0.25
                : smoother.value(toward: target, at: context.date.timeIntervalSinceReferenceDate)
            rim
                .stroke(
                    LinearGradient(
                        colors: [
                            NookPalette.accent.opacity(0),
                            NookPalette.accentHighlight,
                            NookPalette.accent.opacity(0),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    lineWidth: 1.4
                )
                .opacity(isPaused ? 0.25 : 0.2 + min(1, level * 1.6) * 0.8)
                .shadow(color: NookPalette.accent.opacity(0.7), radius: 4)
        }
    }
}

private struct SweepRim: View {
    let rim: NotchIslandRim
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let position = reduceMotion ? 0.5 : (time.truncatingRemainder(dividingBy: 1.8)) / 1.8
            let band = 0.18
            rim
                .stroke(
                    LinearGradient(
                        stops: [
                            .init(color: NookPalette.accent.opacity(0), location: max(0, position - band)),
                            .init(color: NookPalette.accentHighlight, location: position),
                            .init(color: NookPalette.accent.opacity(0), location: min(1, position + band)),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    lineWidth: 1.5
                )
                .shadow(color: NookPalette.accent.opacity(0.8), radius: 4)
        }
    }
}

private struct FlashRim: View {
    let rim: NotchIslandRim
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var intensity = 1.0

    var body: some View {
        rim
            .stroke(color, lineWidth: 1.5)
            .shadow(color: color.opacity(0.9), radius: 5)
            .opacity(intensity)
            .onAppear {
                guard !reduceMotion else {
                    intensity = 0.5
                    return
                }
                withAnimation(.easeOut(duration: 1.4).delay(0.25)) {
                    intensity = 0.25
                }
            }
    }
}

// MARK: - Marks

/// The consent prompt's mark: a live dot sending out a slow ring, the one
/// thing on the island that asks to be looked at.
private struct IslandInvitation: View {
    var size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .fill(NookPalette.accent.opacity(0.16))
            Circle()
                .stroke(NookPalette.accent, lineWidth: 1.5)
                .phaseAnimator(reduceMotion ? [0.0] : [0.0, 1.0]) { ring, progress in
                    ring
                        .scaleEffect(0.45 + progress * 0.75)
                        .opacity(reduceMotion ? 0 : 0.8 * (1 - progress))
                } animation: { progress in
                    progress == 1 ? .easeOut(duration: 1.6) : .linear(duration: 0.01)
                }
            Circle()
                .fill(NookPalette.accentHighlight)
                .frame(width: size * 0.32, height: size * 0.32)
                .shadow(color: NookPalette.accent, radius: 4)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Writing the notes: three dots that rise in turn, the way a reply is
/// shown being typed.
private struct IslandWritingMark: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    let wave = reduceMotion
                        ? 0
                        : max(0, sin(time * 5.2 - Double(index) * 0.9))
                    Circle()
                        .fill(NookPalette.accentHighlight)
                        .frame(width: 6, height: 6)
                        .opacity(0.45 + wave * 0.55)
                        .offset(y: -wave * 3.5)
                        .shadow(color: NookPalette.accent.opacity(wave * 0.8), radius: 3)
                }
            }
            .frame(width: 30, height: 30)
        }
        .accessibilityHidden(true)
    }
}

private struct IslandFlagMark: View {
    @State private var trigger = false

    var body: some View {
        Image(systemName: "flag.fill")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(NookPalette.accentHighlight)
            .shadow(color: NookPalette.accent.opacity(0.8), radius: 4)
            .symbolEffect(.bounce, value: trigger)
            .onAppear { trigger.toggle() }
            .accessibilityLabel("Moment flagged")
    }
}

/// "In 4 min", "Starting now": updated twice a minute, which is as fine as
/// a meeting start needs.
private struct UpcomingEventTime: View {
    let startDate: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Text(UpcomingEventTiming.label(until: startDate.timeIntervalSince(context.date)))
                .font(.system(size: 11))
                .foregroundStyle(NookPalette.accentHighlight)
                .monospacedDigit()
                .contentTransition(.numericText())
        }
    }

}

enum UpcomingEventTiming {
    static func label(until seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        switch minutes {
        case ..<(-1): return "Started \(-minutes) min ago"
        case -1...0: return "Starting now"
        default: return "Starts in \(minutes) min"
        }
    }
}

/// The meeting app's own icon inside the invitation ring, so the prompt says
/// which call at a glance. Falls back to the plain pulse when the app cannot
/// be found, such as a meeting in a browser tab.
private struct MeetingAppMark: View {
    let appName: String
    let size: CGFloat

    var body: some View {
        if let icon = Self.icon(for: appName) {
            ZStack {
                IslandInvitation(size: size + 10)
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size, height: size)
                    .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
        } else {
            IslandInvitation(size: size)
        }
    }

    private static let knownBundles: [String: [String]] = [
        "teams": ["com.microsoft.teams2", "com.microsoft.teams"],
        "zoom": ["us.zoom.xos"],
        "facetime": ["com.apple.FaceTime"],
        "webex": ["Cisco-Systems.Spark", "com.webex.meetingmanager"],
        "slack": ["com.tinyspeck.slackmacgap"],
        "discord": ["com.hnc.Discord"],
        "around": ["co.teamport.around"],
    ]

    @MainActor
    private static func icon(for appName: String) -> NSImage? {
        let name = appName.lowercased()
        if let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName?.lowercased() == name
        }), let icon = running.icon {
            return icon
        }
        for (key, bundles) in knownBundles where name.contains(key) {
            for bundle in bundles {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
                    return NSWorkspace.shared.icon(forFile: url.path)
                }
            }
        }
        return nil
    }
}

/// Saved: the circle fills and the tick draws itself in.
private struct IslandCheckmark: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDrawn = false

    var body: some View {
        ZStack {
            Circle()
                .fill(NookPalette.accent)
                .scaleEffect(isDrawn ? 1 : 0.5)
                .opacity(isDrawn ? 1 : 0)
                .shadow(color: NookPalette.accent.opacity(0.6), radius: 6)
            CheckmarkShape()
                .trim(from: 0, to: isDrawn ? 1 : 0)
                .stroke(
                    NookPalette.notchInk,
                    style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round)
                )
                .padding(8.5)
        }
        .frame(width: 30, height: 30)
        .onAppear {
            guard !reduceMotion else {
                isDrawn = true
                return
            }
            withAnimation(.spring(response: 0.42, dampingFraction: 0.7).delay(0.14)) {
                isDrawn = true
            }
        }
        .accessibilityHidden(true)
    }
}

private struct CheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY + rect.height * 0.04))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.38, y: rect.maxY - rect.height * 0.12))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.14))
        return path
    }
}

private struct IslandAttentionMark: View {
    @State private var trigger = false

    var body: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(NookPalette.warning)
            .symbolEffect(.bounce, value: trigger)
            .frame(width: 30, height: 30)
            .onAppear { trigger.toggle() }
            .accessibilityHidden(true)
    }
}

// MARK: - Controls

/// Round controls on the island, the size of the app's hit-target floor.
private struct IslandControlButtonStyle: ButtonStyle {
    var tint: Color?
    var sideLength: CGFloat = 30

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let feedback = PanelPressFeedback(
            surface: .icon, isPressed: configuration.isPressed, reduceMotion: reduceMotion
        )
        return configuration.label
            .font(.system(size: sideLength * 0.37, weight: .bold))
            .labelStyle(.iconOnly)
            .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(Color.white.opacity(0.92)))
            .frame(width: sideLength, height: sideLength)
            .background(.white.opacity(feedback.backgroundOpacity * 2), in: Circle())
            .contentShape(Circle())
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(feedback.scale)
            .nookFocusRing(Circle(), isVisible: isFocused)
            .animation(feedback.animation, value: configuration.isPressed)
    }
}

/// The one filled control on the island: the answer it is asking for.
private struct IslandCapsuleButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let feedback = PanelPressFeedback(
            surface: .text, isPressed: configuration.isPressed, reduceMotion: reduceMotion
        )
        return configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .labelStyle(.titleAndIcon)
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(NookPalette.notchInk)
            .padding(.horizontal, 13)
            .frame(minHeight: 30)
            .background(
                NookPalette.accent.opacity(configuration.isPressed ? 0.86 : 1),
                in: Capsule()
            )
            .shadow(color: NookPalette.accent.opacity(0.35), radius: 8, y: 2)
            .contentShape(Capsule())
            .scaleEffect(feedback.scale)
            .nookFocusRing(Capsule(), isVisible: isFocused)
            .animation(feedback.animation, value: configuration.isPressed)
    }
}

/// The Record capsule's label. The glyph is drawn, not an SF Symbol: the
/// symbol ignored every foreground style here and rendered white on mint,
/// under 2:1, while shapes in the same ink render as asked.
private struct IslandCapsuleLabel: View {
    let title: String

    var body: some View {
        HStack(spacing: 6) {
            RecordGlyph()
                .frame(width: 13, height: 13)
            Text(title)
        }
        .foregroundStyle(NookPalette.notchInk)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }
}

/// A ring around a dot: the record mark, in the current foreground style.
struct RecordGlyph: View {
    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                Circle()
                    .strokeBorder(.foreground, lineWidth: max(1.2, side * 0.12))
                Circle()
                    .fill(.foreground)
                    .frame(width: side * 0.42, height: side * 0.42)
            }
            .frame(width: side, height: side)
        }
        .accessibilityHidden(true)
    }
}

private struct IslandControl: View {
    let symbol: String
    let label: String
    var tint: Color?
    var bounceTrigger = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: bounceTrigger)
        }
        .buttonStyle(IslandControlButtonStyle(tint: tint))
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Transcript, summary and notes, with the selection sliding between them.
private struct IslandModePicker: View {
    let selection: MeetingPanelMode
    let notesDetached: Bool
    let select: (MeetingPanelMode) -> Void

    @Namespace private var picker
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Every mode, always. Notes used to disappear from the notch while
    /// they were in their own window, which left no way to take one here.
    private var availableModes: [MeetingPanelMode] {
        MeetingPanelMode.allCases
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(availableModes) { mode in
                Button {
                    select(mode)
                } label: {
                    Text(mode.label)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(
                            selection == mode
                                ? AnyShapeStyle(.primary)
                                : AnyShapeStyle(.secondary)
                        )
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity)
                        .frame(height: 24)
                        .background {
                            if selection == mode {
                                Capsule()
                                    .fill(.white.opacity(0.12))
                                    .matchedGeometryEffect(id: "selection", in: picker)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(mode.label)
                .accessibilityLabel("Show \(mode.label)")
                .accessibilityAddTraits(
                    selection == mode ? .isSelected : []
                )
            }
        }
        .padding(3)
        .background(.white.opacity(0.05), in: Capsule())
        .animation(
            reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.82),
            value: selection
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Meeting workspace")
    }
}

/// Which consent action holds keyboard focus.
private enum DetectedAction: Hashable {
    case record
    case dismiss
}

/// Text buttons on the edge-dark panel shell.
///
/// One style instead of the three that grew separately: same press feedback,
/// same minimum height, and a visible focus ring, which custom styles never
/// got from SwiftUI on their own.
private struct PanelTextButtonStyle: ButtonStyle {
    var tint: Color?
    var isPrimary = false

    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let feedback = PanelPressFeedback(
            surface: .text, isPressed: configuration.isPressed, reduceMotion: reduceMotion
        )
        return configuration.label
            .font(NookType.metadata)
            .labelStyle(.titleAndIcon)
            .foregroundStyle(foreground)
            .padding(.horizontal, 8)
            .frame(minHeight: 30)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.white.opacity(feedback.backgroundOpacity))
            }
            .contentShape(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .scaleEffect(feedback.scale)
            .nookFocusRing(
                RoundedRectangle(cornerRadius: 9, style: .continuous),
                isVisible: isFocused
            )
            .animation(
                feedback.animation,
                value: configuration.isPressed
            )
    }

    private var foreground: AnyShapeStyle {
        if isPrimary { return AnyShapeStyle(NookPalette.accentHighlight) }
        if let tint { return AnyShapeStyle(tint) }
        return AnyShapeStyle(Color.white.opacity(0.92))
    }
}

/// Icon-only controls on the edge-dark panel shell.
private struct PanelIconButtonStyle: ButtonStyle {
    var tint: Color?
    var isDestructive = false
    /// 30 by default so every panel control meets the app's own hit-target
    /// floor. Transport inside the expanded chrome passes 28 because that
    /// row is exactly the menu-bar inset tall.
    var sideLength: CGFloat = 30

    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let feedback = PanelPressFeedback(
            surface: .icon, isPressed: configuration.isPressed, reduceMotion: reduceMotion
        )
        return configuration.label
            .font(.system(size: 11, weight: .semibold))
            .labelStyle(.iconOnly)
            .foregroundStyle(foreground)
            .frame(width: sideLength, height: sideLength)
            .background(
                .white.opacity(feedback.backgroundOpacity),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .contentShape(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .scaleEffect(feedback.scale)
            .nookFocusRing(
                RoundedRectangle(cornerRadius: 9, style: .continuous),
                isVisible: isFocused
            )
            .animation(
                feedback.animation,
                value: configuration.isPressed
            )
    }

    private var foreground: AnyShapeStyle {
        if isDestructive { return AnyShapeStyle(NookPalette.danger) }
        if let tint { return AnyShapeStyle(tint) }
        return AnyShapeStyle(Color.white.opacity(0.92))
    }
}

private struct HiddenRecordingIndicatorStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let feedback = PanelPressFeedback(
            surface: .hiddenIndicator, isPressed: configuration.isPressed, reduceMotion: reduceMotion
        )
        return configuration.label
            .opacity(feedback.contentOpacity)
            .scaleEffect(feedback.scale)
            // The one control on a hidden panel, and the only way back to the
            // recording without a pointer. It gets the same focus ring the
            // other panel styles do; without it a keyboard user could reach it
            // and not know they had.
            .nookFocusRing(
                RoundedRectangle(cornerRadius: 9, style: .continuous),
                isVisible: isFocused
            )
            .animation(
                feedback.animation,
                value: configuration.isPressed
            )
    }
}

/// Reduce Motion removes the transform, not the acknowledgment of a press.
/// Keeping those decisions together preserves each panel control's existing
/// feedback while making both preferences use the same nonmoving colors.
struct PanelPressFeedback {
    enum Surface: CaseIterable, Sendable {
        case text, icon, hiddenIndicator
    }

    let scale: CGFloat
    let backgroundOpacity: Double
    let contentOpacity: Double
    let animation: Animation?

    init(surface: Surface, isPressed: Bool, reduceMotion: Bool) {
        let pressedScale: CGFloat
        switch surface {
        case .text:
            pressedScale = 0.98
            backgroundOpacity = isPressed ? 0.10 : 0.001
        case .icon:
            pressedScale = 0.96
            backgroundOpacity = isPressed ? 0.12 : 0.045
        case .hiddenIndicator:
            pressedScale = 0.985
            backgroundOpacity = 0
        }
        scale = isPressed && !reduceMotion ? pressedScale : 1
        contentOpacity = surface == .hiddenIndicator && isPressed ? 0.82 : 1
        animation = reduceMotion ? nil : NookMotion.settle(over: 0.12)
    }
}

/// The elapsed clock shared by the expanded chrome, the compact bar and the
/// hidden indicator. Observes `MeetingLiveSignals` so that object's meter,
/// caption and clock publishes re-render this text alone rather than the
/// panel shell; the spoken label is attached here for the same
/// reason, since it reads the clock too.
private struct NotchRecordingClock: View {
    @ObservedObject var live: MeetingLiveSignals
    var isPaused = false
    var isSmall = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text(NookElapsedTime.clock(live.elapsed))
            .font(.system(size: isSmall ? 11 : 12.5, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(isPaused ? NookPalette.warning : Color.white.opacity(0.92))
            .contentTransition(.numericText())
            .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: Int(live.elapsed))
            // A paused clock breathes, so it reads as held rather than stuck.
            .phaseAnimator(isPaused && !reduceMotion ? [1.0, 0.45] : [1.0]) { clock, opacity in
                clock.opacity(opacity)
            } animation: { _ in
                .easeInOut(duration: 0.9)
            }
            .accessibilityLabel(
                (isPaused ? "Paused, " : "") + NookElapsedTime.spoken(live.elapsed)
            )
    }
}

/// Attaches a spoken label that includes the elapsed time to `content`.
///
/// The panel's buttons and its compact container describe themselves as
/// "Recording <title>, 4 minutes 12 seconds" and similar. Assembling that
/// string in `NotchPanelView` would drag its whole body back into observing
/// the clock, so the string is built here from `describe(spokenElapsed)`
/// with the slow parts (title, pause state) captured by the caller.
private struct RecordingSpokenLabel<Content: View>: View {
    @ObservedObject var live: MeetingLiveSignals
    let describe: (String) -> String
    let content: Content

    init(
        live: MeetingLiveSignals,
        describe: @escaping (String) -> String,
        @ViewBuilder content: () -> Content
    ) {
        self.live = live
        self.describe = describe
        self.content = content()
    }

    var body: some View {
        content
            .accessibilityLabel(describe(NookElapsedTime.spoken(live.elapsed)))
    }
}

private struct LiveSummaryPanel: View {
    let insights: MeetingInsights?
    let isRefreshing: Bool
    let updatedAt: Date?
    /// Held, not observed: only `LiveSummaryWaitingText` reads the word
    /// count, so the transcript's ~10 Hz updates stop at that leaf.
    let live: MeetingLiveSignals
    let refresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // The tab already says Summary. One quiet line says how fresh it
            // is and offers to refresh; no glyph restates the title.
            HStack(spacing: 8) {
                Text(updatedLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)

                Spacer()

                Button(action: refresh) {
                    Image(systemName: "arrow.clockwise")
                        .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                        .animation(
                            isRefreshing
                                ? .linear(duration: 1).repeatForever(autoreverses: false)
                                : .default,
                            value: isRefreshing
                        )
                }
                .buttonStyle(IslandControlButtonStyle(sideLength: 24))
                .disabled(isRefreshing)
                .help("Update summary")
                .accessibilityLabel(isRefreshing ? "Updating summary" : "Update meeting summary")
            }

            if let insights {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(insights.summary)
                            .font(.system(size: 13, weight: .semibold))
                            .lineSpacing(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)

                        ForEach(
                            Array(insights.keyPoints.prefix(3).enumerated()),
                            id: \.offset
                        ) { _, point in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Circle()
                                    .fill(NookPalette.accent)
                                    .frame(width: 4, height: 4)
                                Text(point)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .transition(.opacity)
            } else {
                HStack(spacing: 10) {
                    IslandWritingMark()
                    LiveSummaryWaitingText(live: live)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 126, maxHeight: 138)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Meeting summary")
    }

    private var updatedLabel: String {
        guard let updatedAt else {
            return insights == nil
                ? "Written on this Mac once enough has been said"
                : "Written on this Mac"
        }
        return "Updated \(updatedAt.formatted(.relative(presentation: .named))) · on this Mac"
    }
}

/// What the summary tab says before there is a summary. Reads the transcript
/// word count from `MeetingLiveSignals` so the panel around it does not.
private struct LiveSummaryWaitingText: View {
    @ObservedObject var live: MeetingLiveSignals

    var body: some View {
        Text(
            live.liveTranscript.wordCount == 0
                ? "A faithful summary will appear as the conversation develops."
                : "Finding the shape of the conversation…"
        )
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.secondary)
    }
}

private struct LiveNotesPanel: View {
    @Binding var notes: String
    let focusToken: Int
    let detach: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text("Added to the note when the meeting ends")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: detach) {
                    Image(systemName: "macwindow.on.rectangle")
                }
                .buttonStyle(IslandControlButtonStyle(sideLength: 24))
                .help("Open notes in a floating window")
                .accessibilityLabel("Open notes in a floating window")
            }

            NookNotesEditor(
                text: $notes,
                placeholder: "Type a thought, a question, or something to remember…",
                focusToken: focusToken,
                contentInsets: EdgeInsets(
                    top: 9,
                    leading: 11,
                    bottom: 9,
                    trailing: 11
                ),
                lineSpacing: 3,
                accessibilityLabel: "My meeting notes"
            )
            .frame(minHeight: 120)
            .background(
                .white.opacity(0.06),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
        }
        .frame(maxWidth: .infinity)
    }
}

/// My notes while it is in its own window. The tab stays, so taking a note
/// is always one click from the notch: bring the window forward, or put the
/// notes back here.
private struct DetachedNotesPanel: View {
    let bringForward: () -> Void
    let bringBack: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 3) {
                Text("My notes is in its own window")
                    .font(.system(size: 13, weight: .semibold))
                Text("Keep writing there, or bring the notes back into the notch.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Button("Show Window", action: bringForward)
                    .buttonStyle(PanelTextButtonStyle())
                Button("Bring Back Here", action: bringBack)
                    .buttonStyle(IslandCapsuleButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, minHeight: 126)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("My notes is open in a floating window")
    }
}

private struct NotchCaptionStream: View {
    @ObservedObject var live: MeetingLiveSignals
    /// A caption-specific notice from the coordinator (for example that
    /// captions are unavailable); shown in place of the listening hint.
    let notice: String?
    /// Flagged moments, as recording offsets, so a line said at a flagged
    /// moment carries the flag.
    var moments: [TimeInterval] = []

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var lines: [LiveCaptionLine] {
        live.liveTranscript.notchCaptionLines
    }

    private var revision: Int {
        live.liveTranscript.revision
    }

    /// Decided here rather than in the panel because the hint follows the
    /// meter: "Finding the words" once someone is audibly speaking, so the
    /// audio level has to be read by a view that observes it.
    private var fallback: String {
        if let notice { return notice }
        return live.audioLevel > 0.08
            ? "Finding the words…"
            : "Listening for the first words…"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if lines.isEmpty {
                HStack(spacing: 10) {
                    IslandWritingMark()
                    Text(fallback)
                        .font(NookType.transcriptEmphasized)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 100, alignment: .leading)
                .transition(.opacity)
                .accessibilityElement(children: .combine)
            } else {
                ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                    NotchCaptionRow(
                        line: line,
                        isNewest: index == lines.count - 1,
                        prominence: prominence(for: index),
                        isFlagged: isFlagged(line)
                    )
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .asymmetric(
                                insertion: .opacity
                                    .combined(with: .offset(y: 8)),
                                removal: .opacity
                                    .combined(with: .offset(y: -6))
                            )
                    )
                }
            }
        }
        .frame(
            maxWidth: .infinity,
            minHeight: 104,
            maxHeight: 124,
            alignment: .bottom
        )
        .padding(.bottom, 4)
        .clipped()
        .animation(
            reduceMotion ? nil : NookMotion.settle(over: 0.26),
            value: lines.map(\.id)
        )
        .animation(
            reduceMotion ? nil : NookMotion.settle(over: 0.16),
            value: revision
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Live transcript")
    }

    /// A finished line is flagged when a flag fell while it was said; the
    /// line still being heard, when a flag fell after the last finished one.
    private func isFlagged(_ line: LiveCaptionLine) -> Bool {
        LiveCaptionFlags.isFlagged(
            line.id,
            segments: live.liveTranscript.segments,
            moments: moments
        )
    }

    private func prominence(for index: Int) -> Double {
        guard lines.count > 1 else { return 1 }
        let distanceFromNewest = lines.count - 1 - index
        switch distanceFromNewest {
        case 0: return 1
        case 1: return 0.80
        case 2: return 0.62
        default: return 0.46
        }
    }
}

private struct NotchCaptionRow: View {
    let line: LiveCaptionLine
    let isNewest: Bool
    let prominence: Double
    var isFlagged = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: line.source.symbol)
                .font(.system(size: isNewest ? 8 : 7, weight: .semibold))
                .foregroundStyle(line.source.nookTint)
                .frame(width: 10)
                .opacity(isNewest ? 1 : 0.72)
                .accessibilityHidden(true)

            Text(line.text)
                .font(
                    isNewest
                        ? NookType.transcriptEmphasized
                        : NookType.transcript
                )
                .foregroundStyle(.primary)
                .lineLimit(line.isPartial ? 2 : 1)
                .truncationMode(line.isPartial ? .head : .tail)
                .multilineTextAlignment(.leading)
                .contentTransition(.interpolate)

            if line.isPartial {
                ListeningCaret(tint: line.source.nookTint)
            }

            if isFlagged {
                IslandFlagMark()
                    .scaleEffect(0.8)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(prominence)
        .scaleEffect(
            reduceMotion ? 1 : 0.985 + (0.015 * prominence),
            anchor: .center
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(line.source.label): \(line.text)")
        .accessibilityValue(
            (line.isPartial ? "Being transcribed" : "Final")
                + (isFlagged ? ", flagged" : "")
        )
    }
}

private struct ListeningCaret: View {
    let tint: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = true

    var body: some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(tint)
            .frame(width: 3, height: 13)
            .opacity(isVisible ? 1 : 0.30)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(
                    .easeInOut(duration: 0.62)
                        .repeatForever(autoreverses: true)
                ) {
                    isVisible = false
                }
            }
            .accessibilityHidden(true)
    }
}
