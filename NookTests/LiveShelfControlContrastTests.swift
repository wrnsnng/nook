import AppKit
import SwiftUI
import Testing
@testable import Nook

@MainActor
struct LiveShelfControlContrastTests {
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
    func liveControlsKeepReadableTextWhileIdleAndPressed(_ variant: Appearance) throws {
        let appearance = try #require(NSAppearance(named: variant.name))
        let appSurfaces: [(String, Color)] = [
            ("paper", NookPalette.paper),
            ("canvas top", NookPalette.canvasTop),
            ("canvas bottom", NookPalette.canvasBottom),
            ("native window", Color(nsColor: .windowBackgroundColor)),
            ("native editor", Color(nsColor: .textBackgroundColor))
        ]

        for isCompact in [false, true] {
            let controls: [(String, LiveShelfControlStyle)] = [
                ("pause and captions", LiveShelfControlStyle(isCompact: isCompact)),
                ("resume", LiveShelfControlStyle(tint: NookPalette.success, isCompact: isCompact)),
                ("finish", LiveShelfControlStyle(
                    tint: NookPalette.danger, isDestructive: true, isCompact: isCompact
                ))
            ]
            for (name, style) in controls {
                let foreground = try resolve(style.foregroundColor, in: appearance)
                // The glass shelf can composite over other windows too. Bound
                // the destructive fill against both extremes, not just canvas.
                let surfaces = style.isDestructive
                    ? appSurfaces + [("black", Color.black), ("white", Color.white)]
                    : appSurfaces
                for isPressed in [false, true] {
                    let fill = try resolve(style.backgroundColor(isPressed: isPressed), in: appearance)
                    for (surfaceName, color) in surfaces {
                        let background = fill.composited(over: try resolve(color, in: appearance))
                        let displayedForeground = foreground.composited(over: background)
                        let ratio = displayedForeground.contrast(against: background)
                        #expect(
                            ratio >= 4.5,
                            "\(variant.rawValue), \(name), compact \(isCompact), pressed \(isPressed), \(surfaceName): \(ratio):1"
                        )
                    }
                }
            }
        }
    }

    @Test(arguments: Appearance.allCases)
    func increasedContrastStrengthensLiveControlBoundaries(_ variant: Appearance) throws {
        let appearance = try #require(NSAppearance(named: variant.name))
        for isDestructive in [false, true] {
            let style = LiveShelfControlStyle(isDestructive: isDestructive)
            let standard = style.outline(contrast: .standard)
            let increased = style.outline(contrast: .increased)
            #expect(increased.width > standard.width)
            #expect(increased.width >= 1)

            for surfaceColor in [NookPalette.paper, NookPalette.canvasTop, NookPalette.canvasBottom] {
                let surface = try resolve(surfaceColor, in: appearance)
                let normalInk = try resolve(Color.primary.opacity(standard.opacity), in: appearance)
                let strongerInk = try resolve(Color.primary.opacity(increased.opacity), in: appearance)
                let normalRatio = normalInk.composited(over: surface).contrast(against: surface)
                let increasedRatio = strongerInk.composited(over: surface).contrast(against: surface)
                #expect(
                    increasedRatio > normalRatio + 0.5,
                    "\(variant.rawValue), destructive \(isDestructive): \(normalRatio):1 to \(increasedRatio):1"
                )
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
