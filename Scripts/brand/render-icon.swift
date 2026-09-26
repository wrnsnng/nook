import AppKit
import CoreGraphics

// Nook app icon, drawn on Apple's 1024 macOS grid.
//
//   swiftc -O Scripts/brand/render-icon.swift -o /tmp/render-icon
//   /tmp/render-icon <out.png> [size]
//
// Sizes of 40 px and below draw simplified artwork (three bars, one line), as
// Apple's own small icons do. AppIcon.appiconset and both Brand masters are
// produced by this file; edit here rather than the PNGs.
let args = CommandLine.arguments
let out = args[1]
let size = args.count > 2 ? Int(args[2])! : 1024
let S = CGFloat(size) / 1024

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: a
    )
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!
// Work in a top-left, 1024-unit coordinate space.
ctx.translateBy(x: 0, y: CGFloat(size))
ctx.scaleBy(x: S, y: -S)

// Apple's tile is close to a superellipse; n = 5 matches its corner mass.
func squirclePath(_ r: CGRect, n: CGFloat = 5) -> CGPath {
    let p = CGMutablePath()
    let cx = r.midX, cy = r.midY, a = r.width / 2, b = r.height / 2
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = cx + a * copysign(pow(abs(c), 2 / n), c)
        let y = cy + b * copysign(pow(abs(s), 2 / n), s)
        if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
    }
    p.closeSubpath()
    return p
}

let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let squircle = squirclePath(body)
let small = size <= 40

// Drop shadow under the tile, as Apple's template has.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10 * 1), blur: 28, color: rgb(0x000000, 0.35))
ctx.addPath(squircle)
ctx.setFillColor(rgb(0x061014))
ctx.fillPath()
ctx.restoreGState()

// Tile background: deep ink, a touch of lagoon at the top.
ctx.saveGState()
ctx.addPath(squircle)
ctx.clip()
let bg = CGGradient(colorsSpace: space, colors: [rgb(0x12302F), rgb(0x0A1B1E), rgb(0x05090C)] as CFArray, locations: [0, 0.45, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])

// The glow the island casts downward, like its rim light.
let glow = CGGradient(colorsSpace: space, colors: [rgb(0x4ADBC6, 0.42), rgb(0x4ADBC6, 0.10), rgb(0x4ADBC6, 0)] as CFArray, locations: [0, 0.45, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 300), startRadius: 0, endCenter: CGPoint(x: 512, y: 300), endRadius: 470, options: [])

// Faint top sheen so the tile reads as glass, not flat paint.
let sheen = CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF, 0.10), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(sheen, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 420), options: [])

// The island hanging from the top edge, with concave shoulders.
let iw: CGFloat = small ? 520 : 420, ih: CGFloat = small ? 250 : 190, shoulder: CGFloat = 30, ir: CGFloat = small ? 96 : 76
let il = 512 - iw / 2, irt = 512 + iw / 2, top: CGFloat = 100, bottom = top + ih
let island = CGMutablePath()
island.move(to: CGPoint(x: il - shoulder, y: top - 4))
island.addLine(to: CGPoint(x: il - shoulder, y: top))
island.addQuadCurve(to: CGPoint(x: il, y: top + shoulder), control: CGPoint(x: il, y: top))
island.addLine(to: CGPoint(x: il, y: bottom - ir))
island.addCurve(to: CGPoint(x: il + ir, y: bottom), control1: CGPoint(x: il, y: bottom - ir * 0.38), control2: CGPoint(x: il + ir * 0.38, y: bottom))
island.addLine(to: CGPoint(x: irt - ir, y: bottom))
island.addCurve(to: CGPoint(x: irt, y: bottom - ir), control1: CGPoint(x: irt - ir * 0.38, y: bottom), control2: CGPoint(x: irt, y: bottom - ir * 0.38))
island.addLine(to: CGPoint(x: irt, y: top + shoulder))
island.addQuadCurve(to: CGPoint(x: irt + shoulder, y: top), control: CGPoint(x: irt, y: top))
island.addLine(to: CGPoint(x: irt + shoulder, y: top - 4))
island.closeSubpath()
ctx.addPath(island)
ctx.setFillColor(rgb(0x000000))
ctx.fillPath()

