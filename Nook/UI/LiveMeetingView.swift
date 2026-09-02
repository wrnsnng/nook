import AppKit
import SwiftUI

/// This is the Library window's detail pane, so every re-render of it re-lays
/// out that whole window. The fast outputs (`audioLevel`, `elapsed`,
/// `liveTranscript`) are therefore read only inside the small private leaf
/// views further down this file, each observing `meeting.live` through
/// `@ObservedObject var live`. Nothing in this struct's body, helpers or
/// modifiers may read them: the coordinator's forwarders (`meeting.audioLevel`
/// and friends) compile but never update a view, and reading `meeting.live.x`
/// here would drag the whole window along at 10 to 12 Hz.
struct LiveMeetingView: View {
    @EnvironmentObject private var meeting: MeetingCoordinator
    @EnvironmentObject private var shortcuts: ShortcutStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var transcriptScroll = LiveTranscriptScrollState()
    private let rendersForSnapshot: Bool
    private let recordingControlsEnabled: Bool

    init(rendersForSnapshot: Bool = false, recordingControlsEnabled: Bool = true) {
        self.rendersForSnapshot = rendersForSnapshot
        self.recordingControlsEnabled = recordingControlsEnabled
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
                    transcriptStream(showsListeningState: false)
                }
                .frame(maxWidth: 860, alignment: .leading)
                .padding(.horizontal, 56)
                .padding(.top, 48)
                .frame(maxWidth: .infinity)

