import AppKit
import SwiftUI
import Testing
@testable import Nook

@MainActor
struct NookDesignContrastTests {
    enum Appearance: String, CaseIterable, Sendable {
        case light, dark, highContrastLight, highContrastDark

        var name: NSAppearance.Name {
            switch self {
            case .light: .aqua
            case .dark: .darkAqua
            case .highContrastLight: .accessibilityHighContrastAqua
            case .highContrastDark: .accessibilityHighContrastDarkAqua
            }
        }
    }

    @Test(arguments: Appearance.allCases)
    func enabledProminentButtonsKeepReadableTextWhileIdleAndPressed(_ variant: Appearance) throws {
        let appearance = try #require(NSAppearance(named: variant.name))
        let style = NookButtonStyle(tint: NookPalette.accent, isProminent: true)
        let foreground = try resolve(style.foregroundColor, in: appearance)
        let surfaces: [(String, Color)] = [
            ("paper", NookPalette.paper),
            ("canvas top", NookPalette.canvasTop),
            ("canvas bottom", NookPalette.canvasBottom),
            ("native window", Color(nsColor: .windowBackgroundColor)),
            ("native editor", Color(nsColor: .textBackgroundColor)),
            // Bound the pressed alpha composition as well as today's surfaces.
            ("black", .black),
            ("white", .white)
        ]

        for isPressed in [false, true] {
            let fill = try resolve(style.backgroundColor(isPressed: isPressed), in: appearance)
            for (name, color) in surfaces {
                let surface = try resolve(color, in: appearance)
                let background = fill.composited(over: surface)
                let displayedForeground = foreground.composited(over: background)
                let ratio = displayedForeground.contrast(against: background)
                #expect(ratio >= 4.5, "\(variant.rawValue), pressed \(isPressed), \(name): \(ratio):1")
            }
        }
    }

