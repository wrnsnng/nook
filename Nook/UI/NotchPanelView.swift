import AppKit
import SwiftUI

struct NotchPanelView: View {
    @EnvironmentObject private var meeting: MeetingCoordinator
    @EnvironmentObject private var geometry: NotchPanelGeometry
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false
    @FocusState private var notesEditorFocused: Bool
    private let rendersForSnapshot: Bool

    init(rendersForSnapshot: Bool = false) {
        self.rendersForSnapshot = rendersForSnapshot
    }

    private var bodySize: CGSize {
        let preferred = NotchPanelMetrics.bodySize(
            for: meeting.phase,
            showsCaptions: meeting.showLiveCaptions,
            panelMode: meeting.panelMode,
            isHidden: meeting.topPanelHidden
        )
        return CGSize(
            width: min(preferred.width, geometry.maximumPanelWidth),
            height: preferred.height
        )
    }

    private var totalHeight: CGFloat {
        bodySize.height + geometry.topInset
    }

    private var increaseContrast: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    private var isUltraCompact: Bool {
        meeting.phase.isRecording
            && !meeting.showLiveCaptions
            && !meeting.topPanelHidden
    }

    private var isExpandedRecording: Bool {
        meeting.phase.isRecording
            && meeting.showLiveCaptions
            && !meeting.topPanelHidden
    }

    private var isHiddenRecording: Bool {
        meeting.phase.isRecording && meeting.topPanelHidden
    }

    private var isDetected: Bool {
        if case .detected = meeting.phase { true } else { false }
    }

    private var shellBottomRadius: CGFloat {
        if isUltraCompact { return 17 }
        if isDetected { return 20 }
        return meeting.phase.isRecording && meeting.showLiveCaptions ? 32 : 26
    }

    private var shellShape: TopAnchoredPanelShape {
        TopAnchoredPanelShape(
            bottomRadius: shellBottomRadius,
            revealProgress: geometry.revealProgress
        )
    }

    private var shellOutlineShape: TopAnchoredPanelOutline {
        TopAnchoredPanelOutline(
            topInset: geometry.topInset,
            bottomRadius: shellBottomRadius,
            revealProgress: geometry.revealProgress
        )
    }

    var body: some View {
        Group {
            if isHiddenRecording {
                hiddenRecordingIndicator
            } else {
                standardPanel
            }
        }
        .frame(
            width: bodySize.width,
            height: totalHeight,
            alignment: .top
        )
        .animation(
            shellAnimation,
            value: meeting.phase
        )
        .animation(
            shellAnimation,
            value: meeting.showLiveCaptions
        )
        .animation(
            shellAnimation,
            value: meeting.panelMode
        )
        .animation(
            shellAnimation,
            value: meeting.topPanelHidden
        )
        // The physical camera housing is the material. Keeping this surface
        // edge-black in both app appearances makes it read as part of the
        // display bezel instead of another themed window.
        .environment(\.colorScheme, .dark)
        .tint(NookPalette.accentHighlight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            isHiddenRecording
                ? "Nook recording indicator"
                : "Nook meeting panel"
        )
        .accessibilityIdentifier("nook.notchPanel")
    }

    private var standardPanel: some View {
        shellContent
            .background(edgeShellGradient, in: shellShape)
            .overlay {
                shellOutlineShape
                    .stroke(
                        Color.white.opacity(increaseContrast ? 0.24 : 0.075),
                        lineWidth: increaseContrast ? 1.1 : 0.55
                    )
            }
            .overlay {
                shellHighlight
            }
            .shadow(
                color: .black.opacity(isHovering ? 0.34 : 0.24),
                radius: isHovering ? 18 : 12,
                y: isHovering ? 8 : 5
            )
            .contentShape(shellShape)
            .onHover(perform: updateHoverState)
    }

    private var hiddenRecordingIndicator: some View {
        hiddenRestoreButton(
            attachedToCamera: geometry.cameraHousingWidth > 1
        )
        .frame(
            width: bodySize.width,
            height: totalHeight,
            alignment: .top
        )
    }