                Spacer(minLength: 18)
                staticControlShelf
            }
        } else {
            ScrollView {
                // Only the header and transcript container live here. Making
                // both levels lazy can retain an inflated transcript estimate
                // after a large reset, leaving the viewport in blank space.
                // Individual transcript rows remain lazy in transcriptStream.
                VStack(alignment: .leading, spacing: 0) {
                    liveHeader(title: title)
                    transcriptStream(showsListeningState: true) {
                        updateScrollWithoutAnimation { $0.transcriptChanged() }
                    }
                }
                .frame(maxWidth: 860, alignment: .leading)
                .padding(.horizontal, 56)
                .padding(.top, 48)
                // The shelf reserves its own space through safeAreaInset.
                .padding(.bottom, 18)
                .frame(maxWidth: .infinity)
            }
            // The native edge is not sufficient for appended or reflowing
            // text. Request it again only while following, then correct once
            // measured layout grows, without starting a scroll animation.
            .scrollPosition($transcriptScroll.position)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.top, for: .alignment)
            .onScrollGeometryChange(for: LiveTranscriptScrollState.Observation.self) { geometry in
                transcriptScroll.observation(geometry)
            } action: { _, observation in
                updateScrollWithoutAnimation { $0.geometryChanged(observation) }
            }
            .onScrollPhaseChange { _, phase, context in
                updateScrollWithoutAnimation {
                    $0.phaseChanged(
                        to: phase,
                        isAtLatest: LiveTranscriptScrollState.isAtLatest(context.geometry)
                    )
                }
            }
            .onAppear {
                // Reopening the live view should reach the current words even
                // when no new revision arrives, such as while capture is paused.
                transcriptScroll.appeared()
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 10) {
                    if transcriptScroll.showsJumpToLatest {
                        Button {
                            withAnimation(NookMotion.quickAnimation(reduceMotion: reduceMotion)) {
                                transcriptScroll.jumpToLatest()
                            }
                        } label: {
                            Label("Jump to latest", systemImage: "arrow.down")
                        }
                        .buttonStyle(NookButtonStyle())
                        .background(
                            NookPalette.paper,
                            in: RoundedRectangle(cornerRadius: NookRadius.control, style: .continuous)
                        )
                        .help("Show the latest words and follow new transcript updates")
                        .accessibilityHint("Resumes following the live transcript")
                    }
                    liveControlShelf
                }
            }
        }
    }

    private func updateScrollWithoutAnimation(_ update: (inout LiveTranscriptScrollState) -> Void) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { update(&transcriptScroll) }
    }

    private func liveHeader(title: String) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                HStack(spacing: 7) {
                    LiveListeningPresence(
                        live: meeting.live,
                        isPaused: meeting.isPaused,
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
                LiveClock(live: meeting.live) { clock in
                    NookMetadataLabel(
                        title: clock,
                        symbol: "clock",
                        tint: .secondary
                    )
                }
                .monospacedDigit()
                .contentTransition(.numericText())

                LiveWordCount(live: meeting.live)
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

    private func transcriptStream(
        showsListeningState: Bool,
        onTranscriptChanged: (() -> Void)? = nil
    ) -> some View {
        LiveTranscriptStream(
            live: meeting.live,
            isPaused: meeting.isPaused,
            captionNotice: meeting.liveCaptionNotice,
            showsListeningState: showsListeningState,
            onTranscriptChanged: onTranscriptChanged
        )
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
        // Synthetic replay can exercise the real scroll surface without
        // exposing recording actions, including the compact shelf's shortcuts.
        // Jump to latest lives outside this subtree and remains available.
        .disabled(!recordingControlsEnabled)
    }

    private var fullLiveControls: some View {
        HStack(spacing: 16) {
            LiveWaveform(
                live: meeting.live,
                isPaused: meeting.isPaused,
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
            LiveWaveform(
                live: meeting.live,
                isPaused: meeting.isPaused,
                barCount: 14
            )
            .frame(width: 54, height: 22)

            LiveClock(live: meeting.live) { Text($0) }
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
                toggleTopPanel()
            } label: {
                Label(
                    topPanelActionLabel,
                    systemImage: topPanelSymbol
                )
                .labelStyle(.iconOnly)
            }
            .buttonStyle(LiveShelfControlStyle(isCompact: true))
            .help(topPanelActionLabel)
            .accessibilityLabel(topPanelActionLabel)

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
            .keyboardShortcut(
                shortcuts.binding(for: .finishMeeting).keyEquivalent,
                modifiers: shortcuts.binding(for: .finishMeeting).eventModifiers
            )
        }
    }

    private var captureStatus: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(meeting.isPaused ? "Capture paused" : "Capturing locally")
                .font(NookType.metadata)
                .lineLimit(1)
            LiveClock(live: meeting.live) { Text($0) }
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
            toggleTopPanel()
        } label: {
            Label(
                topPanelActionLabel,
                systemImage: topPanelSymbol
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
        .keyboardShortcut(
            shortcuts.binding(for: .finishMeeting).keyEquivalent,
            modifiers: shortcuts.binding(for: .finishMeeting).eventModifiers
        )
    }

    private var staticControlShelf: some View {
        HStack(spacing: 16) {
            LiveWaveform(
                live: meeting.live,
                isPaused: meeting.isPaused,
                barCount: 18
            )
            .frame(width: 92, height: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.isPaused ? "Capture paused" : "Capturing locally")
                    .font(NookType.metadata)
                LiveClock(live: meeting.live) { Text($0) }
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

            Label("Top panel on", systemImage: "rectangle.topthird.inset.filled")
                .font(NookType.metadata)
                .foregroundStyle(.secondary)

            Label("Finish meeting", systemImage: "stop.fill")
                .font(NookType.metadata)
                .foregroundStyle(NookPalette.prominentButtonForeground)
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

                if step != .discarding {
                    ProcessingRail(current: step)
                        .frame(maxWidth: 650)
                }

                LiveProcessingStats(live: meeting.live)

                if step != .discarding, meeting.canCancelProcessing {
                    Button("Cancel and discard recording") {
                        meeting.requestProcessingCancellation()
                    }
                    .buttonStyle(NookButtonStyle())
                    .accessibilityHint(
                        "Asks before permanently discarding this recording without saving a note"
                    )
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
                    .font(NookType.body)
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

    private var topPanelActionLabel: String {
        if meeting.topPanelHidden {
            return "Show top panel"
        }
        return meeting.showLiveCaptions
            ? "Collapse top panel"
            : "Expand top panel"
    }

    private var topPanelSymbol: String {
        if meeting.topPanelHidden {
            return "rectangle.expand.vertical"
        }
        return meeting.showLiveCaptions
            ? "rectangle.compress.vertical"
            : "rectangle.expand.vertical"
    }

    private func toggleTopPanel() {
        if meeting.topPanelHidden {
            meeting.restoreTopPanel()
        } else if meeting.showLiveCaptions {
            meeting.collapseTopPanel()
        } else {
            meeting.expandTopPanel()
        }
    }

    private func processingDetail(_ step: MeetingPhase.ProcessingStep) -> String {
        // Shared with the top panel so a step never reads two ways, and it
        // carries the part counter while a long meeting is condensed in parts.
        let detail = meeting.processingDetail
        return detail.isEmpty ? step.displaySentence : detail
    }
}

struct LiveShelfControlStyle: ButtonStyle {
    var tint: Color?
    var isDestructive = false
    var isCompact = false
    @Environment(\.isFocused) private var isFocused
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    func makeBody(configuration: Configuration) -> some View {
        let isPressed = configuration.isPressed && isEnabled
        let outline = self.outline(contrast: contrast)
        return configuration.label
            .font(NookType.control)
            .lineLimit(1)
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, isCompact ? 0 : 11)
            .frame(
                width: isCompact ? 34 : nil,
                height: 32
            )
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(backgroundColor(isPressed: isPressed))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(
                        .primary.opacity(outline.opacity),
                        lineWidth: outline.width
                    )
            }
            .opacity(isEnabled ? 1 : 0.42)
            .scaleEffect(NookMotion.pressedScale(isPressed: isPressed, reduceMotion: reduceMotion))
            .animation(NookMotion.quickAnimation(reduceMotion: reduceMotion), value: isPressed)
            .nookFocusRing(
                RoundedRectangle(cornerRadius: 10, style: .continuous),
                isVisible: isFocused && isEnabled
            )
    }

    var foregroundColor: Color {
        // Resume's semantic green remains in the fill. Using it as small text
        // over the pressed light surface fell below readable contrast.
        isDestructive ? NookPalette.prominentButtonForeground : .primary
    }

    func backgroundColor(isPressed: Bool) -> Color {
        if isDestructive {
            // Dark-mode danger is pink, so use the shared dark filled-button
            // ink and keep enough pressed fill to read over the glass shelf.
            return NookPalette.danger.opacity(isPressed ? 0.90 : 1)
        }
        return (tint ?? .primary).opacity(isPressed ? 0.13 : 0.055)
    }

    func outline(contrast: ColorSchemeContrast) -> NookOutline.Metrics {
        NookOutline.button(isProminent: isDestructive, contrast: contrast)
    }
}

/// Owns only the scroll policy, not transcript content or accessibility focus.
/// SwiftUI clears the edge position when the user scrolls. We release it as
/// soon as scrolling begins too, so a new partial cannot fight that gesture.
struct LiveTranscriptScrollState {
    struct Extent: Equatable {
        let contentHeight: CGFloat
        let viewportHeight: CGFloat
        let viewportWidth: CGFloat
        let visibleHeight: CGFloat
        let topInset: CGFloat
        let bottomInset: CGFloat

        var latestOffsetY: CGFloat {
            max(-topInset, contentHeight + bottomInset - visibleHeight)
        }

        func isAtLatest(offsetY: CGFloat) -> Bool {
            guard viewportHeight > 0, visibleHeight > 0 else { return false }
            return abs(offsetY - latestOffsetY) <= 2
        }
    }

    struct Observation: Equatable {
        let isAtLatest: Bool
        let generation: UInt
        let extent: Extent?
        let contentOffsetY: CGFloat?
    }

    var position = ScrollPosition(edge: .bottom)
    private(set) var phase: ScrollPhase = .idle
    private(set) var isAtLatest = true
    private var generation: UInt = 0
    private var lastExtent: Extent?
    private var lastFollowingOffset: CGFloat?

    var isFollowing: Bool {
        position.edge == .bottom && !position.isPositionedByUser
    }

    var showsJumpToLatest: Bool {
        !isFollowing && !isAtLatest
    }

    mutating func appeared() {
        generation &+= 1
        phase = .idle
        isAtLatest = true
        lastExtent = nil
        lastFollowingOffset = nil
        position.scrollTo(edge: .bottom)
    }

    mutating func jumpToLatest() {
        generation &+= 1
        lastFollowingOffset = nil
        position.scrollTo(edge: .bottom)
    }

    /// Returns whether a fresh bottom request was made. The view applies these
    /// automatic requests without animation; only an explicit Jump animates.
    @discardableResult
    mutating func transcriptChanged() -> Bool {
        requestBottomWhileFollowing()
    }

    @discardableResult
    mutating func phaseChanged(to phase: ScrollPhase, isAtLatest: Bool) -> Bool {
        generation &+= 1
        self.phase = phase
        self.isAtLatest = isAtLatest
        lastFollowingOffset = nil
        switch phase {
        case .interacting, .decelerating:
            position.isPositionedByUser = true
        case .idle:
            // Use the geometry supplied with the phase, rather than an older
            // visibility callback, when a gesture or momentum scroll ends.
            if isAtLatest, position.isPositionedByUser {
                position.scrollTo(edge: .bottom)
                return true
            }
            // Growth during a touch or an explicit Jump waits until that
            // interaction has settled rather than fighting it in flight.
            if !isAtLatest { return requestBottomWhileFollowing() }
        case .tracking:
            // Tracking can be only a touch with no movement. Keep the anchor
            // until actual interaction, even if words arrive during that touch.
            break
        case .animating:
            // Our Jump action animates too. It must not be treated as the user
            // scrolling away and detach the edge we just requested.
            break
        }
        return false
    }

    func observation(isAtLatest: Bool) -> Observation {
        Observation(isAtLatest: isAtLatest, generation: generation, extent: nil, contentOffsetY: nil)
    }

    func observation(_ geometry: ScrollGeometry) -> Observation {
        observation(
            extent: Self.measuredExtent(geometry),
            offsetY: geometry.contentOffset.y
        )
    }

    func observation(
        extent: Extent,
        offsetY: CGFloat
    ) -> Observation {
        Observation(
            isAtLatest: extent.isAtLatest(offsetY: offsetY),
            generation: generation,
            extent: extent,
            // An accessibility scrollbar can move without scroll phases or a
            // user-positioned binding. Observe its offset only until detached,
            // not every pixel while the user reads earlier passages.
            contentOffsetY: isFollowing && phase == .idle ? offsetY : nil
        )
    }

    @discardableResult
    mutating func geometryChanged(_ observation: Observation) -> Bool {
        // A transformed geometry callback can be delivered after a newer phase
        // or explicit Jump. It must not overwrite that decision in either direction.
        guard observation.generation == generation else { return false }
        let previousExtent = lastExtent
        let extentChanged = observation.extent != nil && observation.extent != previousExtent
        let previousOffset = lastFollowingOffset
        if let extent = observation.extent { lastExtent = extent }
        if let offset = observation.contentOffsetY, let extent = observation.extent,
           offset >= -extent.topInset - 2, offset <= extent.latestOffsetY + 2 {
            lastFollowingOffset = offset
        } else {
            // A stale offset beyond newly shortened content is not a valid
            // reading position. Its eventual backwards clamp is not Page Up.
            lastFollowingOffset = nil
        }
        isAtLatest = observation.isAtLatest
        if !isAtLatest, isFollowing, phase == .idle,
           let previousExtent, let extent = observation.extent,
           extent.viewportHeight == previousExtent.viewportHeight,
           extent.viewportWidth == previousExtent.viewportWidth,
           extent.visibleHeight == previousExtent.visibleHeight,
           extent.topInset == previousExtent.topInset,
           extent.bottomInset == previousExtent.bottomInset,
           extent.contentHeight >= previousExtent.contentHeight,
           let previousOffset, let offset = observation.contentOffsetY,
           offset < previousOffset - 2 {
            // A Page Up or accessibility move can be delivered with newly
            // appended text. Growth alone must not outrank movement into
            // history. Shrinking content and viewport changes can themselves
            // move the offset backwards, so those still use layout correction.
            generation &+= 1
            lastFollowingOffset = nil
            position.isPositionedByUser = true
            return false
        }
        // Also handle user positioning that changes geometry without an active
        // gesture, such as keyboard scrolling. Never interrupt ongoing momentum.
        if isAtLatest, phase == .idle, position.isPositionedByUser {
            position.scrollTo(edge: .bottom)
            return true
        }
        // Appends, partial wrapping, viewport resize and shelf changes can
        // finish layout after the revision's first request. Deduplicate by
        // extent so the resulting offset callback cannot form a scroll loop.
        if extentChanged, !isAtLatest { return requestBottomWhileFollowing() }
        return false
    }

    private mutating func requestBottomWhileFollowing() -> Bool {
        guard isFollowing, phase == .idle else { return false }
        position.scrollTo(edge: .bottom)
        return true
    }

    static func isAtLatest(_ geometry: ScrollGeometry) -> Bool {
        measuredExtent(geometry).isAtLatest(offsetY: geometry.contentOffset.y)
    }

    private static func measuredExtent(_ geometry: ScrollGeometry) -> Extent {
        // The native safe-area shelf reduces containerSize, but visibleRect
        // still includes that inset. Subtracting the reduced container height
        // counts the shelf twice and can never recognize the actual bottom.
        // Clamp short content to its top inset rather than accepting old offsets
        // beyond a newly shortened document as visible words.
        Extent(
            contentHeight: geometry.contentSize.height,
            viewportHeight: geometry.containerSize.height,
            viewportWidth: geometry.containerSize.width,
            visibleHeight: geometry.visibleRect.height,
            topInset: geometry.contentInsets.top,
            bottomInset: geometry.contentInsets.bottom
        )
    }
}

/// The transcript column: finalized rows, the in-progress partial and, until
/// anything has been said, the listening placeholder. It also raises the
/// revision trigger for follow-the-bottom scrolling through
/// `onTranscriptChanged`, so the scroll state itself can stay next to the
/// ScrollView in `LiveMeetingView` while the fast reads stay down here.
private struct LiveTranscriptStream: View {
    @ObservedObject var live: MeetingLiveSignals
    let isPaused: Bool
    let captionNotice: String?
    let showsListeningState: Bool
    let onTranscriptChanged: (() -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // The trigger sits outside the branch so switching from the listening
        // placeholder to the first words does not reset it.
        content
            .onChange(of: live.liveTranscript.revision) { _, _ in
                onTranscriptChanged?()
            }
    }

    @ViewBuilder
    private var content: some View {
        if showsListeningState,
           live.liveTranscript.segments.isEmpty,
           live.liveTranscript.latestText.isEmpty {
            LiveListeningState(live: live, isPaused: isPaused)
                .padding(.top, 48)
        } else {
            stream
        }
    }

    private var stream: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(live.liveTranscript.segments) { segment in
                LiveTranscriptRow(segment: segment)
                    .id(segment.id)
                    // A new line sliding up is the motion Reduce Motion is
                    // asking Nook not to make, so it fades in instead.
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .asymmetric(
                                insertion: .opacity
                                    .combined(with: .move(edge: .bottom)),
                                removal: .opacity
                            )
                    )
            }

            if !live.liveTranscript.latestText.isEmpty {
                LivePartialRow(
                    source: live.liveTranscript.latestSource,
                    text: live.liveTranscript.latestText
                )
                .id("partial-\(live.liveTranscript.latestSource.rawValue)")
            }

            if let notice = captionNotice {
                Label(notice, systemImage: "info.circle")
                    .font(NookType.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 18)
            }
        }
        .padding(.top, 14)
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.24),
            value: live.liveTranscript.segments.count
        )
    }
}

