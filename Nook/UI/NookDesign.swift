import AppKit
import SwiftUI

enum NookAppearancePreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: Self { self }

    var label: String {
        switch self {
        case .system: "Auto"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var symbol: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }

    var appKitAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

@MainActor
final class NookAppearanceController: ObservableObject {
    private let persistsSelection: Bool

    @Published var selection: NookAppearancePreference {
        didSet {
            if persistsSelection {
                UserDefaults.standard.set(
                    selection.rawValue,
                    forKey: "appearance"
                )
            }
            apply()
        }
    }

    init(
        initialSelection: NookAppearancePreference? = nil,
        persistsSelection: Bool = true
    ) {
        self.persistsSelection = persistsSelection
        let stored = UserDefaults.standard.string(forKey: "appearance")
        selection = initialSelection
            ?? NookAppearancePreference(rawValue: stored ?? "")
            ?? .system
        apply()
    }

    private func apply() {
        NSApp.appearance = selection.appKitAppearance
    }
}

enum NookPalette {
    /// Nook's single brand accent: calm enough for long meetings, bright enough
    /// to remain legible on both native window backgrounds and the top-edge glass.
    static let accent = adaptive(
        light: NSColor(red: 0.10, green: 0.34, blue: 0.72, alpha: 1),
        dark: NSColor(red: 0.43, green: 0.68, blue: 1.00, alpha: 1)
    )
    static let accentHighlight = adaptive(
        light: NSColor(red: 0.32, green: 0.55, blue: 0.92, alpha: 1),
        dark: NSColor(red: 0.64, green: 0.80, blue: 1.00, alpha: 1)
    )
    /// A deliberately deeper selection color so white sidebar text retains
    /// AA contrast in both active and inactive windows.
    static let sidebarSelection = adaptive(
        light: NSColor(red: 0.07, green: 0.25, blue: 0.54, alpha: 1),
        dark: NSColor(red: 0.10, green: 0.29, blue: 0.58, alpha: 1)
    )

    /// Speaker roles are intentionally variations of the same ink rather than
    /// additional brand colors. The icon and source name carry the distinction;
    /// color is only a redundant cue.
    static let voiceSelf = adaptive(
        light: NSColor(red: 0.22, green: 0.30, blue: 0.43, alpha: 1),
        dark: NSColor(red: 0.66, green: 0.73, blue: 0.84, alpha: 1)
    )
    static let voiceSystem = accent
    static let voiceMixed = adaptive(
        light: NSColor(red: 0.14, green: 0.38, blue: 0.64, alpha: 1),
        dark: NSColor(red: 0.53, green: 0.70, blue: 0.91, alpha: 1)
    )

    static let canvasTop = adaptive(
        light: NSColor(red: 0.982, green: 0.980, blue: 0.974, alpha: 1),
        dark: NSColor(red: 0.112, green: 0.114, blue: 0.120, alpha: 1)
    )
    static let canvasBottom = adaptive(
        light: NSColor(red: 0.958, green: 0.958, blue: 0.952, alpha: 1),
        dark: NSColor(red: 0.080, green: 0.082, blue: 0.087, alpha: 1)
    )
    static let paper = adaptive(
        light: NSColor(red: 0.995, green: 0.993, blue: 0.986, alpha: 1),
        dark: NSColor(red: 0.122, green: 0.124, blue: 0.130, alpha: 1)
    )

    static let success = adaptive(
        light: NSColor(red: 0.12, green: 0.50, blue: 0.24, alpha: 1),
        dark: NSColor(red: 0.40, green: 0.80, blue: 0.50, alpha: 1)
    )
    static let warning = adaptive(
        light: NSColor(red: 0.66, green: 0.36, blue: 0.02, alpha: 1),
        dark: NSColor(red: 1.00, green: 0.68, blue: 0.28, alpha: 1)
    )
    static let danger = adaptive(
        light: NSColor(red: 0.72, green: 0.12, blue: 0.16, alpha: 1),
        dark: NSColor(red: 1.00, green: 0.38, blue: 0.42, alpha: 1)
    )

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? dark
                    : light
            }
        )
    }
}

