import AppKit
import Combine
import SwiftUI

@MainActor
final class NotchPanelGeometry: ObservableObject {
    @Published var topInset: CGFloat = NSStatusBar.system.thickness
    @Published var revealProgress: CGFloat = 1
    @Published var maximumPanelWidth: CGFloat = 720
    @Published var cameraHousingWidth: CGFloat = 0
    /// Whether the consent prompt has shrunk to its Record affordance.
    @Published var detectionPromptIsCompact = false
    /// Whether the pointer rests on the island. Only the compact recording
    /// state answers it, by lowering its control shelf.
    @Published var isHovering = false
    /// True while the island folds back into the camera housing. The view
    /// keeps showing what it showed last, so the content goes away with the
    /// shape instead of switching to an empty state first.
    @Published var isTucking = false
}

/// How the consent prompt behaves over time and around focus.
///
/// Both rules are here, and pure, because both were previously decided inline
/// and were wrong in ways nothing could catch: a prompt that vanished after
/// eight seconds, and a panel that activated Nook over whatever meeting app the
/// user was actually looking at.
enum DetectionPromptPolicy {
    /// What the prompt is showing.
    enum State: Equatable {
        /// Meeting title, application, and both answers.
        case expanded
        /// A Record affordance and a one-click dismissal, nothing else.
        case compact
    }

    /// How long the full prompt stays before it collapses.
    ///
    /// Eight seconds was long enough to be seen and far too short to be
    /// answered: someone who glances at a notification, finishes a sentence,
    /// and looks back finds nothing there. A minute covers that, and the
    /// prompt does not disappear at the end of it either.
    static let expandedSeconds: Double = 60

    static func state(afterVisibleFor seconds: Double) -> State {
        seconds < expandedSeconds ? .expanded : .compact
    }

    /// Whether the panel may take key focus to show the prompt.
    ///
    /// Only when Nook is already the front application. Detection fires while
    /// the user is joining a meeting, and activating over that window steals
    /// the keystroke they were in the middle of, moves their camera and
    /// microphone controls behind another window, and does it for a prompt
    /// they did not ask for. Principle 3 calls the live surface glanceable
    /// rather than a floating dialog, and a dialog is exactly what taking
    /// focus makes it. Return and Esc still answer the prompt for anyone
    /// already in Nook, and the menu bar and the notification answer it for
    /// everyone else.
    static func takesKeyFocus(applicationIsActive: Bool) -> Bool {
        applicationIsActive
    }
}

/// What the island is showing, which decides its shape.
enum NotchIslandMode: Equatable, Sendable {
    case idle
    case detected(compact: Bool)
    /// Waveform and clock either side of the camera; the control shelf
    /// hangs below only while the pointer is on the island.
    case recordingCompact(showsControls: Bool)
    case recordingExpanded(MeetingPanelMode)
    case hiddenRecording
    case processing
    case completed
    case failed

    /// Content identity. Hovering keeps the compact identity, so the ears
    /// stay put while only the shelf comes and goes.
    var contentIdentity: String {
        switch self {
        case .idle: "idle"
        case .detected(let compact): compact ? "detected-compact" : "detected"
        case .recordingCompact: "recording-compact"
        case .recordingExpanded: "recording-expanded"
        case .hiddenRecording: "hidden"
        case .processing: "processing"
        case .completed: "completed"
        case .failed: "failed"
        }
    }

    /// Cards float: they cast a shadow and need room for it. The ears are
    /// part of the bezel and hang nothing below the menu bar.
    var floatsAboveContent: Bool {
        switch self {
        case .recordingCompact(let showsControls): showsControls
        case .hiddenRecording: false
        default: true
        }
    }
}

enum NotchPanelMetrics {
    /// The concave joins where the island meets the screen edge, like the
    /// camera housing's own.
    static let shoulder: CGFloat = 8
    /// One side of the camera in the compact recording state.
    static let earWidth: CGFloat = 76

