import AppKit
import SwiftUI

/// The small dictation indicator that follows the pointer.
///
/// It shows the recognizer's volatile guess — the text that is still being
/// revised — while only settled text goes into the user's document. Watching
/// words correct themselves here is reassuring; watching them correct
/// themselves inside a Slack message is not.
struct DictationIndicatorView: View {
    let phase: DictationPhase
    /// Most recent first. A short history rather than a single value, so the
    /// meter reads as a travelling waveform instead of a symmetric pulse.
    let levels: [Float]
    let volatileText: String

    var body: some View {
        HStack(spacing: NookSpacing.small) {
            symbol
                .frame(width: 22, alignment: .leading)
            if !label.isEmpty {
                Text(label)
                    .font(NookType.caption)
                    .foregroundStyle(labelColor)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: 280, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
                    .animation(.default, value: label)
            }
        }
        .padding(.leading, NookSpacing.medium)
        .padding(.trailing, NookSpacing.large - 4)
        .padding(.vertical, NookSpacing.small)
        .background(background)
        // Clipping the composed result is what removes the square corners:
        // the material and its border are otherwise free to paint into them.
        .clipShape(.capsule)
        .compositingGroup()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var background: some View {
        ZStack {
            Capsule(style: .continuous)
                .fill(.regularMaterial)
            Capsule(style: .continuous)
                .strokeBorder(borderColor, lineWidth: NookSpacing.hairline)
        }
    }

    private var borderColor: Color {
        switch phase {
        case .failed: NookPalette.warning.opacity(0.5)
        case .refining: NookPalette.accent.opacity(0.45)
        default: NookPalette.accent.opacity(0.28)
        }
    }

    @ViewBuilder
    private var symbol: some View {
        switch phase {
        case .listening, .preparing:
            DictationLevelMeter(levels: levels)
        case .refining:
            DictationPolishingIndicator()
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(NookPalette.warning)
        case .idle:
            EmptyView()
        }
    }

    private var label: String {
        switch phase {
        case .preparing:
            "Listening"
        case .listening:
            volatileText.isEmpty ? "Listening" : volatileText
        case .refining:
            "Polishing"
        case .failed(let message):
            message
        case .idle:
            ""
        }
    }

    private var labelColor: Color {
        switch phase {
        case .failed: NookPalette.warning
        case .listening where !volatileText.isEmpty: .primary
        default: .secondary
        }
    }

    private var accessibilityLabel: String {
        switch phase {
        case .preparing, .listening: "Nook is listening"
        case .refining: "Nook is polishing your dictation"
        case .failed(let message): message
        case .idle: ""
        }
    }
}

/// Bars that carry the last moments of speech across the meter.
///
/// The newest sample enters at the right, so quiet and loud passages visibly
/// travel rather than every bar moving as one — which is what made the earlier
/// version read as a loading spinner rather than a microphone.
private struct DictationLevelMeter: View {
    let levels: [Float]

    private static let barCount = 5
    private static let minimumHeight: CGFloat = 3
    private static let maximumHeight: CGFloat = 15

    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(0..<Self.barCount, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(NookPalette.accent.opacity(opacity(for: index)))
                    .frame(width: 2.5, height: height(for: index))
            }
        }
        .frame(height: Self.maximumHeight)
        .animation(.spring(response: 0.22, dampingFraction: 0.62), value: levels)
    }

    /// Bar 0 is the oldest sample, so it sits at the left and fades out.
    private func height(for index: Int) -> CGFloat {
        let sampleIndex = Self.barCount - 1 - index
        let level = CGFloat(
            sampleIndex < levels.count ? levels[sampleIndex] : 0
        )
        let eased = pow(min(1, max(0, level)), 0.7)
        return Self.minimumHeight
            + (Self.maximumHeight - Self.minimumHeight) * eased
    }

    private func opacity(for index: Int) -> Double {
        0.45 + (0.55 * Double(index) / Double(Self.barCount - 1))
    }
}