enum NookType {
    static let micro = Font.caption2
    static let caption = Font.caption
    static let metadata = Font.caption.weight(.medium)
    static let control = Font.callout.weight(.semibold)
    static let body = Font.callout
    static let bodyEmphasized = Font.callout.weight(.semibold)
    static let panelTitle = Font.headline
    static let transcript = Font.body
    static let transcriptEmphasized = Font.body.weight(.semibold)
    static let spoken = Font.title3
    static let spokenEmphasized = Font.title3.weight(.semibold)
    static let sectionTitle = Font.callout.weight(.semibold)
    static let title = Font.system(.title, design: .rounded).weight(.semibold)
    static let largeTitle = Font.system(.largeTitle, design: .rounded)
        .weight(.semibold)
    static let editorialSummary = Font.system(.title3, design: .serif)
    static let code = Font.caption.monospaced()
}

enum NookSpacing {
    static let hairline: CGFloat = 1
    static let xSmall: CGFloat = 4
    static let small: CGFloat = 8
    static let medium: CGFloat = 12
    static let large: CGFloat = 18
}

/// One elapsed-clock format for every surface. Each screen used to grow its
/// own formatter and they disagreed the moment a meeting passed an hour: the
/// menu bar dropped seconds while the panel kept counting minutes past 99.
enum NookElapsedTime {
    /// Minutes and seconds until an hour appears, then hours stay visible
    /// rather than seconds silently disappearing.
    static func clock(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let hours = total / 3_600
        guard hours > 0 else {
            return String(format: "%02d:%02d", total / 60, total % 60)
        }
        return String(
            format: "%d:%02d:%02d",
            hours,
            (total / 60) % 60,
            total % 60
        )
    }

    /// The zero-padded stamp written into a note's Markdown transcript.
    ///
    /// Deliberately not `clock`: every note already on disk carries a
    /// two-digit hour, so the emitter has to keep producing exactly the shape
    /// the parser and those files already agree on. One arithmetic, two
    /// audiences.
    static func stamp(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let hours = total / 3_600
        guard hours > 0 else {
            return String(format: "%02d:%02d", total / 60, total % 60)
        }
        return String(
            format: "%02d:%02d:%02d",
            hours,
            (total / 60) % 60,
            total % 60
        )
    }

    /// A finished duration at minute granularity, for something that is over
    /// and no longer counting. `atLeastAMinute` is for a saved note, where "0m"
    /// would claim a meeting that never happened.
    static func minutes(
        _ interval: TimeInterval,
        atLeastAMinute: Bool = false
    ) -> String {
        var total = max(0, Int(interval)) / 60
        if atLeastAMinute {
            total = max(1, total)
        }
        guard total >= 60 else { return "\(total)m" }
        let remainder = total % 60
        return remainder == 0
            ? "\(total / 60)h"
            : "\(total / 60)h \(remainder)m"
    }

    /// The same clock written out for VoiceOver, where "01:05" is ambiguous.
    ///
    /// Hours are named rather than rolled into the minutes: a two-hour meeting
    /// announced as "125 minutes" sounds like a long workshop is a long call.
    static func spoken(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let hours = total / 3_600
        let minutes = (total / 60) % 60
        let seconds = total % 60

        var parts: [String] = []
        if hours > 0 {
            parts.append("\(hours) \(hours == 1 ? "hour" : "hours")")
        }
        parts.append("\(minutes) \(minutes == 1 ? "minute" : "minutes")")
        parts.append("\(seconds) \(seconds == 1 ? "second" : "seconds")")
        return parts.joined(separator: ", ")
    }
}

enum NookRadius {
    static let control: CGFloat = 8
    static let surface: CGFloat = 14
}

enum NookMotion {
    static let quick = Animation.easeOut(duration: 0.18)
    static let spatial = Animation.timingCurve(
        0.16,
        0.78,
        0.22,
        1,
        duration: 0.40
    )

    /// The two curves the top panel moves on, named here so a surface stops
    /// retyping its own approximation of them. The shape is the token; the
    /// duration stays at the call site because it depends on how far the thing
    /// actually travels, and a 0.12s press wants the same easing as a 0.64s
    /// reveal.
    static func settle(over duration: Double) -> Animation {
        .timingCurve(0.22, 1, 0.36, 1, duration: duration)
    }