    private func hiddenRestoreButton(attachedToCamera: Bool) -> some View {
        Button {
            meeting.restoreTopPanel()
        } label: {
            HStack(spacing: 6) {
                Text(elapsedLabel)
                    .font(NookType.code)
                    .monospacedDigit()
                    .contentTransition(.numericText())

                Circle()
                    .fill(
                        meeting.isPaused
                            ? NookPalette.warning
                            : NookPalette.danger
                    )
                    .frame(width: 6, height: 6)
                    .shadow(
                        color: (
                            meeting.isPaused
                                ? NookPalette.warning
                                : NookPalette.danger
                        ).opacity(0.45),
                        radius: 3
                    )
            }
            .foregroundStyle(.white.opacity(isHovering ? 1 : 0.86))
            .frame(width: 86, height: geometry.topInset)
            .background {
                UnevenRoundedRectangle(
                    topLeadingRadius: attachedToCamera ? 0 : 8,
                    bottomLeadingRadius: attachedToCamera ? 0 : 8,
                    bottomTrailingRadius: 8,
                    topTrailingRadius: attachedToCamera ? 0 : 8,
                    style: .continuous
                )
                .fill(Color.black.opacity(isHovering ? 1 : 0.97))
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(.white.opacity(isHovering ? 0.10 : 0.045))
                        .frame(height: 0.5)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(HiddenRecordingIndicatorStyle())
        .help("Show meeting panel")
        .accessibilityLabel(
            "\(meeting.isPaused ? "Recording paused" : "Recording"), \(elapsedSpokenLabel). Show meeting panel"
        )
        .accessibilityHint("Restores the compact recording controls")
        .onHover(perform: updateHoverState)
    }

    private func updateHoverState(_ hovering: Bool) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
            isHovering = hovering
        }
    }