/// A quiet travelling shimmer for the rewrite pause.
///
/// The wait is short but not instant, and an indicator that simply froze would
/// read as the feature having failed.
private struct DictationPolishingIndicator: View {
    @State private var phase: CGFloat = 0

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(NookPalette.accent)
                    .frame(width: 4, height: 4)
                    .opacity(opacity(for: index))
            }
        }
        .frame(height: 15)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: false)) {
                phase = 3
            }
        }
    }

    private func opacity(for index: Int) -> Double {
        let distance = abs(phase - CGFloat(index))
        return 0.3 + 0.7 * Double(max(0, 1 - min(1, distance)))
    }
}

/// Hosts the indicator in a borderless panel that tracks the pointer.
@MainActor
final class DictationIndicatorController {
    private var panel: NSPanel?
    private var hosting: NSHostingView<DictationIndicatorView>?
    private var tracker: Timer?
    private var lastPoint: NSPoint = .zero
    private var levels: [Float] = []

    /// How many recent level samples the meter shows.
    private static let levelHistory = 5

    /// Far enough from the pointer that the indicator never sits under it, and
    /// below it so it does not cover the line being typed into.
    private static let cursorOffset = NSPoint(x: 16, y: -34)

    func update(phase: DictationPhase, level: Float, volatileText: String) {
        guard phase != .idle else {
            hide()
            return
        }

        levels.insert(level, at: 0)
        if levels.count > Self.levelHistory {
            levels.removeLast(levels.count - Self.levelHistory)
        }

        show(
            DictationIndicatorView(
                phase: phase,
                levels: levels,
                volatileText: volatileText
            )
        )
    }

    private func show(_ content: DictationIndicatorView) {
        if let hosting {
            hosting.rootView = content
            resizeToFit()
            moveToPointer(force: false)
            return
        }

        let hosting = NSHostingView(rootView: content)
        hosting.wantsLayer = true
        // Without this the hosting view paints its own opaque backing into the
        // corners the capsule leaves empty.
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        self.hosting = hosting

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The system shadow follows the rendered alpha, so it traces the
        // capsule. A hand-drawn shadow traced the layer's square bounds.
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.alphaValue = 0
        // Dictation happens in other people's apps, including full-screen
        // ones, so the indicator has to follow the user everywhere without
        // ever taking key focus away from what they are typing into.
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
        self.panel = panel

        resizeToFit()
        moveToPointer(force: true)
        panel.orderFrontRegardless()
        panel.animator().alphaValue = 1
        startTracking()
    }

    private func hide() {
        stopTracking()
        levels = []
        guard let panel else { return }
        self.panel = nil
        self.hosting = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            panel.animator().alphaValue = 0
        } completionHandler: {
            panel.orderOut(nil)
        }
    }

    private func resizeToFit() {
        guard let panel, let hosting else { return }
        let size = hosting.fittingSize
        guard size.width > 0, size.height > 0 else { return }
        guard panel.frame.size != size else { return }
        panel.setContentSize(size)
    }

    private func startTracking() {
        guard tracker == nil else { return }
        // Polling `NSEvent.mouseLocation` avoids a global event monitor, which
        // would need Accessibility permission just to place a decoration.
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { _ in
            MainActor.assumeIsolated {
                self.moveToPointer(force: false)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        tracker = timer
    }

    private func stopTracking() {
        tracker?.invalidate()
        tracker = nil
    }

    private func moveToPointer(force: Bool) {
        guard let panel else { return }
        let pointer = NSEvent.mouseLocation
        guard force || hypot(
            pointer.x - lastPoint.x,
            pointer.y - lastPoint.y
        ) > 0.5 else {
            return
        }
        lastPoint = pointer

        let size = panel.frame.size
        var origin = NSPoint(
            x: pointer.x + Self.cursorOffset.x,
            y: pointer.y + Self.cursorOffset.y - size.height
        )

        // Keep the whole indicator on the screen the pointer is actually on,
        // flipping it across the pointer rather than letting it clip.
        if let screen = NSScreen.screens.first(where: {
            $0.frame.contains(pointer)
        }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            if origin.x + size.width > visible.maxX {
                origin.x = pointer.x - Self.cursorOffset.x - size.width
            }
            if origin.y < visible.minY {
                origin.y = pointer.y - Self.cursorOffset.y
            }
            origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
            origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        }
        panel.setFrameOrigin(origin)
    }
}