    static func mode(
        for phase: MeetingPhase,
        showsCaptions: Bool,
        panelMode: MeetingPanelMode,
        isHidden: Bool = false,
        detectionPromptIsCompact: Bool = false,
        isHovering: Bool = false
    ) -> NotchIslandMode {
        switch phase {
        case .idle: return .idle
        case .detected: return .detected(compact: detectionPromptIsCompact)
        case .recording:
            if isHidden { return .hiddenRecording }
            return showsCaptions
                ? .recordingExpanded(panelMode)
                : .recordingCompact(showsControls: isHovering)
        case .processing: return .processing
        case .completed: return .completed
        case .failed: return .failed
        }
    }

    /// The island below the menu bar band, excluding its shoulders.
    static func bodySize(
        for mode: NotchIslandMode,
        cameraHousingWidth: CGFloat = 0
    ) -> CGSize {
        let ears = max(cameraHousingWidth + 2 * earWidth, 176)
        switch mode {
        case .idle:
            return CGSize(width: 320, height: 50)
        case .detected(let compact):
            return compact
                ? CGSize(width: 236, height: 44)
                : CGSize(width: 420, height: 60)
        case .recordingCompact(let showsControls):
            // At rest nothing hangs below the menu bar. The shelf is tall
            // enough for 30pt controls, the app's own hit-target floor.
            return showsControls
                ? CGSize(width: max(ears, 292), height: 50)
                : CGSize(width: ears, height: 0)
        case .recordingExpanded(let panelMode):
            return CGSize(width: 680, height: panelMode == .notes ? 212 : 190)
        case .hiddenRecording:
            return CGSize(width: 86, height: 0)
        case .processing:
            return CGSize(width: 460, height: 58)
        case .completed:
            return CGSize(width: 452, height: 58)
        case .failed:
            return CGSize(width: 560, height: 72)
        }
    }

    static func bodySize(
        for phase: MeetingPhase,
        showsCaptions: Bool,
        panelMode: MeetingPanelMode,
        isHidden: Bool = false,
        detectionPromptIsCompact: Bool = false,
        isHovering: Bool = false,
        cameraHousingWidth: CGFloat = 0
    ) -> CGSize {
        bodySize(
            for: mode(
                for: phase,
                showsCaptions: showsCaptions,
                panelMode: panelMode,
                isHidden: isHidden,
                detectionPromptIsCompact: detectionPromptIsCompact,
                isHovering: isHovering
            ),
            cameraHousingWidth: cameraHousingWidth
        )
    }

    static func bottomRadius(for mode: NotchIslandMode) -> CGFloat {
        switch mode {
        case .recordingCompact(let showsControls): showsControls ? 22 : 12
        case .recordingExpanded: 30
        case .hiddenRecording: 8
        case .detected(let compact): compact ? 20 : 24
        default: 24
        }
    }

    /// Transparent room around a floating island for its shadow. Kept to the
    /// states that float, because this band still takes clicks.
    static func stageMargins(for mode: NotchIslandMode) -> (horizontal: CGFloat, bottom: CGFloat) {
        mode.floatsAboveContent ? (18, 24) : (0, 0)
    }
}

@MainActor
final class NotchPanelCoordinator {
    private let panel: NookTopPanel
    private let meeting: MeetingCoordinator
    private let geometry = NotchPanelGeometry()
    private var cancellables: Set<AnyCancellable> = []
    private var hideTask: Task<Void, Never>?
    /// The fold-and-reappear step when the island moves beside the camera.
    /// Separate from `hideTask`, which phase changes cancel as a matter of
    /// course.
    private var choreographyTask: Task<Void, Never>?
    private var layoutGeneration = 0
    private var lastLayoutMode: NotchIslandMode?

    init(meeting: MeetingCoordinator) {
        self.meeting = meeting
        self.panel = NookTopPanel(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        let host = NSHostingController(
            rootView: NotchPanelView()
                .environmentObject(meeting)
                .environmentObject(geometry)
        )
        // The window is a stage sized by `updateLayout`. SwiftUI must never
        // resize it to fit the island, or the stage would chase the spring.
        host.sizingOptions = []
        panel.contentViewController = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        // `isFloatingPanel` resets an NSPanel to the ordinary floating level.
        // Apply the status-bar level afterwards so the edge surface remains
        // above the menu bar instead of being composited behind it.
        panel.level = .statusBar
        panel.becomesKeyOnlyIfNeeded = true
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.identifier = NSUserInterfaceItemIdentifier("nook.notchPanel")

        // AppModel is first resolved while SwiftUI is constructing the menu-bar
        // scene. Resizing an NSHostingController-backed panel synchronously from
        // that graph update is re-entrant and aborts on newer macOS builds.
        // Install observers after the initial scene transaction has completed.
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.startObserving()
        }
    }