private struct LiveListeningState: View {
    @ObservedObject var live: MeetingLiveSignals
    let isPaused: Bool

    var body: some View {
        VStack(spacing: 18) {
            NookPresence(
                state: .listening(
                    level: live.audioLevel,
                    isPaused: isPaused
                ),
                size: 68
            )

            VStack(spacing: 6) {
                Text(
                    isPaused
                        ? "Capture paused"
                        : (live.audioLevel > 0.08
                            ? "Finding the words…"
                            : "Listening…")
                )
                    .font(NookType.spokenEmphasized)
                Text(
                    isPaused
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
}

/// Thin observers that forward one fast value into a shared subview. Those
/// subviews are used elsewhere with plain values, so they are wrapped rather
/// than taught about `MeetingLiveSignals`.
private struct LiveListeningPresence: View {
    @ObservedObject var live: MeetingLiveSignals
    let isPaused: Bool
    let size: CGFloat
    var showsSurface = true

    var body: some View {
        NookPresence(
            state: .listening(level: live.audioLevel, isPaused: isPaused),
            size: size,
            showsSurface: showsSurface
        )
    }
}

private struct LiveWaveform: View {
    @ObservedObject var live: MeetingLiveSignals
    let isPaused: Bool
    let barCount: Int

    var body: some View {
        RecordingWaveform(
            level: isPaused ? 0 : live.audioLevel,
            isActive: !isPaused,
            barCount: barCount
        )
    }
}

private struct LiveClock<Content: View>: View {
    @ObservedObject var live: MeetingLiveSignals
    @ViewBuilder let content: (String) -> Content

    var body: some View {
        content(NookElapsedTime.clock(live.elapsed))
    }
}

private struct LiveWordCount: View {
    @ObservedObject var live: MeetingLiveSignals

    var body: some View {
        NookMetadataLabel(
            title: "\(live.liveTranscript.wordCount) words",
            symbol: "text.word.spacing",
            tint: .secondary
        )
    }
}

private struct LiveProcessingStats: View {
    @ObservedObject var live: MeetingLiveSignals

    var body: some View {
        if !live.liveTranscript.segments.isEmpty {
            HStack(spacing: 20) {
                Label(
                    "\(live.liveTranscript.wordCount) words captured",
                    systemImage: "text.word.spacing"
                )
                Label(
                    "\(live.liveTranscript.segments.count) passages",
                    systemImage: "quote.bubble"
                )
            }
            .font(NookType.metadata)
            .foregroundStyle(.secondary)
        }
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
        case .discarding: 0
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
        // All nouns: the rail names the thing being made at each step, not
        // an instruction. It used to mix the two, so "Transcript" and "Distill"
        // read as different kinds of label sitting in the same row.
        case .preparing: "Capture"
        case .refining, .transcribing: "Transcript"
        case .summarizing: "Summary"
        case .saving: "Note"
        case .discarding: "Cleanup"
        }
    }
}