    private var edgeShellGradient: LinearGradient {
        return LinearGradient(
            colors: [
                Color(red: 0.002, green: 0.003, blue: 0.004),
                Color(red: 0.012, green: 0.014, blue: 0.018),
                Color(red: 0.020, green: 0.023, blue: 0.029),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    @ViewBuilder
    private var shellContent: some View {
        if isExpandedRecording {
            revealedPhaseContent
                .frame(
                    width: bodySize.width,
                    height: totalHeight,
                    alignment: .top
                )
                .clipShape(shellShape)
        } else {
            revealedPhaseContent
            .padding(
                .horizontal,
                isUltraCompact
                    ? 12
                    : (isDetected
                        ? 13
                        : (meeting.showLiveCaptions ? 22 : 18))
            )
            .padding(
                .top,
                geometry.topInset
                    + (isUltraCompact
                        ? 5
                        : (isDetected
                            ? 5
                            : (meeting.showLiveCaptions ? 9 : 9)))
            )
            .padding(
                .bottom,
                isUltraCompact
                    ? 5
                    : (isDetected
                        ? 7
                        : (meeting.showLiveCaptions ? 14 : 11))
            )
            .frame(width: bodySize.width, height: totalHeight, alignment: .top)
            .clipShape(shellShape)
        }
    }

    private var revealedPhaseContent: some View {
        phaseContent
            .opacity(contentRevealProgress)
            .offset(y: reduceMotion ? 0 : (1 - contentRevealProgress) * -5)
    }

    private var shellHighlight: some View {
        shellOutlineShape
            .stroke(
                LinearGradient(
                    colors: [
                        .clear,
                        .white.opacity(isHovering ? 0.11 : 0.065),
                        .clear,
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                lineWidth: 0.55
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var shellAnimation: Animation? {
        reduceMotion
            ? nil
            : .timingCurve(0.16, 1, 0.30, 1, duration: 0.32)
    }

    private var contentRevealProgress: CGFloat {
        guard !reduceMotion else { return 1 }
        return min(1, max(0, (geometry.revealProgress - 0.26) / 0.74))
    }

    @ViewBuilder
    private var phaseContent: some View {
        ZStack {
            switch meeting.phase {
            case .idle:
                idleContent
            case .detected(let detection):
                detectedContent(detection)
            case .recording(let title, _):
                recordingContent(title: title)
            case .processing(let step):
                processingContent(step)
            case .completed(let title):
                completedContent(title)
            case .failed(let message):
                failedContent(message)
            }
        }
        .id(phaseIdentity)
        .transition(
            reduceMotion
                ? .identity
                : .opacity.combined(with: .scale(scale: 0.985, anchor: .top))
        )
    }

    private var idleContent: some View {
        HStack(spacing: 10) {
            NookPresence(
                state: .resting,
                size: 23,
                showsSurface: false
            )
            VStack(alignment: .leading, spacing: 2) {
                Text("Nook is listening")
                    .font(NookType.bodyEmphasized)
                Text("Ready when a conversation begins")
                    .font(NookType.micro)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                meeting.startManualMeeting()
            } label: {
                Image(systemName: "waveform.badge.mic")
            }
            .buttonStyle(
                EdgeSymbolButtonStyle(
                    tint: NookPalette.accentHighlight
                )
            )
            .help("Start recording")
            .accessibilityLabel("Start recording")
        }
    }

    private func detectedContent(_ detection: DetectedMeeting) -> some View {
        HStack(spacing: 8) {
            NookPresence(
                state: .detected,
                size: 21,
                showsSurface: false
            )

            VStack(alignment: .leading, spacing: 1) {
                Text(detection.suggestedTitle)
                    .font(NookType.metadata)
                    .lineLimit(1)
                Text(detection.appName)
                    .font(NookType.micro)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            HStack(spacing: 3) {
                Button {
                    meeting.dismissPrompt()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(EdgeSymbolButtonStyle())
                .keyboardShortcut(.cancelAction)
                .help("Not now")
                .accessibilityLabel("Not now")
                .accessibilityHint("Leaves this meeting unrecorded")

                Button {
                    meeting.startDetectedMeeting()
                } label: {
                    Label("Record", systemImage: "waveform")
                }
                .buttonStyle(DetectedPromptButtonStyle(isPrimary: true))
                .keyboardShortcut(.defaultAction)
                .accessibilityHint("Starts recording locally")
            }
        }
    }

    @ViewBuilder
    private func recordingContent(title: String) -> some View {
        if meeting.showLiveCaptions {
            expandedRecordingContent(title: title)
        } else {
            compactRecordingContent(title: title)
        }
    }

    private func expandedRecordingContent(title: String) -> some View {
        VStack(spacing: 0) {
            expandedRecordingChrome(title: title)
                .frame(height: geometry.topInset)
                .padding(.horizontal, 18)

            VStack(spacing: 7) {
                MeetingPanelModeBar(
                    selection: meeting.panelMode,
                    notesDetached: meeting.liveNotesDetached
                ) { mode in
                    meeting.selectPanelMode(mode)
                    if mode == .notes {
                        Task { @MainActor in
                            await Task.yield()
                            notesEditorFocused = true
                        }
                    }
                }

                Group {
                    switch meeting.panelMode {
                    case .transcript:
                        transcriptWorkspace
                    case .summary:
                        LiveSummaryPanel(
                            insights: meeting.liveInsights,
                            isRefreshing: meeting.liveSummaryIsRefreshing,
                            updatedAt: meeting.liveSummaryUpdatedAt,
                            wordCount: meeting.liveTranscript.wordCount,
                            refresh: meeting.refreshLiveSummary
                        )
                    case .notes:
                        if meeting.liveNotesDetached {
                            DetachedNotesPanel {
                                guard !rendersForSnapshot else { return }
                                AppModel.shared.openLiveNotes()
                            }
                        } else {
                            LiveNotesPanel(
                                notes: $meeting.liveNotes,
                                isFocused: $notesEditorFocused,
                                detach: {
                                    guard !rendersForSnapshot else { return }
                                    notesEditorFocused = false
                                    AppModel.shared.openLiveNotes()
                                }
                            )
                        }
                    }
                }
                .transition(
                    reduceMotion
                        ? .opacity
                        : .opacity.combined(with: .offset(y: 4))
                )
            }
            .padding(.horizontal, 22)
            .padding(.top, 7)
            .padding(.bottom, 12)
            .frame(height: bodySize.height, alignment: .top)
        }
    }

    private func expandedRecordingChrome(title: String) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                LiveStatusIndicator(
                    isPaused: meeting.isPaused,
                    level: meeting.audioLevel
                )

                Text(title)
                    .font(NookType.metadata)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Color.clear
                .frame(width: geometry.cameraHousingWidth)
                .accessibilityHidden(true)

            HStack(spacing: 4) {
                Text(elapsedLabel)
                    .font(NookType.code)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .accessibilityLabel(elapsedSpokenLabel)

                recordingControls

                Button {
                    meeting.collapseTopPanel()
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(PanelTransportButtonStyle())
                .help("Collapse top panel")
                .accessibilityLabel("Collapse top panel")
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func compactRecordingContent(title: String) -> some View {
        HStack(spacing: 8) {
            Button {
                meeting.expandTopPanel()
            } label: {
                HStack(spacing: 8) {
                    RecordingWaveform(
                        level: meeting.isPaused ? 0 : meeting.audioLevel,
                        isActive: !meeting.isPaused,
                        barCount: 18,
                        minimumHeight: 1.5
                    )
                    .frame(width: 78, height: 13)
                    .opacity(meeting.isPaused ? 0.34 : 0.88)

                    Text(meeting.isPaused ? "PAUSED" : elapsedLabel)
                        .font(NookType.code)
                        .foregroundStyle(
                            meeting.isPaused
                                ? NookPalette.warning
                                : .secondary
                        )
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .frame(minWidth: 42, alignment: .leading)

                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Expand meeting workspace")
            .accessibilityLabel(
                "Expand \(title), \(elapsedSpokenLabel)"
            )

            Spacer(minLength: 0)

            HStack(spacing: 2) {
                CompactMeetingControl(
                    symbol: "chevron.up",
                    label: "Hide top panel",
                    action: meeting.hideTopPanel
                )

                CompactMeetingControl(
                    symbol: meeting.isPaused ? "play.fill" : "pause.fill",
                    label: meeting.isPaused
                        ? "Resume recording"
                        : "Pause recording",
                    tint: meeting.isPaused ? NookPalette.success : nil,
                    action: meeting.togglePause
                )
                .disabled(meeting.pauseTransitionInFlight)

                CompactMeetingControl(
                    symbol: "stop.fill",
                    label: "Finish meeting",
                    tint: NookPalette.danger,
                    action: meeting.stopRecording
                )
                .disabled(meeting.pauseTransitionInFlight)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "\(meeting.isPaused ? "Paused" : "Recording") \(title), \(elapsedSpokenLabel)"
        )
    }

    private var transcriptWorkspace: some View {
        VStack(spacing: 5) {
            AudioThread(
                level: meeting.isPaused ? 0 : meeting.audioLevel,
                isActive: !meeting.isPaused
            )
                .frame(height: 12)

            NotchCaptionStream(
                lines: meeting.liveTranscript.notchCaptionLines,
                fallback: liveCaptionFallback,
                revision: meeting.liveTranscript.revision
            )
        }
    }

    @ViewBuilder
    private var recordingControls: some View {
        if rendersForSnapshot {
            Image(systemName: "pause.fill")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(
                    .white.opacity(0.045),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )

            Image(systemName: "stop.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(NookPalette.danger)
                .frame(width: 28, height: 28)
                .background(
                    .white.opacity(0.045),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
        } else {
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
            .buttonStyle(
                PanelTransportButtonStyle(
                    tint: meeting.isPaused ? NookPalette.success : nil
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
                Label("Finish", systemImage: "stop.fill")
            }
            .buttonStyle(
                PanelTransportButtonStyle(
                    tint: NookPalette.danger,
                    isDestructive: true
                )
            )
            .disabled(meeting.pauseTransitionInFlight)
            .help("Stop and create notes")
            .accessibilityLabel("Stop recording and create notes")
        }
    }

    private func processingContent(_ step: MeetingPhase.ProcessingStep) -> some View {
        HStack(spacing: 12) {
            NookPresence(state: .thinking, size: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text("Tucking this conversation away")
                    .font(NookType.bodyEmphasized)
                Text(processingDetail(for: step))
                    .font(NookType.micro)
                    .foregroundStyle(.secondary)
            }

            Spacer()
            if step != .discarding, meeting.canCancelProcessing {
                Button("Cancel") {
                    meeting.cancelProcessing()
                }
                .buttonStyle(PanelActionButtonStyle())
                .help("Cancel processing and discard this recording")
                .accessibilityHint("Permanently discards this recording")
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private func completedContent(_ title: String) -> some View {
        HStack(spacing: 12) {
            NookPresence(state: .saved, size: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text("Tucked away")
                    .font(NookType.bodyEmphasized)
                Text("\(title) · Saved as Markdown")
                    .font(NookType.micro)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button("Open notes") {
                openLibrary()
                meeting.resetStatus()
            }
            .buttonStyle(PanelActionButtonStyle(tint: NookPalette.accent))
            .keyboardShortcut(.defaultAction)
        }
    }

    private func failedContent(_ message: String) -> some View {
        HStack(spacing: 12) {
            NookPresence(state: .attention, size: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text("Nook needs a hand")
                    .font(NookType.bodyEmphasized)
                Text(panelFailureMessage(message))
                    .font(NookType.micro)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            Spacer(minLength: 8)

            if let permission = meeting.requiredPermission {
                Button(permission.primaryActionTitle) {
                    meeting.performPermissionPrimaryAction()
                }
                .buttonStyle(PanelActionButtonStyle())

                Button("Open Settings") {
                    meeting.revealPermissions()
                }
                .buttonStyle(
                    PanelActionButtonStyle(tint: NookPalette.accent)
                )
            } else {
                Button("Dismiss") {
                    meeting.resetStatus()
                }
                .buttonStyle(PanelActionButtonStyle())
            }
        }
    }

    private var liveCaptionFallback: String {
        if let notice = meeting.liveCaptionNotice { return notice }
        return meeting.audioLevel > 0.08
            ? "Finding the words…"
            : "Listening for the first words…"
    }

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

    private var elapsedLabel: String {
        let total = Int(meeting.elapsed)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private var elapsedSpokenLabel: String {
        let total = Int(meeting.elapsed)
        let minutes = total / 60
        let seconds = total % 60
        return "\(minutes) minutes, \(seconds) seconds"
    }

    private var phaseIdentity: String {
        switch meeting.phase {
        case .idle: "idle"
        case .detected: "detected"
        case .recording: "recording"
        case .processing: "processing"
        case .completed: "completed"
        case .failed: "failed"
        }
    }

    private func processingSymbol(for step: MeetingPhase.ProcessingStep) -> String {
        switch step {
        case .preparing: "waveform"
        case .refining: "text.badge.checkmark"
        case .transcribing: "ear"
        case .summarizing: "sparkles"
        case .saving: "doc.badge.plus"
        case .discarding: "trash"
        }
    }

    private func processingDetail(for step: MeetingPhase.ProcessingStep) -> String {
        switch step {
        case .preparing: "Securing the audio on this Mac"
        case .refining: "Turning live captions into a clean record"
        case .transcribing: "A careful second listen, entirely on-device"
        case .summarizing: "Finding decisions, themes, and next steps"
        case .saving: "Writing a plain Markdown file"
        case .discarding: "Removing the accidental recording"
        }
    }

    private func openLibrary() {
        AppModel.shared.openLibrary()
    }
}

private struct PanelActionButtonStyle: ButtonStyle {
    var tint: Color?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(NookType.metadata)
            .foregroundStyle(
                tint.map { AnyShapeStyle($0) }
                    ?? AnyShapeStyle(.primary)
            )
            .padding(.horizontal, 8)
            .frame(minHeight: 30)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(
                        .white.opacity(
                            configuration.isPressed ? 0.10 : 0.001
                        )
                    )
            }
            .contentShape(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(
                .timingCurve(0.22, 1, 0.36, 1, duration: 0.12),
                value: configuration.isPressed
            )
    }
}

private struct DetectedPromptButtonStyle: ButtonStyle {
    var isPrimary = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(NookType.metadata)
            .labelStyle(.titleAndIcon)
            .foregroundStyle(
                isPrimary
                    ? AnyShapeStyle(NookPalette.accentHighlight)
                    : AnyShapeStyle(.secondary)
            )
            .padding(.horizontal, 7)
            .frame(minHeight: 28)
            .background(
                .white.opacity(configuration.isPressed ? 0.10 : 0.001),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .contentShape(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(
                .timingCurve(0.22, 1, 0.36, 1, duration: 0.12),
                value: configuration.isPressed
            )
    }
}

private struct PanelTransportButtonStyle: ButtonStyle {
    var tint: Color?
    var isDestructive = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .labelStyle(.iconOnly)
            .foregroundStyle(
                isDestructive
                    ? AnyShapeStyle(NookPalette.danger)
                    : AnyShapeStyle(tint ?? .primary)
            )
            .frame(width: 28, height: 28)
            .background(
                .white.opacity(configuration.isPressed ? 0.12 : 0.045),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(
                .timingCurve(0.22, 1, 0.36, 1, duration: 0.14),
                value: configuration.isPressed
            )
    }
}

private struct EdgeSymbolButtonStyle: ButtonStyle {
    var tint: Color?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(tint ?? Color.secondary)
            .frame(width: 27, height: 27)
            .background(
                .white.opacity(configuration.isPressed ? 0.11 : 0.001),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .contentShape(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
            .animation(
                .timingCurve(0.22, 1, 0.36, 1, duration: 0.12),
                value: configuration.isPressed
            )
    }
}

private struct HiddenRecordingIndicatorStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(
                .timingCurve(0.22, 1, 0.36, 1, duration: 0.12),
                value: configuration.isPressed
            )
    }
}

private struct CompactMeetingControl: View {
    let symbol: String
    let label: String
    var tint: Color?
    let action: () -> Void

    init(
        symbol: String,
        label: String,
        tint: Color? = nil,
        action: @escaping () -> Void
    ) {
        self.symbol = symbol
        self.label = label
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
        }
        .buttonStyle(CompactMeetingControlStyle(tint: tint))
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct CompactMeetingControlStyle: ButtonStyle {
    let tint: Color?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(tint ?? Color.white.opacity(0.92))
            .frame(width: 26, height: 24)
            .background(
                .primary.opacity(configuration.isPressed ? 0.13 : 0.001),
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
            .contentShape(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
    }
}

private struct LiveStatusIndicator: View {
    let isPaused: Bool
    let level: Double

    var body: some View {
        HStack(spacing: 6) {
            NookPresence(
                state: .listening(level: level, isPaused: isPaused),
                size: 18,
                showsSurface: false
            )

            Text(isPaused ? "Paused" : "Recording")
                .font(NookType.metadata)
                .foregroundStyle(
                    isPaused ? NookPalette.warning : NookPalette.accent
                )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isPaused ? "Recording paused" : "Recording live")
    }
}

private struct AudioThread: View {
    let level: Double
    let isActive: Bool

    var body: some View {
        HStack(spacing: 9) {
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [.clear, .primary.opacity(0.10)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 0.5)

            RecordingWaveform(
                level: level,
                isActive: isActive,
                barCount: 14,
                minimumHeight: 2
            )
            .frame(width: 62, height: 12)

            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [.primary.opacity(0.10), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 0.5)
        }
        .accessibilityHidden(true)
    }
}

private struct TopAnchoredPanelShape: Shape {
    var bottomRadius: CGFloat
    var revealProgress: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get {
            AnimatablePair(bottomRadius, revealProgress)
        }
        set {
            bottomRadius = newValue.first
            revealProgress = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let progress = min(1, max(0.001, revealProgress))
        let bodyBottom = rect.minY + max(1, rect.height * progress)
        // Extend the cap above the panel bounds so neither the border nor the
        // glass highlight can draw a hairline across the physical screen edge.
        let capTop = rect.minY - 2
        let radius = min(
            bottomRadius * progress,
            rect.width / 2,
            max(0.5, (bodyBottom - rect.minY) / 2)
        )

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: capTop))
        path.addLine(to: CGPoint(x: rect.maxX, y: capTop))
        path.addLine(to: CGPoint(x: rect.maxX, y: bodyBottom - radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - radius, y: bodyBottom),
            control: CGPoint(x: rect.maxX, y: bodyBottom)
        )
        path.addLine(to: CGPoint(x: rect.minX + radius, y: bodyBottom))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: bodyBottom - radius),
            control: CGPoint(x: rect.minX, y: bodyBottom)
        )
        path.closeSubpath()
        return path
    }
}

/// Leaves the screen-edge cap open so the panel reads as an extension of the
/// menu bar instead of a rounded window placed over it.
private struct TopAnchoredPanelOutline: Shape {
    var topInset: CGFloat
    var bottomRadius: CGFloat
    var revealProgress: CGFloat

    var animatableData: AnimatablePair<
        CGFloat,
        AnimatablePair<CGFloat, CGFloat>
    > {
        get {
            AnimatablePair(
                topInset,
                AnimatablePair(bottomRadius, revealProgress)
            )
        }
        set {
            topInset = newValue.first
            bottomRadius = newValue.second.first
            revealProgress = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let progress = min(1, max(0.001, revealProgress))
        let bodyBottom = rect.minY + max(1, rect.height * progress)
        let radius = min(
            bottomRadius * progress,
            rect.width / 2,
            max(0.5, (bodyBottom - rect.minY) / 2)
        )
        let edgeStart = min(
            bodyBottom - radius,
            rect.minY + max(0, topInset)
        )

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: edgeStart))
        path.addLine(to: CGPoint(x: rect.minX, y: bodyBottom - radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + radius, y: bodyBottom),
            control: CGPoint(x: rect.minX, y: bodyBottom)
        )
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: bodyBottom))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: bodyBottom - radius),
            control: CGPoint(x: rect.maxX, y: bodyBottom)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: edgeStart))
        return path
    }
}

private struct MeetingPanelModeBar: View {
    let selection: MeetingPanelMode
    let notesDetached: Bool
    let select: (MeetingPanelMode) -> Void

    private var availableModes: [MeetingPanelMode] {
        MeetingPanelMode.allCases.filter {
            !notesDetached || $0 != .notes
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(availableModes) { mode in
                Button {
                    select(mode)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: mode.symbol)
                            .font(.system(size: 10, weight: .semibold))
                        Text(mode.label)
                            .font(NookType.metadata)
                    }
                    .foregroundStyle(
                        selection == mode
                            ? AnyShapeStyle(.primary)
                            : AnyShapeStyle(.secondary)
                    )
                    .frame(maxWidth: .infinity)
                    .frame(height: 26)
                    .contentShape(Rectangle())
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(
                                selection == mode
                                    ? NookPalette.accent
                                    : Color.clear
                            )
                            .frame(height: 2)
                    }
                }
                .buttonStyle(.plain)
                .help(mode.label)
                .accessibilityLabel("Show \(mode.label)")
                .accessibilityAddTraits(
                    selection == mode ? .isSelected : []
                )
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(.primary.opacity(0.075))
                .frame(height: 0.5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Meeting workspace")
    }
}

private struct LiveSummaryPanel: View {
    let insights: MeetingInsights?
    let isRefreshing: Bool
    let updatedAt: Date?
    let wordCount: Int
    let refresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("Meeting summary", systemImage: "text.alignleft")
                    .font(NookType.metadata)
                    .foregroundStyle(.primary)

                Spacer()

                if isRefreshing {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityLabel("Updating summary")
                }

                Button(action: refresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Update summary")
                .accessibilityLabel("Update meeting summary")
            }

            if let insights {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(insights.summary)
                            .font(NookType.bodyEmphasized)
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
                                    .font(NookType.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "text.append")
                        .foregroundStyle(NookPalette.accent)
                    Text(
                        wordCount == 0
                            ? "A faithful summary will appear as the conversation develops."
                            : "Finding the shape of the conversation…"
                    )
                    .font(NookType.metadata)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            HStack(spacing: 5) {
                Image(systemName: "lock.fill")
                Text(updatedLabel)
            }
            .font(NookType.micro)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        }
        .frame(maxWidth: .infinity, minHeight: 126, maxHeight: 138)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Meeting summary")
    }

    private var updatedLabel: String {
        guard let updatedAt else {
            return insights == nil
                ? "Generated locally when enough has been said"
                : "Generated locally · on this Mac"
        }
        return "Updated \(updatedAt.formatted(.relative(presentation: .named))) · on this Mac"
    }
}

private struct LiveNotesPanel: View {
    @Binding var notes: String
    var isFocused: FocusState<Bool>.Binding
    let detach: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label("My notes", systemImage: "pencil.line")
                    .font(NookType.metadata)
                    .foregroundStyle(.primary)
                Spacer()
                Text("Added to the Markdown when the meeting ends")
                    .font(NookType.micro)
                    .foregroundStyle(.secondary)

                Button(action: detach) {
                    Image(systemName: "macwindow.on.rectangle")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Open notes in a floating window")
                .accessibilityLabel("Open notes in a floating window")
            }

            NookNotesEditor(
                text: $notes,
                placeholder: "Type a thought, a question, or something to remember…",
                isFocused: Binding(
                    get: { isFocused.wrappedValue },
                    set: { isFocused.wrappedValue = $0 }
                ),
                contentInsets: EdgeInsets(
                    top: 10,
                    leading: 11,
                    bottom: 10,
                    trailing: 11
                ),
                lineSpacing: 3
            )
            .frame(minHeight: 132)
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
                        Color(nsColor: .separatorColor).opacity(0.55),
                        lineWidth: 0.7
                    )
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct DetachedNotesPanel: View {
    let bringForward: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "macwindow.on.rectangle")
                .font(NookType.bodyEmphasized)
                .foregroundStyle(NookPalette.accent)
                .frame(width: 28, height: 28)
                .background(
                    NookPalette.accent.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text("My Notes is floating")
                    .font(NookType.bodyEmphasized)
                Text("Keep writing there while Nook shows the meeting here.")
                    .font(NookType.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            Button("Bring Forward", action: bringForward)
                .buttonStyle(NookButtonStyle(tint: NookPalette.accent))
        }
        .frame(maxWidth: .infinity, minHeight: 126)
        .padding(.horizontal, 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("My Notes is open in a floating window")
    }
}

private struct NotchCaptionStream: View {
    let lines: [LiveCaptionLine]
    let fallback: String
    let revision: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .center, spacing: 6) {
            if lines.isEmpty {
                HStack(spacing: 9) {
                    Image(systemName: "ear")
                        .font(NookType.metadata)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(fallback)
                        .font(NookType.transcriptEmphasized)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 100)
                .multilineTextAlignment(.center)
                .transition(.opacity)
                .accessibilityElement(children: .combine)
            } else {
                ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                    NotchCaptionRow(
                        line: line,
                        isNewest: index == lines.count - 1,
                        prominence: prominence(for: index)
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
            reduceMotion
                ? nil
                : .timingCurve(0.22, 1, 0.36, 1, duration: 0.26),
            value: lines.map(\.id)
        )
        .animation(
            reduceMotion
                ? nil
                : .timingCurve(0.22, 1, 0.36, 1, duration: 0.16),
            value: revision
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Live transcript")
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
                .multilineTextAlignment(.center)
                .contentTransition(.interpolate)

            if line.isPartial {
                ListeningCaret(tint: line.source.nookTint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .opacity(prominence)
        .scaleEffect(
            reduceMotion ? 1 : 0.985 + (0.015 * prominence),
            anchor: .center
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(line.source.label): \(line.text)")
        .accessibilityValue(line.isPartial ? "Being transcribed" : "Final")
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
