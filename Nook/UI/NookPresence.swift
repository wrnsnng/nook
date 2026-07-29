import SwiftUI

enum NookPresenceState: Equatable {
    case resting
    case detected
    case listening(level: Double, isPaused: Bool)
    case thinking
    case saved
    case attention

    fileprivate var animatesContinuously: Bool {
        switch self {
        case .listening(_, let isPaused):
            !isPaused
        case .thinking:
            true
        default:
            false
        }
    }

    fileprivate var accessibilityLabel: String {
        switch self {
        case .resting: "Nook is ready"
        case .detected: "Meeting detected"
        case .listening(_, let isPaused):
            isPaused ? "Recording paused" : "Recording"
        case .thinking: "Creating meeting notes"
        case .saved: "Meeting notes saved"
        case .attention: "Nook needs attention"
        }
    }
}

/// Nook's living state mark. Spoken fragments begin as a loose thread, align
/// into written lines, then settle into the speech-seed silhouette when saved.
/// It deliberately stays abstract and silent so it can remain visible during a
/// meeting without becoming a mascot that demands attention.
struct NookPresence: View {
    let state: NookPresenceState
    var size: CGFloat = 48
    var showsSurface = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        TimelineView(
            .animation(
                minimumInterval: 1 / 20,
                paused: reduceMotion || !state.animatesContinuously
            )
        ) { context in
            let time = context.date.timeIntervalSinceReferenceDate

            ZStack {
                if showsSurface {
                    ConversationSeedShape()
                        .fill(surfaceFill)
                        .overlay {
                            ConversationSeedShape()
                                .stroke(
                                    .primary.opacity(
                                        colorScheme == .dark ? 0.11 : 0.07
                                    ),
                                    lineWidth: 0.7
                                )
                        }
                }

                ConversationThread(
                    state: state,
                    time: time,
                    reduceMotion: reduceMotion
                )
                .padding(size * (showsSurface ? 0.22 : 0.08))
            }
        }
        .frame(width: size, height: size)
        .contentTransition(.interpolate)
        .animation(reduceMotion ? nil : NookMotion.spatial, value: state)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.accessibilityLabel)
    }

    private var surfaceFill: AnyShapeStyle {
        switch state {
        case .attention:
            AnyShapeStyle(NookPalette.warning.opacity(0.12))
        case .saved:
            AnyShapeStyle(NookPalette.accent.opacity(0.105))
        default:
            AnyShapeStyle(NookPalette.accent.opacity(0.085))
        }
    }
}

private struct ConversationSeedShape: Shape {
    func path(in rect: CGRect) -> Path {
        let tail = rect.width * 0.13
        let bubbleRect = CGRect(
            x: rect.minX,
            y: rect.minY,
            width: rect.width,
            height: rect.height - tail * 0.72
        )
        let radius = min(bubbleRect.width, bubbleRect.height) * 0.31
        var path = Path(
            roundedRect: bubbleRect,
            cornerRadius: radius,
            style: .continuous
        )

        let tailPath = Path { tailPath in
            tailPath.move(
                to: CGPoint(
                    x: rect.midX + rect.width * 0.12,
                    y: bubbleRect.maxY - 1
                )
            )
            tailPath.addQuadCurve(
                to: CGPoint(
                    x: rect.midX + rect.width * 0.28,
                    y: rect.maxY
                ),
                control: CGPoint(
                    x: rect.midX + rect.width * 0.18,
                    y: rect.maxY - tail * 0.12
                )
            )
            tailPath.addQuadCurve(
                to: CGPoint(
                    x: rect.midX + rect.width * 0.02,
                    y: bubbleRect.maxY - 1
                ),
                control: CGPoint(
                    x: rect.midX + rect.width * 0.15,
                    y: bubbleRect.maxY
                )
            )
            tailPath.closeSubpath()
        }
        path.addPath(tailPath)
        return path
    }
}

private struct ConversationThread: View {
    let state: NookPresenceState
    let time: TimeInterval
    let reduceMotion: Bool

    var body: some View {
        Canvas { context, size in
            switch state {
            case .resting:
                drawResting(in: &context, size: size)
            case .detected:
                drawDetected(in: &context, size: size)
            case .listening(let level, let isPaused):
                drawListening(
                    in: &context,
                    size: size,
                    level: level,
                    isPaused: isPaused
                )
            case .thinking:
                drawThinking(in: &context, size: size)
            case .saved:
                drawSaved(in: &context, size: size)
            case .attention:
                drawAttention(in: &context, size: size)
            }
        }
    }

    private var ink: Color {
        switch state {
        case .attention:
            NookPalette.warning
        default:
            NookPalette.accent
        }
    }

    private func drawResting(
        in context: inout GraphicsContext,
        size: CGSize
    ) {
        let y = size.height * 0.52
        stroke(
            path(from: [
                CGPoint(x: size.width * 0.18, y: y),
                CGPoint(x: size.width * 0.38, y: y - size.height * 0.05),
                CGPoint(x: size.width * 0.62, y: y + size.height * 0.04),
                CGPoint(x: size.width * 0.82, y: y),
            ]),
            in: &context,
            width: max(1.5, size.width * 0.075)
        )
    }

