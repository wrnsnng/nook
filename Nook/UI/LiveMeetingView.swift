import AppKit
import SwiftUI

struct LiveMeetingView: View {
    @EnvironmentObject private var meeting: MeetingCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let rendersForSnapshot: Bool

    init(rendersForSnapshot: Bool = false) {
        self.rendersForSnapshot = rendersForSnapshot
    }

    var body: some View {
        ZStack {
            NookAmbientBackground()

            switch meeting.phase {
            case .recording(let title, _):
                liveTranscript(title: title)
            case .processing(let step):
                processing(step)
            case .failed(let message):
                failure(message)
            case .completed(let title):
                completed(title)
            case .idle, .detected:
                waiting
            }
        }
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.32),
            value: meeting.phase
        )
    }

    @ViewBuilder
    private func liveTranscript(title: String) -> some View {
        if rendersForSnapshot {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    liveHeader(title: title)
                    transcriptStream
                }
                .frame(maxWidth: 860, alignment: .leading)
                .padding(.horizontal, 56)
                .padding(.top, 48)
                .frame(maxWidth: .infinity)

                Spacer(minLength: 18)
                staticControlShelf
            }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        liveHeader(title: title)

                        if meeting.liveTranscript.segments.isEmpty,
                           meeting.liveTranscript.latestText.isEmpty {
                            listeningState
                                .padding(.top, 48)
                        } else {
                            transcriptStream
                        }

                        Color.clear
                            .frame(height: 1)
                            .id("live-transcript-end")
                    }
                    .frame(maxWidth: 860, alignment: .leading)
                    .padding(.horizontal, 56)
                    .padding(.top, 48)
                    .padding(.bottom, 120)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: meeting.liveTranscript.revision) { _, _ in
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.28)) {
                        proxy.scrollTo("live-transcript-end", anchor: .bottom)
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    liveControlShelf
                }
            }
        }
    }

    private func liveHeader(title: String) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                HStack(spacing: 7) {
                    NookPresence(
                        state: .listening(
                            level: meeting.audioLevel,
                            isPaused: meeting.isPaused
                        ),
                        size: 20,
                        showsSurface: false
                    )
                    Text(meeting.isPaused ? "Paused" : "Recording")
                        .font(NookType.metadata)
                        .foregroundStyle(
                            meeting.isPaused
                                ? NookPalette.warning
                                : NookPalette.accent
                        )
                }
                Spacer()
                Text("On-device")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            Text(title)
                .font(NookType.largeTitle)
                .tracking(-0.7)
                .lineLimit(2)
                .accessibilityAddTraits(.isHeader)

            HStack(spacing: 18) {
                NookMetadataLabel(
                    title: elapsedLabel,
                    symbol: "clock",
                    tint: .secondary
                )
                .monospacedDigit()
                .contentTransition(.numericText())

                NookMetadataLabel(
                    title: "\(meeting.liveTranscript.wordCount) words",
                    symbol: "text.word.spacing",
                    tint: .secondary
                )
                .contentTransition(.numericText())

                NookMetadataLabel(
                    title: "System audio + microphone",
                    symbol: "waveform.and.mic",
                    tint: .secondary
                )
            }

            SoftDivider()
        }
    }

    private var transcriptStream: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(meeting.liveTranscript.segments) { segment in
                LiveTranscriptRow(segment: segment)
                    .id(segment.id)
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .bottom)),
                            removal: .opacity
                        )
                    )
            }

            if !meeting.liveTranscript.latestText.isEmpty {
                LivePartialRow(
                    source: meeting.liveTranscript.latestSource,
                    text: meeting.liveTranscript.latestText
                )
                .id("partial-\(meeting.liveTranscript.latestSource.rawValue)")
            }

            if let notice = meeting.liveCaptionNotice {
                Label(notice, systemImage: "info.circle")
                    .font(NookType.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 18)
            }
        }
        .padding(.top, 14)
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.24),
            value: meeting.liveTranscript.segments.count
        )
    }

    private var listeningState: some View {
        VStack(spacing: 18) {
            NookPresence(
                state: .listening(
                    level: meeting.audioLevel,
                    isPaused: meeting.isPaused
                ),
                size: 68
            )

            VStack(spacing: 6) {
                Text(
                    meeting.isPaused
                        ? "Capture paused"
                        : (meeting.audioLevel > 0.08
                            ? "Finding the words…"
                            : "Listening…")
                )
                    .font(NookType.spokenEmphasized)
                Text(
                    meeting.isPaused
                        ? "Resume when you’re ready. Nothing is saved while paused."
                        : "The first words will appear here as they’re spoken."
                )
                    .font(NookType.body)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 52)
    }

    private var liveControlShelf: some View {
        GlassEffectContainer(spacing: 12) {
            ViewThatFits(in: .horizontal) {
                fullLiveControls
                compactLiveControls
            }
            .padding(.horizontal, 18)
            .frame(height: 62)
            .frame(maxWidth: 800)
            .glassEffect(
                .regular.tint(.black.opacity(0.07)),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 18)
    }

    private var fullLiveControls: some View {
        HStack(spacing: 16) {
            RecordingWaveform(
                level: meeting.isPaused ? 0 : meeting.audioLevel,
                isActive: !meeting.isPaused,
                barCount: 18
            )
            .frame(width: 92, height: 26)

            captureStatus

            Spacer(minLength: 8)

            pauseButton
                .fixedSize()

            captionsButton
                .fixedSize()

            finishButton
                .fixedSize()
        }
    }

    private var compactLiveControls: some View {
        HStack(spacing: 8) {
            RecordingWaveform(
                level: meeting.isPaused ? 0 : meeting.audioLevel,
                isActive: !meeting.isPaused,
                barCount: 14
            )
            .frame(width: 54, height: 22)

            Text(elapsedLabel)
                .font(NookType.code)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .contentTransition(.numericText())

            Spacer(minLength: 4)

            Button {
                meeting.togglePause()
            } label: {
                Label(
                    meeting.isPaused ? "Resume" : "Pause",
                    systemImage: meeting.isPaused ? "play.fill" : "pause.fill"
                )
                .labelStyle(.iconOnly)
            }
            .buttonStyle(
                LiveShelfControlStyle(
                    tint: meeting.isPaused ? NookPalette.success : nil,
                    isCompact: true
                )
            )
            .disabled(meeting.pauseTransitionInFlight)
            .help(meeting.isPaused ? "Resume recording" : "Pause recording")
            .accessibilityLabel(
                meeting.isPaused ? "Resume recording" : "Pause recording"
            )

            Button {
                meeting.showLiveCaptions.toggle()
            } label: {
                Label(
                    meeting.showLiveCaptions
                        ? "Hide top captions"
                        : "Show top captions",
                    systemImage: meeting.showLiveCaptions
                        ? "captions.bubble.fill"
                        : "captions.bubble"
                )
                .labelStyle(.iconOnly)
            }
            .buttonStyle(LiveShelfControlStyle(isCompact: true))
            .help(
                meeting.showLiveCaptions
                    ? "Hide top captions"
                    : "Show top captions"
            )
            .accessibilityLabel(
                meeting.showLiveCaptions
                    ? "Hide top captions"
                    : "Show top captions"
            )

            Button {
                meeting.stopRecording()
            } label: {
                Label("Finish meeting", systemImage: "stop.fill")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(
                LiveShelfControlStyle(
                    tint: NookPalette.danger,
                    isDestructive: true,
                    isCompact: true
                )
            )
            .disabled(meeting.pauseTransitionInFlight)
            .help("Finish meeting")
            .accessibilityLabel("Finish meeting")
            .keyboardShortcut(".", modifiers: [.command, .shift])
        }
    }

    private var captureStatus: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(meeting.isPaused ? "Capture paused" : "Capturing locally")
                .font(NookType.metadata)
                .lineLimit(1)
            Text(elapsedLabel)
                .font(NookType.code)
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
        }
    }

    private var pauseButton: some View {
        Button {
            meeting.togglePause()
        } label: {
            Label(
                meeting.isPaused ? "Resume" : "Pause",
                systemImage: meeting.isPaused ? "play.fill" : "pause.fill"
            )
        }
        .buttonStyle(
            LiveShelfControlStyle(
                tint: meeting.isPaused ? NookPalette.success : nil
            )
        )
        .disabled(meeting.pauseTransitionInFlight)
    }

    private var captionsButton: some View {
        Button {
            meeting.showLiveCaptions.toggle()
        } label: {
            Label(
                meeting.showLiveCaptions
                    ? "Top captions on"
                    : "Top captions off",
                systemImage: meeting.showLiveCaptions
                    ? "captions.bubble.fill"
                    : "captions.bubble"
            )
        }
        .buttonStyle(LiveShelfControlStyle())
    }

    private var finishButton: some View {
        Button {
            meeting.stopRecording()
        } label: {
            Label("Finish meeting", systemImage: "stop.fill")
        }
        .buttonStyle(
            LiveShelfControlStyle(
                tint: NookPalette.danger,
                isDestructive: true
            )
        )
        .disabled(meeting.pauseTransitionInFlight)
        .keyboardShortcut(".", modifiers: [.command, .shift])
    }

    private var staticControlShelf: some View {
        HStack(spacing: 16) {
            RecordingWaveform(
                level: meeting.isPaused ? 0 : meeting.audioLevel,
                isActive: !meeting.isPaused,
                barCount: 18
            )
            .frame(width: 92, height: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.isPaused ? "Capture paused" : "Capturing locally")
                    .font(NookType.metadata)
                Text(elapsedLabel)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Label(
                meeting.isPaused ? "Resume" : "Pause",
                systemImage: meeting.isPaused ? "play.fill" : "pause.fill"
            )
            .font(NookType.control)
            .foregroundStyle(
                meeting.isPaused ? NookPalette.success : .secondary
            )

            Label("Top captions on", systemImage: "captions.bubble.fill")
                .font(NookType.metadata)
                .foregroundStyle(.secondary)

            Label("Finish meeting", systemImage: "stop.fill")
                .font(NookType.metadata)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background(
                    NookPalette.danger,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: 800)
        .frame(height: 62)
        .background(
            .white.opacity(0.085),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 18)
    }

    private func processing(_ step: MeetingPhase.ProcessingStep) -> some View {
        ScrollView {
            VStack(spacing: 30) {
                NookPresence(state: .thinking, size: 92)

                VStack(spacing: 10) {
                    Text("Tucking this conversation away")
                        .font(NookType.title)
                    Text(processingDetail(step))
                        .font(NookType.transcript)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 500)
                }

                ProcessingRail(current: step)
                    .frame(maxWidth: 650)

                if !meeting.liveTranscript.segments.isEmpty {
                    HStack(spacing: 20) {
                        Label(
                            "\(meeting.liveTranscript.wordCount) words captured",
                            systemImage: "text.word.spacing"
                        )
                        Label(
                            "\(meeting.liveTranscript.segments.count) passages",
                            systemImage: "quote.bubble"
                        )
                    }
                    .font(NookType.metadata)
                    .foregroundStyle(.secondary)
                }

            }
            .padding(64)
            .frame(maxWidth: .infinity, minHeight: 560)
        }
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: 24) {
            NookPresence(state: .attention, size: 88)

            VStack(spacing: 8) {
                Text("Nook needs a hand")
                    .font(NookType.title)
                Text(message)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }

            HStack(spacing: 10) {
                if let permission = meeting.requiredPermission {
                    Button(permission.primaryActionTitle) {
                        meeting.performPermissionPrimaryAction()
                    }
                    .buttonStyle(NookButtonStyle())

                    Button("Open \(settingsName(for: permission)) Settings") {
                        meeting.revealPermissions()
                    }
                    .buttonStyle(
                        NookButtonStyle(
                            tint: NookPalette.accent,
                            isProminent: true
                        )
                    )
                } else {
                    Button("Dismiss") {
                        meeting.resetStatus()
                    }
                    .buttonStyle(NookButtonStyle())
                }
            }
        }
        .padding(60)
    }

    private func settingsName(for permission: NookPermission) -> String {
        switch permission {
        case .screenRecording:
            "Screen Recording"
        case .microphone:
            "Microphone"
        case .speechRecognition:
            "Speech Recognition"
        }
    }

    private func completed(_ title: String) -> some View {
        VStack(spacing: 18) {
            NookPresence(state: .saved, size: 78)
            Text("Tucked away")
                .font(NookType.title)
            Text("\(title) · Saved as Markdown")
                .foregroundStyle(.secondary)
        }
    }

    private var waiting: some View {
        VStack(spacing: 18) {
            NookPresence(state: .resting, size: 70)
            VStack(spacing: 5) {
                Text("Ready when you are")
                    .font(NookType.title)
                Text("Nook stays quiet until a conversation begins.")
                    .font(NookType.body)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var elapsedLabel: String {
        let total = Int(meeting.elapsed)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private func processingSymbol(_ step: MeetingPhase.ProcessingStep) -> String {
        switch step {
        case .preparing: "waveform"
        case .refining: "text.badge.checkmark"
        case .transcribing: "ear"
        case .summarizing: "sparkles"
        case .saving: "doc.badge.plus"
        }
    }

    private func processingDetail(_ step: MeetingPhase.ProcessingStep) -> String {
        switch step {
        case .preparing:
            meeting.elapsed > 2
                ? "Securing the recording before Nook shapes it into notes."
                : "Warming up the on-device listener. This only takes a moment."
        case .refining:
            "Cleaning up the live captions while preserving what was actually said."
        case .transcribing:
            "Giving the saved audio a careful second listen, entirely on this Mac."
        case .summarizing:
            "Finding the useful shape of the conversation: themes, decisions, and next steps."
        case .saving:
            "Writing a durable Markdown note you can read with any editor."
        }
    }
}

private struct LiveShelfControlStyle: ButtonStyle {
    var tint: Color?
    var isDestructive = false
    var isCompact = false
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(NookType.control)
            .lineLimit(1)
            .foregroundStyle(
                isDestructive
                    ? AnyShapeStyle(Color.white)
                    : AnyShapeStyle(tint ?? .primary)
            )
            .padding(.horizontal, isCompact ? 0 : 11)
            .frame(
                width: isCompact ? 34 : nil,
                height: 32
            )
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        isDestructive
                            ? AnyShapeStyle(
                                NookPalette.danger.opacity(
                                    configuration.isPressed ? 0.78 : 1
                                )
                            )
                            : AnyShapeStyle(
                                .primary.opacity(
                                    configuration.isPressed ? 0.13 : 0.055
                                )
                            )
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(
                        .primary.opacity(
                            colorScheme == .dark ? 0.11 : 0.075
                        ),
                        lineWidth: 0.6
                    )
            }
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

private struct LiveTranscriptRow: View {
    let segment: TranscriptSegment

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .trailing, spacing: 8) {
                SourceBadge(source: segment.source)
                Text(segment.timestamp)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            .frame(width: 92, alignment: .trailing)

            Text(segment.text)
                .font(NookType.spoken)
                .lineSpacing(5)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 18)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            SoftDivider()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(segment.source.label): \(segment.text)")
        .accessibilityValue(segment.timestamp)
    }
}

private struct LivePartialRow: View {
    let source: TranscriptSegment.Source
    let text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            SourceBadge(source: source)
                .frame(width: 92, alignment: .trailing)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(text)
                    .font(NookType.spokenEmphasized)
                    .lineSpacing(5)
                    .contentTransition(.interpolate)
                Circle()
                    .fill(source.nookTint)
                    .frame(width: 5, height: 5)
                    .symbolEffect(.pulse, isActive: !reduceMotion)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 18)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(source.label): \(text)")
        .accessibilityValue("Being transcribed")
    }
}

