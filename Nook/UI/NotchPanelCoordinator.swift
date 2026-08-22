import AppKit
import Combine
import SwiftUI

@MainActor
final class NotchPanelGeometry: ObservableObject {
    @Published var topInset: CGFloat = NSStatusBar.system.thickness
    @Published var revealProgress: CGFloat = 1
    @Published var maximumPanelWidth: CGFloat = 720
    @Published var cameraHousingWidth: CGFloat = 0
}

enum NotchPanelMetrics {
    static func bodySize(
        for phase: MeetingPhase,
        showsCaptions: Bool,
        panelMode: MeetingPanelMode,
        isHidden: Bool = false
    ) -> CGSize {
        if phase.isRecording, isHidden {
            return CGSize(width: 86, height: 0)
        }

        switch phase {
        case .idle:
            return CGSize(width: 336, height: 54)
        case .detected:
            return CGSize(width: 360, height: 48)
        case .recording:
            guard showsCaptions else {
                return CGSize(width: 316, height: 38)
            }
            switch panelMode {
            case .transcript:
                return CGSize(width: 680, height: 190)
            case .summary:
                return CGSize(width: 680, height: 190)
            case .notes:
                return CGSize(width: 680, height: 204)
            }
        case .processing:
            return CGSize(width: 424, height: 72)
        case .completed:
            return CGSize(width: 440, height: 76)
        case .failed:
            return CGSize(width: 584, height: 76)
        }
    }
}

@MainActor
final class NotchPanelCoordinator {
    private let panel: NookTopPanel
    private let meeting: MeetingCoordinator
    private let geometry = NotchPanelGeometry()
    private var cancellables: Set<AnyCancellable> = []
    private var hideTask: Task<Void, Never>?
    private var layoutGeneration = 0

    init(meeting: MeetingCoordinator) {
        self.meeting = meeting
        self.panel = NookTopPanel(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.contentViewController = NSHostingController(
            rootView: NotchPanelView()
                .environmentObject(meeting)
                .environmentObject(geometry)
        )
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
            scheduleDetectionHide()
        }

        guard !wasVisible, shouldAnimate else { return }
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, self.panel.isVisible else { return }
            withAnimation(
                .timingCurve(0.16, 1, 0.30, 1, duration: 0.36)
            ) {
                self.geometry.revealProgress = 1
            }
        }
    }

    func hide() {
        hideTask?.cancel()
        guard panel.isVisible, shouldAnimate else {
            geometry.revealProgress = 1
            panel.orderOut(nil)
            return
        }

        withAnimation(.easeIn(duration: 0.16)) {
            geometry.revealProgress = 0
        }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, let self else { return }
            self.panel.orderOut(nil)
            self.geometry.revealProgress = 1
        }
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
        updateLayout(
            animated: panel.isVisible,
            phase: phase,
            showsCaptions: showsCaptions,
            panelMode: panelMode,
            isHidden: isHidden
        )

        if case .detected = phase {
            // The consent prompt is the one decision the user must be able to
            // answer without reaching for the pointer, and its Return and Esc
            // shortcuts only fire while Nook is active. Taking focus for this
            // moment matches what a macOS dialog does; recording surfaces
            // stay non-activating.
            makeInteractive()
        }

        if case .detected = phase, panel.isVisible {
            scheduleDetectionHide()
        } else if case .idle = phase {
            // Idle owns the delayed exit below.
        } else {
            hideTask?.cancel()
        }

        if case .completed = phase, panel.isVisible {
            scheduleCompletionReset()
        }

        if case .idle = phase, panel.isVisible {
            hideTask?.cancel()
            hideTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled, let self else { return }
                if self.shouldAnimate {
                    withAnimation(.easeIn(duration: 0.16)) {
                        self.geometry.revealProgress = 0
                    }
                    try? await Task.sleep(for: .milliseconds(180))
                }
                guard !Task.isCancelled else { return }
                self.panel.orderOut(nil)
                self.geometry.revealProgress = 1
            }
        }
    }

    private func updateLayout(
        animated: Bool,
        phase: MeetingPhase? = nil,
        showsCaptions: Bool? = nil,
        panelMode: MeetingPanelMode? = nil,
        isHidden: Bool? = nil
    ) {
        guard let screen = targetScreen else { return }
        updateGeometry(for: screen)

        let resolvedPhase = phase ?? meeting.phase
        let resolvedHidden = isHidden ?? meeting.topPanelHidden
        let bodySize = NotchPanelMetrics.bodySize(
            for: resolvedPhase,
            showsCaptions: showsCaptions ?? meeting.showLiveCaptions,
            panelMode: panelMode ?? meeting.panelMode,
            isHidden: resolvedHidden
        )
        let scale = max(1, screen.backingScaleFactor)
        let resolvedWidth = pixelAligned(
            min(bodySize.width, geometry.maximumPanelWidth),
            scale: scale
        )
        let size = NSSize(
            width: resolvedWidth,
            height: pixelAligned(
                bodySize.height + geometry.topInset,
                scale: scale
            )
        )
        #if DEBUG
        if resolvedHidden, resolvedPhase.isRecording {
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

        guard
            animated,
            shouldAnimate
        else {
            panel.setFrame(frame, display: true)
        #if DEBUG
        if resolvedHidden, resolvedPhase.isRecording {
            NookDebugLog.write("[panel] applied frame: \(panel.frame) visible=\(panel.isVisible)")
        }
        #endif
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.32
            context.timingFunction = CAMediaTimingFunction(
                controlPoints: 0.16,
                1,
                0.30,
                1
            )
            panel.animator().setFrame(frame, display: true)
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, generation == self.layoutGeneration else {
                    return
                }
                // End every interrupted resize on the exact same screen-centre
                // anchor, including half-point Retina coordinates.
                self.panel.setFrame(frame, display: true)
            }
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

    private func scheduleDetectionHide() {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard
                !Task.isCancelled,
                let self,
                case .detected = self.meeting.phase
            else {
                return
            }

            if self.shouldAnimate {
                withAnimation(.easeIn(duration: 0.16)) {
                    self.geometry.revealProgress = 0
                }
                try? await Task.sleep(for: .milliseconds(180))
            }

            guard !Task.isCancelled else { return }
            self.panel.orderOut(nil)
            self.geometry.revealProgress = 1
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