    private func drawDetected(
        in context: inout GraphicsContext,
        size: CGSize
    ) {
        let amplitude: CGFloat = reduceMotion
            ? 0.03
            : 0.03 + CGFloat((sin(time * 3.0) + 1) * 0.018)
        for index in 0..<3 {
            let position = CGFloat(index)
            let y = size.height * (0.34 + position * 0.18)
            let inset = size.width * position * 0.025
            stroke(
                path(from: [
                    CGPoint(x: size.width * 0.16 + inset, y: y),
                    CGPoint(
                        x: size.width * 0.48,
                        y: y - size.height * amplitude
                    ),
                    CGPoint(
                        x: size.width * 0.84 - inset,
                        y: y + size.height * amplitude * 0.4
                    ),
                ]),
                in: &context,
                width: max(1.4, size.width * 0.065),
                opacity: 1 - Double(index) * 0.16
            )
        }
    }

    private func drawListening(
        in context: inout GraphicsContext,
        size: CGSize,
        level: Double,
        isPaused: Bool
    ) {
        let count = 5
        let energy = CGFloat(
            isPaused ? 0.06 : max(0.10, min(1, level))
        )
        let barWidth = size.width * 0.085
        let gap = size.width * 0.085
        let totalWidth = CGFloat(count) * barWidth + CGFloat(count - 1) * gap
        let originX = (size.width - totalWidth) / 2

        for index in 0..<count {
            let wave: CGFloat = reduceMotion || isPaused
                ? 0.34
                : CGFloat(
                    (sin(time * 7.2 + Double(index) * 1.18) + 1) / 2
                )
            let envelope = 1 - abs(CGFloat(index) - 2) * 0.12
            let height = size.height
                * (0.18 + energy * (0.20 + wave * 0.42) * envelope)
            let rect = CGRect(
                x: originX + CGFloat(index) * (barWidth + gap),
                y: (size.height - height) / 2,
                width: barWidth,
                height: height
            )
            context.fill(
                Path(
                    roundedRect: rect,
                    cornerRadius: barWidth / 2,
                    style: .continuous
                ),
                with: .color(ink.opacity(isPaused ? 0.46 : 1))
            )
        }
    }

    private func drawThinking(
        in context: inout GraphicsContext,
        size: CGSize
    ) {
        let progress: CGFloat = reduceMotion
            ? 1
            : CGFloat((sin(time * 2.1) + 1) / 2)
        let widths: [CGFloat] = [0.68, 0.52, 0.60]
        for (index, baseWidth) in widths.enumerated() {
            let variation = index == 1 ? progress * 0.10 : (1 - progress) * 0.06
            let width = size.width * (baseWidth + variation)
            let y = size.height * (0.31 + CGFloat(index) * 0.21)
            let rect = CGRect(
                x: (size.width - width) / 2,
                y: y,
                width: width,
                height: max(1.5, size.height * 0.065)
            )
            context.fill(
                Path(
                    roundedRect: rect,
                    cornerRadius: rect.height / 2,
                    style: .continuous
                ),
                with: .color(ink.opacity(1 - Double(index) * 0.15))
            )
        }
    }

    private func drawSaved(
        in context: inout GraphicsContext,
        size: CGSize
    ) {
        let widths: [CGFloat] = [0.66, 0.54, 0.40]
        for (index, widthFraction) in widths.enumerated() {
            let width = size.width * widthFraction
            let y = size.height * (0.31 + CGFloat(index) * 0.20)
            let rect = CGRect(
                x: size.width * 0.18,
                y: y,
                width: width,
                height: max(1.5, size.height * 0.065)
            )
            context.fill(
                Path(
                    roundedRect: rect,
                    cornerRadius: rect.height / 2,
                    style: .continuous
                ),
                with: .color(ink.opacity(1 - Double(index) * 0.12))
            )
        }
    }

    private func drawAttention(
        in context: inout GraphicsContext,
        size: CGSize
    ) {
        let lineWidth = max(1.6, size.width * 0.075)
        var line = Path()
        line.move(to: CGPoint(x: size.width * 0.50, y: size.height * 0.22))
        line.addLine(to: CGPoint(x: size.width * 0.50, y: size.height * 0.62))
        context.stroke(
            line,
            with: .color(ink),
            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
        )
        context.fill(
            Path(
                ellipseIn: CGRect(
                    x: size.width * 0.46,
                    y: size.height * 0.74,
                    width: size.width * 0.08,
                    height: size.width * 0.08
                )
            ),
            with: .color(ink)
        )
    }

    private func path(from points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        return path
    }

    private func stroke(
        _ path: Path,
        in context: inout GraphicsContext,
        width: CGFloat,
        opacity: Double = 1
    ) {
        context.stroke(
            path,
            with: .color(ink.opacity(opacity)),
            style: StrokeStyle(
                lineWidth: width,
                lineCap: .round,
                lineJoin: .round
            )
        )
    }
}
