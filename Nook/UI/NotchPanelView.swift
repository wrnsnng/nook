import AppKit
import SwiftUI

struct NotchPanelView: View {
    @EnvironmentObject private var meeting: MeetingCoordinator
    @EnvironmentObject private var geometry: NotchPanelGeometry
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false
    @FocusState private var notesEditorFocused: Bool
    @Namespace private var glassNamespace
    private let rendersForSnapshot: Bool

    init(rendersForSnapshot: Bool = false) {
        self.rendersForSnapshot = rendersForSnapshot
    }

    private var bodySize: CGSize {
        let preferred = NotchPanelMetrics.bodySize(
            for: meeting.phase,
            showsCaptions: meeting.showLiveCaptions,
            panelMode: meeting.panelMode
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

    private var reduceTransparency: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    private var isUltraCompact: Bool {
        meeting.phase.isRecording && !meeting.showLiveCaptions
    }

    private var isDetected: Bool {
        if case .detected = meeting.phase { true } else { false }
    }

    private var shellBottomRadius: CGFloat {
        if isUltraCompact { return 15 }
        if isDetected { return 22 }
        return meeting.phase.isRecording && meeting.showLiveCaptions ? 38 : 30
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
            if rendersForSnapshot || reduceTransparency {
                shellContent
                    .background(
                        opaqueShellGradient,
                        in: shellShape
                    )
                    .overlay {
                        shellOutlineShape
                            .stroke(
                                .primary.opacity(
                                    increaseContrast
                                        ? 0.30
                                        : (colorScheme == .dark ? 0.13 : 0.055)
                                ),
                                lineWidth: increaseContrast ? 1.2 : 0.8
                            )
                    }
                    .overlay {
                        shellHighlight
                    }
                    .shadow(
                        color: .black.opacity(
                            isDetected
                                ? (colorScheme == .dark ? 0.20 : 0.045)
                                : (colorScheme == .dark ? 0.30 : 0.065)
                        ),
                        radius: isDetected
                            ? 16
                            : (colorScheme == .dark ? 32 : 22),
                        y: isDetected
                            ? 6
                            : (colorScheme == .dark ? 16 : 8)
                    )
            } else {
                GlassEffectContainer(spacing: 16) {
                    shellContent
                        .background(
                            LinearGradient(
                                colors: colorScheme == .dark
                                    ? [
                                        Color.black.opacity(0.12),
                                        Color.black.opacity(0.12),
                                    ]
                                    : [
                                        Color.white.opacity(0.56),
                                        Color.white.opacity(0.24),
                                        Color.white.opacity(0.11),
                                    ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            in: shellShape
                        )
                        .glassEffect(
                            .regular.tint(
                                colorScheme == .dark
                                    ? Color.black.opacity(
                                            isHovering ? 0.20 : 0.24
                                    )
                                    : Color.white.opacity(
                                        isHovering ? 0.14 : 0.18
                                    )
                            ),
                            in: shellShape
                        )
                        .glassEffectID("top-panel-shell", in: glassNamespace)
                        .overlay {
                            shellOutlineShape
                                .stroke(
                                    .primary.opacity(
                                        increaseContrast
                                            ? 0.28
                                            : (colorScheme == .dark ? 0.085 : 0.055)
                                    ),
                                    lineWidth: increaseContrast ? 1.2 : 0.65
                                )
                        }
                        .overlay {
                            shellHighlight
                        }
                        .shadow(
                            color: .black.opacity(
                                isDetected
                                    ? (colorScheme == .dark ? 0.14 : 0.045)
                                    : colorScheme == .dark
                                    ? (isHovering ? 0.24 : 0.17)
                                    : (isHovering ? 0.11 : 0.065)
                            ),
                            radius: isDetected
                                ? (isHovering ? 18 : 14)
                                : (isHovering ? 30 : 22),
                            y: isDetected
                                ? (isHovering ? 8 : 5)
                                : (isHovering ? 12 : 8)
                        )
                }
            }
        }
        .frame(
            width: bodySize.width,
            height: totalHeight,
            alignment: .top
        )
        .contentShape(shellShape)
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                isHovering = hovering
            }
        }
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
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Nook meeting panel")
        .accessibilityIdentifier("nook.notchPanel")
    }

    private var opaqueShellGradient: LinearGradient {
        let colors: [Color]
        if reduceTransparency, !rendersForSnapshot {
            let background = Color(nsColor: .windowBackgroundColor)
            colors = [background, background]
        } else if colorScheme == .dark {
            colors = [
                Color.black.opacity(0.80),
                Color.black.opacity(0.80),
            ]
        } else {
            colors = [
                Color.white.opacity(0.98),
                Color.white.opacity(0.92),
                Color.white.opacity(0.86),
            ]
        }

        return LinearGradient(
            colors: colors,
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var shellContent: some View {
        phaseContent
            .opacity(contentRevealProgress)
            .offset(y: reduceMotion ? 0 : (1 - contentRevealProgress) * -8)
            .padding(
                .horizontal,
                isUltraCompact
                    ? 11
                    : (isDetected
                        ? 14
                        : (meeting.showLiveCaptions ? 26 : 20))
            )
            .padding(
                .top,
                geometry.topInset
                    + (isUltraCompact
                        ? 3
                        : (isDetected
                            ? 7
                            : (meeting.showLiveCaptions ? 10 : 11)))
            )
            .padding(
                .bottom,
                isUltraCompact
                    ? 3
                    : (isDetected
                        ? 9
                        : (meeting.showLiveCaptions ? 18 : 14))
            )
            .frame(width: bodySize.width, height: totalHeight, alignment: .top)
            .clipShape(shellShape)
    }

    private var shellHighlight: some View {
        shellOutlineShape
            .stroke(
                LinearGradient(
                    colors: [
                        .white.opacity(isHovering ? 0.16 : 0.10),
                        .clear,
                        NookPalette.accent.opacity(0.08),
                        .clear,
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 0.75
            )
            .blendMode(.screen)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var shellAnimation: Animation? {
        reduceMotion
            ? nil
            : .timingCurve(0.16, 0.78, 0.22, 1, duration: 0.38)
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
        HStack(spacing: 13) {
            NookPresence(state: .resting, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text("Nook is ready")
                    .font(NookType.bodyEmphasized)
                Text("Listening for meetings · Nothing leaves this Mac")
                    .font(NookType.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Record") {
                meeting.startManualMeeting()
            }
            .buttonStyle(PanelActionButtonStyle(tint: NookPalette.accent))
        }
    }

    private func detectedContent(_ detection: DetectedMeeting) -> some View {
        HStack(spacing: 10) {
            NookPresence(
                state: .detected,
                size: 30,
                showsSurface: false
            )

            VStack(alignment: .leading, spacing: 1) {
                Text(detection.suggestedTitle)
                    .font(NookType.bodyEmphasized)
                    .lineLimit(1)
                Text("\(detection.appName) · Not recording")
                    .font(NookType.micro)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            HStack(spacing: 2) {
                Button("Not now") {
                    meeting.dismissPrompt()
                }
                .buttonStyle(DetectedPromptButtonStyle())
                .keyboardShortcut(.cancelAction)
                .accessibilityHint("Leaves this meeting unrecorded")

                Button {
                    meeting.startDetectedMeeting()
                } label: {
                    Text("Record")
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
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    LiveStatusIndicator(
                        isPaused: meeting.isPaused,
                        level: meeting.audioLevel
                    )

                    Text(title)
                        .font(NookType.panelTitle)
                        .lineLimit(1)

                    Spacer(minLength: 14)

                    Text(elapsedLabel)
                        .font(NookType.code)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .accessibilityLabel(elapsedSpokenLabel)

                    recordingControls
                }

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

                Button {
                    meeting.showLiveCaptions = false
                } label: {
                    Capsule()
                        .fill(.primary.opacity(0.28))
                        .frame(width: 34, height: 3)
                        .frame(maxWidth: .infinity, minHeight: 10)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Collapse meeting workspace")
                .accessibilityLabel("Collapse meeting workspace")
            }
        } else {
            compactRecordingContent(title: title)
        }
    }

    private func compactRecordingContent(title: String) -> some View {
        HStack(spacing: 8) {
            Button {
                meeting.showLiveCaptions = true
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
        VStack(spacing: 8) {
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
            Label("Pause", systemImage: "pause.fill")
                .font(NookType.metadata)
                .padding(.horizontal, 9)
                .frame(height: 28)
                .background(
                    .primary.opacity(0.055),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )

            Label("Finish", systemImage: "stop.fill")
                .font(NookType.metadata)
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .frame(height: 28)
                .background(
                    NookPalette.danger,
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
        HStack(spacing: 15) {
            NookPresence(state: .thinking, size: 43)

            VStack(alignment: .leading, spacing: 4) {
                Text("Tucking this conversation away")
                    .font(NookType.panelTitle)
                Text(processingDetail(for: step))
                    .font(NookType.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
            ProgressView()
                .controlSize(.small)
        }
    }

    private func completedContent(_ title: String) -> some View {
        HStack(spacing: 14) {
            NookPresence(state: .saved, size: 44)

            VStack(alignment: .leading, spacing: 4) {
                Text("Tucked away")
                    .font(NookType.panelTitle)
                Text("\(title) · Saved as Markdown")
                    .font(NookType.caption)
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
        HStack(spacing: 14) {
            NookPresence(state: .attention, size: 44)

            VStack(alignment: .leading, spacing: 4) {
                Text("Nook needs a hand")
                    .font(NookType.panelTitle)
                Text(panelFailureMessage(message))
                    .font(NookType.caption)
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
        }
    }

    private func processingDetail(for step: MeetingPhase.ProcessingStep) -> String {
        switch step {
        case .preparing: "Securing the audio on this Mac"
        case .refining: "Turning live captions into a clean record"
        case .transcribing: "A careful second listen, entirely on-device"
        case .summarizing: "Finding decisions, themes, and next steps"
        case .saving: "Writing a plain Markdown file"
        }
    }

    private func openLibrary() {
        AppModel.shared.openLibrary()
    }
}

private struct PanelActionButtonStyle: ButtonStyle {
    var tint: Color?
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(NookType.control)
            .foregroundStyle(
                tint == nil
                    ? AnyShapeStyle(.primary)
                    : AnyShapeStyle(
                        colorScheme == .dark
                            ? Color.black.opacity(0.84)
                            : Color.white.opacity(0.96)
                    )
            )
            .padding(.horizontal, tint == nil ? 10 : 13)
            .frame(minHeight: 30)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        tint.map {
                            AnyShapeStyle(
                                $0.opacity(configuration.isPressed ? 0.80 : 1)
                            )
                        }
                            ?? AnyShapeStyle(
                                .primary.opacity(
                                    configuration.isPressed ? 0.08 : 0.001
                                )
                            )
                    )
            }
            .contentShape(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
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
                    ? AnyShapeStyle(NookPalette.accent)
                    : AnyShapeStyle(.secondary)
            )
            .padding(.horizontal, 8)
            .frame(minHeight: 32)
            .background(
                .primary.opacity(configuration.isPressed ? 0.07 : 0.001),
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
            .font(NookType.metadata)
            .labelStyle(.titleAndIcon)
            .foregroundStyle(
                isDestructive
                    ? AnyShapeStyle(Color.white)
                    : AnyShapeStyle(tint ?? .primary)
            )
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(
                tint?.opacity(configuration.isPressed ? 0.78 : 1)
                    ?? Color.primary.opacity(
                        configuration.isPressed ? 0.13 : 0.055
                    ),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(.primary.opacity(0.10), lineWidth: 0.6)
            }
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(
                .timingCurve(0.22, 1, 0.36, 1, duration: 0.14),
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
            .frame(width: 22, height: 22)
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
                    .frame(height: 28)
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
                Label("The gist so far", systemImage: "text.alignleft")
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
                .accessibilityLabel("Update summary so far")
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
        .frame(maxWidth: .infinity, minHeight: 142, maxHeight: 154)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Summary so far")
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

            ZStack(alignment: .topLeading) {
                if notes.isEmpty {
                    Text("Type a thought, a question, or something to remember…")
                        .font(NookType.body)
                        .foregroundStyle(.secondary)
                        .opacity(0.82)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 10)
                        .allowsHitTesting(false)
                }

                TextEditor(text: $notes)
                    .font(NookType.body)
                    .lineSpacing(3)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 5)
                    .focused(isFocused)
                    .accessibilityLabel("Personal meeting notes")
            }
            .frame(minHeight: 152)
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
        .frame(maxWidth: .infinity, minHeight: 142)
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
        VStack(alignment: .center, spacing: 7) {
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
                .frame(maxWidth: .infinity, minHeight: 116)
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
        .frame(maxWidth: .infinity, minHeight: 126, alignment: .bottom)
        .padding(.bottom, 8)
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
        case 1: return 0.84
        case 2: return 0.70
        default: return 0.58
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
            Circle()
                .fill(line.source.nookTint)
                .frame(width: isNewest ? 5 : 4, height: isNewest ? 5 : 4)
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