// Rim light along the island's lower edge.
let rim = CGMutablePath()
rim.move(to: CGPoint(x: il + 3, y: bottom - ir - 20))
rim.addLine(to: CGPoint(x: il + 3, y: bottom - ir))
rim.addCurve(to: CGPoint(x: il + ir, y: bottom - 3), control1: CGPoint(x: il + 3, y: bottom - ir * 0.38), control2: CGPoint(x: il + ir * 0.38, y: bottom - 3))
rim.addLine(to: CGPoint(x: irt - ir, y: bottom - 3))
rim.addCurve(to: CGPoint(x: irt - 3, y: bottom - ir), control1: CGPoint(x: irt - ir * 0.38, y: bottom - 3), control2: CGPoint(x: irt - 3, y: bottom - ir * 0.38))
rim.addLine(to: CGPoint(x: irt - 3, y: bottom - ir - 20))
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 22, color: rgb(0x4ADBC6, 0.9))
ctx.addPath(rim)
ctx.setLineWidth(5)
ctx.setLineCap(.round)
ctx.replacePathWithStrokedPath()
ctx.clip()
let rimGradient = CGGradient(colorsSpace: space, colors: [rgb(0x4ADBC6, 0), rgb(0xA6F2E4, 1), rgb(0x4ADBC6, 0)] as CFArray, locations: [0, 0.5, 1])!
ctx.drawLinearGradient(rimGradient, start: CGPoint(x: il, y: 0), end: CGPoint(x: irt, y: 0), options: [])
ctx.restoreGState()

// The voice: five bars inside the island.
let heights: [CGFloat] = small ? [110, 176, 110] : [58, 102, 140, 94, 62]
let barW: CGFloat = small ? 64 : 30, gap: CGFloat = small ? 40 : 20
let total = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
let cy = top + ih / 2 + 6
for (i, h) in heights.enumerated() {
    let x = 512 - total / 2 + CGFloat(i) * (barW + gap)
    let rect = CGRect(x: x, y: cy - h / 2, width: barW, height: h)
    let bar = CGPath(roundedRect: rect, cornerWidth: barW / 2, cornerHeight: barW / 2, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 18, color: rgb(0x4ADBC6, 0.85))
    ctx.addPath(bar)
    ctx.clip()
    let g = CGGradient(colorsSpace: space, colors: [rgb(0xD4FFF6), rgb(0x4ADBC6)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: rect.minY), end: CGPoint(x: 0, y: rect.maxY), options: [])
    ctx.restoreGState()
    // Re-draw with shadow for glow outside the clip.
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 26, color: rgb(0x4ADBC6, 0.55))
    ctx.addPath(bar)
    ctx.setFillColor(rgb(0x4ADBC6, 0.001))
    ctx.fillPath()
    ctx.restoreGState()
}

// The note being written below: the first line in lagoon, the rest settled.
func line(_ y: CGFloat, _ x0: CGFloat, _ width: CGFloat, _ color: CGColor, glow: Bool = false) {
    let h: CGFloat = small ? 96 : 44
    let r = CGRect(x: x0, y: y - h / 2, width: width, height: h)
    ctx.saveGState()
    if glow { ctx.setShadow(offset: .zero, blur: 20, color: rgb(0x4ADBC6, 0.6)) }
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: h / 2, cornerHeight: h / 2, transform: nil))
    ctx.setFillColor(color)
    ctx.fillPath()
    ctx.restoreGState()
}
if small {
    line(640, 230, 564, rgb(0x6FE3D1), glow: true)
    line(780, 230, 420, rgb(0xFFFFFF, 0.26))
} else {
    let lx: CGFloat = 236
    line(548, lx, 470, rgb(0x6FE3D1), glow: true)
    line(642, lx, 552, rgb(0xFFFFFF, 0.22))
    line(736, lx, 372, rgb(0xFFFFFF, 0.14))
}
ctx.restoreGState()

// Hairline edge so the tile holds its shape on dark wallpapers.
ctx.addPath(squircle)
ctx.setStrokeColor(rgb(0xFFFFFF, 0.10))
ctx.setLineWidth(2)
ctx.strokePath()

let image = ctx.makeImage()!
try! NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: out))