private struct ProcessingRail: View {
    let current: MeetingPhase.ProcessingStep

    private let steps: [MeetingPhase.ProcessingStep] = [
        .preparing,
        .refining,
        .summarizing,
        .saving
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.element) { index, step in
                VStack(spacing: 9) {
                    ZStack {
                        Circle()
                            .fill(fill(for: step))
                            .frame(width: 24, height: 24)
                        if state(for: step) == .done {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                        } else if state(for: step) == .current {
                            Circle()
                                .fill(.white)
                                .frame(width: 6, height: 6)
                        }
                    }

                    Text(shortTitle(step))
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(
                            state(for: step) == .waiting
                                ? AnyShapeStyle(.tertiary)
                                : AnyShapeStyle(.secondary)
                        )
                }
                .frame(maxWidth: .infinity)
                .overlay(alignment: .topLeading) {
                    if index > 0 {
                        Rectangle()
                            .fill(connectorColor(before: step))
                            .frame(width: 92, height: 2)
                            .offset(x: -46, y: 11)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Meeting note progress")
        .accessibilityValue("\(shortTitle(current)), step \(normalizedIndex(current) + 1) of 4")
    }

    private enum StepState {
        case done
        case current
        case waiting
    }

    private func state(for step: MeetingPhase.ProcessingStep) -> StepState {
        let currentIndex = normalizedIndex(current)
        let stepIndex = normalizedIndex(step)
        if stepIndex < currentIndex { return .done }
        if stepIndex == currentIndex { return .current }
        return .waiting
    }

    private func normalizedIndex(_ step: MeetingPhase.ProcessingStep) -> Int {
        switch step {
        case .preparing: 0
        case .refining, .transcribing: 1
        case .summarizing: 2
        case .saving: 3
        }
    }

    private func fill(for step: MeetingPhase.ProcessingStep) -> Color {
        switch state(for: step) {
        case .done: NookPalette.success
        case .current: NookPalette.voiceSelf
        case .waiting: Color.primary.opacity(0.09)
        }
    }

    private func connectorColor(before step: MeetingPhase.ProcessingStep) -> Color {
        state(for: step) == .waiting
            ? Color.primary.opacity(0.08)
            : NookPalette.success.opacity(0.55)
    }

    private func shortTitle(_ step: MeetingPhase.ProcessingStep) -> String {
        switch step {
        case .preparing: "Capture"
        case .refining, .transcribing: "Transcript"
        case .summarizing: "Distill"
        case .saving: "Save"
        }
    }
}