    /// The shell curve: used where the panel itself changes size or state,
    /// which needs to start faster than content settling inside it.
    static func glide(over duration: Double) -> Animation {
        .timingCurve(0.16, 1, 0.30, 1, duration: duration)
    }
}

struct NookButtonStyle: ButtonStyle {
    var tint: Color?
    var isProminent = false

    @Environment(\.isEnabled) private var isEnabled
    /// Custom button styles own all of their rendering, so SwiftUI draws no
    /// system focus ring for them. Keyboard users would otherwise have no way
    /// to see which control Return or Space will act on.
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(NookType.control)
            .foregroundStyle(foregroundStyle)
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .background {
                RoundedRectangle(
                    cornerRadius: NookRadius.control,
                    style: .continuous
                )
                    .fill(backgroundStyle(configuration: configuration))
            }
            .overlay {
                RoundedRectangle(
                    cornerRadius: NookRadius.control,
                    style: .continuous
                )
                    .stroke(
                        .primary.opacity(isProminent ? 0.04 : 0.09),
                        lineWidth: 0.6
                    )
            }
            .nookFocusRing(
                RoundedRectangle(
                    cornerRadius: NookRadius.control,
                    style: .continuous
                ),
                isVisible: isFocused
            )
            .contentShape(
                RoundedRectangle(
                    cornerRadius: NookRadius.control,
                    style: .continuous
                )
            )
            .opacity(isEnabled ? 1 : 0.42)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(NookMotion.quick, value: configuration.isPressed)
    }

    private var foregroundStyle: AnyShapeStyle {
        if isProminent {
            return AnyShapeStyle(Color.white)
        }
        if let tint {
            return AnyShapeStyle(tint)
        }
        return AnyShapeStyle(.primary)
    }

    private func backgroundStyle(
        configuration: Configuration
    ) -> AnyShapeStyle {
        if isProminent, let tint {
            return AnyShapeStyle(
                tint.opacity(configuration.isPressed ? 0.78 : 1)
            )
        }
        return AnyShapeStyle(
            .primary.opacity(configuration.isPressed ? 0.13 : 0.055)
        )
    }
}

/// The focus indicator shared by every custom button style.
///
/// Drawn slightly outside the control so it reads as the system ring rather
/// than a border, and strengthened under Increased Contrast where a faint
/// stroke would vanish.
extension View {
    func nookFocusRing<S: Shape>(
        _ shape: S,
        isVisible: Bool
    ) -> some View {
        self.overlay {
            let contrastBoost = NSWorkspace.shared
                .accessibilityDisplayShouldIncreaseContrast
            if isVisible {
                shape
                    .stroke(
                        NookPalette.accent.opacity(contrastBoost ? 1 : 0.85),
                        lineWidth: contrastBoost ? 2 : 1.5
                    )
                    .padding(-3)
            } else {
                shape.stroke(Color.clear, lineWidth: 0)
            }
        }
    }
}