    @Test(arguments: [NookAppearancePreference.light, .dark])
    func anExplicitAppAppearanceResolvesButtonColorsInsideTheOppositeDrawingAppearance(
        _ choice: NookAppearancePreference
    ) throws {
        let appAppearance = try #require(choice.appKitAppearance)
        let ambientAppearance = try #require(NSAppearance(
            named: choice == .light ? .darkAqua : .aqua
        ))
        let style = NookButtonStyle(tint: NookPalette.accent, isProminent: true)
        // Keep the same dynamic color alive across both drawing contexts.
        let foreground = style.foregroundColor
        var overriddenColor: NSColor?
        ambientAppearance.performAsCurrentDrawingAppearance {
            appAppearance.performAsCurrentDrawingAppearance {
                overriddenColor = NSColor(foreground).usingColorSpace(.sRGB)
            }
        }
        let overridden = RGBA(try #require(overriddenColor))
        let directlyResolved = try resolve(foreground, in: appAppearance)
        #expect(abs(overridden.luminance - directlyResolved.luminance) < 0.000_001)
        if choice == .light {
            // The fix must not replace the existing light button's white ink.
            #expect(abs(overridden.luminance - 1) < 0.000_001)
            #expect(abs(overridden.alpha - 1) < 0.000_001)
        } else {
            #expect(overridden.luminance < 0.02)
        }
    }

    @Test
    func reducedMotionKeepsPressedControlsAndSavedStatusAtTheirRestingSize() {
        for isPressed in [false, true] {
            #expect(NookMotion.pressedScale(isPressed: isPressed, reduceMotion: true) == 1)
        }
        #expect(NookMotion.savedStatusScale(reduceMotion: true) == 1)
        #expect(NookMotion.quickAnimation(reduceMotion: true) == nil)
        // The accessibility preference must not remove ordinary feedback for
        // people who have not asked to reduce motion.
        #expect(NookMotion.pressedScale(isPressed: false, reduceMotion: false) == 1)
        #expect(NookMotion.pressedScale(isPressed: true, reduceMotion: false) < 1)
        #expect(NookMotion.savedStatusScale(reduceMotion: false) < 1)
        #expect(NookMotion.quickAnimation(reduceMotion: false) != nil)
    }

    @Test(arguments: PanelPressFeedback.Surface.allCases)
    func reducedMotionPanelControlsStillAcknowledgePressesWithoutMoving(
        _ surface: PanelPressFeedback.Surface
    ) {
        let resting = PanelPressFeedback(surface: surface, isPressed: false, reduceMotion: true)
        let pressed = PanelPressFeedback(surface: surface, isPressed: true, reduceMotion: true)
        let movingResting = PanelPressFeedback(surface: surface, isPressed: false, reduceMotion: false)
        let movingPressed = PanelPressFeedback(surface: surface, isPressed: true, reduceMotion: false)

        #expect(resting.scale == 1)
        #expect(pressed.scale == 1)
        #expect(resting.animation == nil)
        #expect(pressed.animation == nil)
        // The preference must not erase the only visible response to a press.
        #expect(pressed.backgroundOpacity != resting.backgroundOpacity
            || pressed.contentOpacity != resting.contentOpacity)
        #expect(pressed.backgroundOpacity == movingPressed.backgroundOpacity)
        #expect(pressed.contentOpacity == movingPressed.contentOpacity)
        #expect(resting.backgroundOpacity == movingResting.backgroundOpacity)
        #expect(resting.contentOpacity == movingResting.contentOpacity)
        #expect(movingResting.scale == 1)
        #expect(movingPressed.scale < movingResting.scale)
        #expect(movingPressed.animation != nil)
    }

    @Test(arguments: [false, true])
    func increasedContrastStrengthensProminentAndOrdinaryControlEdges(_ isProminent: Bool) throws {
        let standard = NookOutline.button(isProminent: isProminent, contrast: .standard)
        let increased = NookOutline.button(isProminent: isProminent, contrast: .increased)
        #expect(increased.width > standard.width)
        #expect(increased.width >= 1)
        try expectStrongerBoundary(increased, than: standard)
    }

    @Test
    func increasedContrastMakesSectionBoundariesThickerAndMoreVisible() throws {
        let standard = NookOutline.divider(contrast: .standard)
        let increased = NookOutline.divider(contrast: .increased)
        #expect(increased.width > standard.width)
        #expect(increased.width >= 1)
        try expectStrongerBoundary(increased, than: standard)
    }

    private func expectStrongerBoundary(
        _ increased: NookOutline.Metrics, than standard: NookOutline.Metrics
    ) throws {
        for variant in Appearance.allCases {
            let appearance = try #require(NSAppearance(named: variant.name))
            for surfaceColor in [NookPalette.paper, NookPalette.canvasTop, NookPalette.canvasBottom] {
                let surface = try resolve(surfaceColor, in: appearance)
                let normalInk = try resolve(Color.primary.opacity(standard.opacity), in: appearance)
                let strongerInk = try resolve(Color.primary.opacity(increased.opacity), in: appearance)
                let normalRatio = normalInk.composited(over: surface).contrast(against: surface)
                let increasedRatio = strongerInk.composited(over: surface).contrast(against: surface)
                #expect(increasedRatio > normalRatio + 0.5, "\(variant.rawValue): \(normalRatio):1 to \(increasedRatio):1")
            }
        }
    }

    private func resolve(_ color: Color, in appearance: NSAppearance) throws -> RGBA {
        var resolved: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            resolved = NSColor(color).usingColorSpace(.sRGB)
        }
        return RGBA(try #require(resolved))
    }

    private struct RGBA {
        let red: Double
        let green: Double
        let blue: Double
        let alpha: Double

        init(_ color: NSColor) {
            red = Double(color.redComponent)
            green = Double(color.greenComponent)
            blue = Double(color.blueComponent)
            alpha = Double(color.alphaComponent)
        }

        private init(red: Double, green: Double, blue: Double, alpha: Double) {
            self.red = red
            self.green = green
            self.blue = blue
            self.alpha = alpha
        }

        func composited(over background: Self) -> Self {
            let combinedAlpha = alpha + background.alpha * (1 - alpha)
            func component(_ foreground: Double, _ behind: Double) -> Double {
                (foreground * alpha + behind * background.alpha * (1 - alpha)) / combinedAlpha
            }
            return Self(
                red: component(red, background.red),
                green: component(green, background.green),
                blue: component(blue, background.blue), alpha: combinedAlpha
            )
        }

        var luminance: Double {
            func linear(_ component: Double) -> Double {
                component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        }

        func contrast(against other: Self) -> Double {
            (max(luminance, other.luminance) + 0.05) / (min(luminance, other.luminance) + 0.05)
        }
    }
}