    func show() {
        hideTask?.cancel()
        geometry.isTucking = false
        let wasVisible = panel.isVisible
        if !wasVisible, shouldAnimate {
            geometry.revealProgress = 0
        } else {
            geometry.revealProgress = 1
        }
        updateLayout(animated: wasVisible)
        panel.orderFrontRegardless()
        if case .completed = meeting.phase {
            scheduleCompletionReset()
        } else if case .detected = meeting.phase {
            scheduleDetectionCollapse()
        }

        guard !wasVisible, shouldAnimate else { return }
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, self.panel.isVisible else { return }
            // The island grows out of the camera housing rather than fading
            // in over it.
            withAnimation(NookMotion.morph) {
                self.geometry.revealProgress = 1
            }
        }
    }

    func hide() {
        hideTask?.cancel()
        guard panel.isVisible, shouldAnimate else {
            geometry.revealProgress = 1
            geometry.isTucking = false
            panel.orderOut(nil)
            return
        }
        hideTask = Task { [weak self] in
            await self?.tuckAway()
        }
    }

    /// Folds the island back into the camera housing with whatever it was
    /// showing, then takes the panel off screen.
    private func tuckAway() async {
        geometry.isTucking = true
        withAnimation(NookMotion.tuck) {
            geometry.revealProgress = 0
        }
        try? await Task.sleep(for: .milliseconds(380))
        guard !Task.isCancelled else { return }
        panel.orderOut(nil)
        geometry.revealProgress = 1
        geometry.isTucking = false
    }

    func showLaunchConfirmation() {
        guard case .idle = meeting.phase else { return }
        show()
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3.6))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func makeInteractive() {
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func startObserving() {
        Publishers.CombineLatest4(
            meeting.$phase.removeDuplicates(),
            meeting.$showLiveCaptions.removeDuplicates(),
            meeting.$panelMode.removeDuplicates(),
            meeting.$topPanelHidden.removeDuplicates()
        )
        .sink { [weak self] phase, captions, panelMode, isHidden in
            self?.phaseDidChange(
                phase,
                showsCaptions: captions,
                panelMode: panelMode,
                isHidden: isHidden
            )
        }
        .store(in: &cancellables)

        // The shelf grows the window first and shrinks it after the shape
        // has settled, like every other change of size.
        geometry.$isHovering
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] isHovering in
                guard let self, self.panel.isVisible, !self.geometry.isTucking else { return }
                self.updateLayout(animated: true, isHovering: isHovering)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(
            for: NSApplication.didChangeScreenParametersNotification
        )
        .sink { [weak self] _ in
            Task { @MainActor in
                self?.updateLayout(animated: false)
            }
        }
        .store(in: &cancellables)
    }

    private func phaseDidChange(
        _ phase: MeetingPhase,
        showsCaptions: Bool,
        panelMode: MeetingPanelMode,
        isHidden: Bool
    ) {
        // Every phase change starts a fresh prompt or ends one, so a prompt
        // that collapsed never hands its size to the next.
        geometry.detectionPromptIsCompact = false
        if case .idle = phase, panel.isVisible {
            // Going away: keep the current frame and content and fold them
            // into the notch together, rather than first reshaping into an
            // idle card nobody asked to see.
            hideTask?.cancel()
            guard shouldAnimate else {
                panel.orderOut(nil)
                return
            }
            hideTask = Task { [weak self] in
                await self?.tuckAway()
            }
            return
        }
        geometry.isTucking = false
        updateLayout(
            animated: panel.isVisible,
            phase: phase,
            showsCaptions: showsCaptions,
            panelMode: panelMode,
            isHidden: isHidden
        )

        if case .detected = phase {
            // Key focus, when Nook already has the user's attention. Never
            // activation: detection fires while someone is joining a meeting,
            // and taking the front from that window for a prompt they did not
            // ask for is the opposite of glanceable. Anyone not in Nook
            // answers with the pointer, the menu bar, or the notification.
            if DetectionPromptPolicy.takesKeyFocus(
                applicationIsActive: NSApp.isActive
            ) {
                panel.makeKeyAndOrderFront(nil)
            }
        }

        if case .detected = phase, panel.isVisible {
            scheduleDetectionCollapse()
        } else if case .idle = phase {
            // Idle owns the delayed exit below.
        } else {
            hideTask?.cancel()
        }

        if case .completed = phase, panel.isVisible {
            scheduleCompletionReset()
        }

    }

    private func updateLayout(
        animated: Bool,
        phase: MeetingPhase? = nil,
        showsCaptions: Bool? = nil,
        panelMode: MeetingPanelMode? = nil,
        isHidden: Bool? = nil,
        isHovering: Bool? = nil
    ) {
        guard let screen = targetScreen else { return }
        updateGeometry(for: screen)

        let resolvedPhase = phase ?? meeting.phase
        let resolvedHidden = isHidden ?? meeting.topPanelHidden
        let mode = NotchPanelMetrics.mode(
            for: resolvedPhase,
            showsCaptions: showsCaptions ?? meeting.showLiveCaptions,
            panelMode: panelMode ?? meeting.panelMode,
            isHidden: resolvedHidden,
            detectionPromptIsCompact: geometry.detectionPromptIsCompact,
            isHovering: isHovering ?? geometry.isHovering
        )
        let bodySize = NotchPanelMetrics.bodySize(
            for: mode,
            cameraHousingWidth: geometry.cameraHousingWidth
        )
        let margins = NotchPanelMetrics.stageMargins(for: mode)
        let scale = max(1, screen.backingScaleFactor)
        let islandWidth = min(bodySize.width, geometry.maximumPanelWidth)
        let stageWidth = mode == .hiddenRecording
            ? islandWidth
            : islandWidth + 2 * (NotchPanelMetrics.shoulder + margins.horizontal)
        let size = NSSize(
            width: pixelAligned(stageWidth, scale: scale),
            height: pixelAligned(
                bodySize.height + geometry.topInset + margins.bottom,
                scale: scale
            )
        )
        #if DEBUG
        if mode == .hiddenRecording {
            NookDebugLog.write(
                "[panel] hidden indicator: screen=\(screen.frame) "
                    + "safeTop=\(screen.safeAreaInsets.top) "
                    + "topInset=\(geometry.topInset) "
                    + "housing=\(geometry.cameraHousingWidth) "
                    + "size=\(size) "
                    + "auxLeft=\(String(describing: screen.auxiliaryTopLeftArea)) "
                    + "auxRight=\(String(describing: screen.auxiliaryTopRightArea))"
            )
        }
        #endif

        let frame = NSRect(
            x: pixelAligned(
                hiddenIndicatorOriginX(
                    for: screen,
                    size: size,
                    phase: resolvedPhase,
                    isHidden: resolvedHidden
                ),
                scale: scale
            ),
            y: pixelAligned(
                screen.frame.maxY - size.height,
                scale: scale
            ),
            width: size.width,
            height: size.height
        )
        layoutGeneration += 1
        let generation = layoutGeneration
        let previousMode = lastLayoutMode
        lastLayoutMode = mode

        // The window is only a stage; SwiftUI animates the island inside it.
        // Growing first gives the shape room to spring outward, and the
        // window shrinks once the shape has settled, so no frame animation
        // ever runs on a different curve from the shape.
        guard animated, shouldAnimate, panel.isVisible else {
            panel.setFrame(frame, display: true)
            return
        }

        // Hiding moves the island off the camera's centre line, which no
        // single frame can span. Fold into the housing, move, then peek out
        // beside it; restoring runs the same steps the other way.
        if mode == .hiddenRecording || previousMode == .hiddenRecording,
           mode != previousMode {
            choreographyTask?.cancel()
            choreographyTask = Task { @MainActor [weak self] in
                guard let self else { return }
                self.geometry.isTucking = true
                withAnimation(NookMotion.tuck) {
                    self.geometry.revealProgress = 0
                }
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled, generation == self.layoutGeneration else { return }
                self.panel.setFrame(frame, display: true)
                self.geometry.isTucking = false
                withAnimation(NookMotion.morph) {
                    self.geometry.revealProgress = 1
                }
            }
            return
        }

        let current = panel.frame
        let stage = NSRect(
            x: min(current.minX, frame.minX),
            y: min(current.minY, frame.minY),
            width: max(current.maxX, frame.maxX) - min(current.minX, frame.minX),
            height: max(current.maxY, frame.maxY) - min(current.minY, frame.minY)
        )
        panel.setFrame(stage, display: true)
        guard stage != frame else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(NookMotion.morphSettleSeconds))
            guard let self, generation == self.layoutGeneration else { return }
            self.panel.setFrame(frame, display: true)
        }
    }

    private func hiddenIndicatorOriginX(
        for screen: NSScreen,
        size: NSSize,
        phase: MeetingPhase,
        isHidden: Bool
    ) -> CGFloat {
        guard
            phase.isRecording,
            isHidden,
            geometry.cameraHousingWidth > 1
        else {
            return screen.frame.midX - size.width / 2
        }
        return screen.frame.midX + geometry.cameraHousingWidth / 2
    }

    private var targetScreen: NSScreen? {
        if panel.isVisible, let screen = panel.screen {
            return screen
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    private func scheduleCompletionReset() {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4.8))
            guard !Task.isCancelled, let self else { return }
            self.meeting.resetStatus()
        }
    }

    /// Shrinks the consent prompt once it has been on screen long enough.
    ///
    /// It used to disappear after eight seconds. Answering "not now" on the
    /// user's behalf is what that amounted to: they looked away, the meeting
    /// went unrecorded, and nothing was left to say Nook had ever offered. The
    /// prompt now stays until it is answered or the meeting window closes,
    /// which puts the phase back to idle and takes the panel with it. All that
    /// expires is the space it takes up.
    private func scheduleDetectionCollapse() {
        hideTask?.cancel()
        geometry.detectionPromptIsCompact = false
        hideTask = Task { [weak self] in
            try? await Task.sleep(
                for: .seconds(DetectionPromptPolicy.expandedSeconds)
            )
            guard
                !Task.isCancelled,
                let self,
                case .detected = self.meeting.phase
            else {
                return
            }

            if self.shouldAnimate {
                withAnimation(NookMotion.morph) {
                    self.geometry.detectionPromptIsCompact = true
                }
            } else {
                self.geometry.detectionPromptIsCompact = true
            }
            self.updateLayout(animated: self.shouldAnimate)
        }
    }

    private var shouldAnimate: Bool {
        !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func updateGeometry(for screen: NSScreen) {
        let visibleMenuBarHeight = max(
            0,
            screen.frame.maxY - screen.visibleFrame.maxY
        )
        geometry.topInset = max(
            NSStatusBar.system.thickness,
            screen.safeAreaInsets.top,
            visibleMenuBarHeight
        )
        geometry.maximumPanelWidth = max(
            440,
            min(680, screen.frame.width - 48)
        )
        if let leftArea = screen.auxiliaryTopLeftArea,
           let rightArea = screen.auxiliaryTopRightArea {
            geometry.cameraHousingWidth = max(
                0,
                min(
                    rightArea.minX - leftArea.maxX,
                    geometry.maximumPanelWidth - 320
                )
            )
        } else {
            geometry.cameraHousingWidth = 0
        }
    }

    private func pixelAligned(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        (value * scale).rounded() / scale
    }
}

private final class NookTopPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    override func constrainFrameRect(
        _ frameRect: NSRect,
        to screen: NSScreen?
    ) -> NSRect {
        // AppKit normally keeps windows below the menu bar, even when their
        // requested frame is anchored to NSScreen.frame.maxY. Nook is an
        // intentional screen-edge surface, so preserve the coordinator's
        // absolute display coordinates instead of snapping to visibleFrame.
        frameRect
    }
}