struct NookAmbientBackground: View {
    var body: some View {
        LinearGradient(
            colors: [NookPalette.canvasTop, NookPalette.canvasBottom],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

struct NookMark: View {
    var size: CGFloat = 30

    var body: some View {
        Image(nsImage: Self.brandImage)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .clipShape(
                RoundedRectangle(
                    cornerRadius: size * 0.225,
                    style: .continuous
                )
            )
            .accessibilityLabel("Nook")
    }

    /// Do not use `NSApp.applicationIconImage` here. Launch Services can retain
    /// an older icon for an existing bundle identifier even after an update,
    /// which made About disagree with the app bundle.
    private static let brandImage: NSImage = {
        if
            let url = Bundle.main.url(
                forResource: "NookIconSource-Cobalt",
                withExtension: "png"
            ),
            let image = NSImage(contentsOf: url)
        {
            return image
        }
        return NSApp.applicationIconImage
    }()
}

struct SourceBadge: View {
    let source: TranscriptSegment.Source
    var compact = false

    var body: some View {
        Label(source.label, systemImage: source.symbol)
            .labelStyle(.titleAndIcon)
            .font((compact ? Font.caption2 : Font.caption).weight(.medium))
            .foregroundStyle(.secondary)
            .symbolRenderingMode(.monochrome)
            .accessibilityLabel(source.label)
    }
}

struct RecordingWaveform: View {
    let level: Double
    var isActive = true
    var barCount = 22
    var minimumHeight: CGFloat = 3

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                let spacing = max(2, size.width / 90)
                let totalSpacing = spacing * CGFloat(max(0, barCount - 1))
                let barWidth = max(1, (size.width - totalSpacing) / CGFloat(barCount))
                let shading = GraphicsContext.Shading.linearGradient(
                    Gradient(colors: [
                        NookPalette.accentHighlight,
                        NookPalette.accent,
                        NookPalette.accentHighlight,
                    ]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: size.width, y: 0)
                )

                for index in 0..<barCount {
                    let height = barHeight(index: index, available: size.height)
                    let x = CGFloat(index) * (barWidth + spacing)
                    let rect = CGRect(
                        x: x,
                        y: (size.height - height) / 2,
                        width: barWidth,
                        height: height
                    )
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: barWidth / 2),
                        with: shading
                    )
                }
            }
        }
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.09),
            value: level
        )
        .accessibilityHidden(true)
    }

    private func barHeight(index: Int, available: CGFloat) -> CGFloat {
        let motion = reduceMotion ? 0 : level * 7.4
        let travel = (sin(motion + Double(index) * 0.78) + 1) / 2
        let counter = (sin(motion * 0.63 - Double(index) * 0.44) + 1) / 2
        let center = Double(barCount - 1) / 2
        let envelope = 1 - min(0.72, abs(Double(index) - center) / max(1, center) * 0.62)
        let energy = isActive ? max(0.075, min(1, level)) : 0.025
        let normalized = energy * (0.38 + travel * 0.44 + counter * 0.18) * envelope
        return max(minimumHeight, min(available, minimumHeight + available * normalized))
    }
}

struct NookMetadataLabel: View {
    let title: String
    let symbol: String
    var tint: Color = .secondary

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(tint)
    }
}

struct NookSectionLabel: View {
    let title: String
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(NookPalette.accent)
                .frame(width: 14)
            Text(title)
                .font(NookType.sectionTitle)
                .foregroundStyle(.primary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A transient notice floating over library and detail surfaces. The severity
/// exists because a failure written into a success banner reads as a
/// confirmation, which is worse than showing nothing.
struct CopyConfirmationBanner: View {
    enum Severity {
        case success
        case failure
        case info
    }

    let message: String
    var severity: Severity = .success

    var body: some View {
        Label(message, systemImage: symbolName)
            .font(.callout.weight(.semibold))
            .foregroundStyle(foregroundStyle)
            .padding(.horizontal, 13)
            .frame(height: 34)
            .background(
                .regularMaterial,
                in: RoundedRectangle(
                    cornerRadius: NookRadius.control,
                    style: .continuous
                )
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: NookRadius.control,
                    style: .continuous
                )
                    .stroke(.primary.opacity(0.09), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
            .accessibilityElement(children: .combine)
    }

    private var symbolName: String {
        switch severity {
        case .success: "checkmark"
        case .failure: "exclamationmark.triangle.fill"
        case .info: "info.circle"
        }
    }

    private var foregroundStyle: Color {
        switch severity {
        case .success: .primary
        case .failure: NookPalette.danger
        case .info: .secondary
        }
    }
}

struct SoftDivider: View {
    var body: some View {
        Rectangle()
            .fill(.primary.opacity(0.09))
            .frame(height: 0.5)
            .accessibilityHidden(true)
    }
}

/// The marker for an unordered list of quoted lines: key points, prep
/// highlights, anything lifted out of a note.
///
/// Deliberately not a number and not a check. Numbers implied a ranking the
/// summary never claimed, and a check implied the line was something the user
/// had completed, which is what the action-item boxes mean two sections lower.
struct NookBullet: View {
    var body: some View {
        Circle()
            .fill(NookPalette.accent)
            .frame(width: 4, height: 4)
            // Keeps the bullet on the first line's optical centre, close
            // enough to its line to read as belonging to it.
            .frame(width: 10, height: 14, alignment: .leading)
            .accessibilityHidden(true)
    }
}

extension TranscriptSegment.Source {
    var nookTint: Color {
        switch self {
        case .microphone:
            NookPalette.voiceSelf
        case .system:
            NookPalette.voiceSystem
        case .mixed:
            NookPalette.voiceMixed
        }
    }
}
