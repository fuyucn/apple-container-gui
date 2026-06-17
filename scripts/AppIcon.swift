// Renders the Apple Container GUI app icon at an arbitrary pixel size.
//
// Concept: "Window + Container Core" — an original macOS app mark that combines
// a native window frame with a compact container/status core. It deliberately
// avoids embedding Apple's official container logo while preserving a compatible
// visual vocabulary: layered rounded tracks, status dots, metallic surfaces, and
// a calm blue GUI backdrop.
//
// Usage: swift scripts/AppIcon.swift <size> <out.png>
//
// No third-party deps: CoreGraphics + ImageIO ship with the Command Line Tools.
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count == 3, let size = Double(args[1]) else {
    FileHandle.standardError.write("usage: AppIcon.swift <size> <out.png>\n".data(using: .utf8)!)
    exit(2)
}

let outPath = args[2]
let S = CGFloat(size)

let colorSpace = CGColorSpaceCreateDeviceRGB()
let context = CGContext(
    data: nil,
    width: Int(S),
    height: Int(S),
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!

context.setAllowsAntialiasing(true)
context.interpolationQuality = .high

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: r, green: g, blue: b, alpha: a)
}

func fill(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) {
    context.setFillColor(color(r, g, b, a))
}

func stroke(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1, width: CGFloat) {
    context.setStrokeColor(color(r, g, b, a))
    context.setLineWidth(width)
}

func linearGradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: locations)!
}

func drawRounded(_ rect: CGRect, radius: CGFloat, fill: CGColor) {
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    context.addPath(path)
    context.setFillColor(fill)
    context.fillPath()
}

func drawRoundedStroke(_ rect: CGRect, radius: CGFloat, fill: CGColor, stroke: CGColor, width: CGFloat) {
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    context.addPath(path)
    context.setFillColor(fill)
    context.fillPath()
    context.addPath(path)
    context.setStrokeColor(stroke)
    context.setLineWidth(width)
    context.strokePath()
}

func drawShadowedRounded(_ rect: CGRect, radius: CGFloat, fill: CGColor, shadow: CGColor, blur: CGFloat, offset: CGSize) {
    context.saveGState()
    context.setShadow(offset: offset, blur: blur, color: shadow)
    drawRounded(rect, radius: radius, fill: fill)
    context.restoreGState()
}

// MARK: - Background

let iconInset = S * 0.055
let bg = CGRect(x: iconInset, y: iconInset, width: S - 2 * iconInset, height: S - 2 * iconInset)
let bgPath = CGPath(roundedRect: bg, cornerWidth: bg.width * 0.225, cornerHeight: bg.height * 0.225, transform: nil)

context.saveGState()
context.addPath(bgPath)
context.clip()
context.drawLinearGradient(
    linearGradient(
        [
            color(0.08, 0.33, 0.86),
            color(0.08, 0.58, 0.92),
            color(0.14, 0.78, 0.74)
        ],
        [0, 0.55, 1]
    ),
    start: CGPoint(x: bg.minX, y: bg.minY),
    end: CGPoint(x: bg.maxX, y: bg.maxY),
    options: []
)

// Soft top-left shine and lower vignette.
context.drawRadialGradient(
    linearGradient([color(1, 1, 1, 0.42), color(1, 1, 1, 0)], [0, 1]),
    startCenter: CGPoint(x: bg.minX + bg.width * 0.25, y: bg.maxY - bg.height * 0.18),
    startRadius: 0,
    endCenter: CGPoint(x: bg.minX + bg.width * 0.25, y: bg.maxY - bg.height * 0.18),
    endRadius: bg.width * 0.62,
    options: []
)
context.drawRadialGradient(
    linearGradient([color(0.02, 0.06, 0.24, 0.0), color(0.02, 0.06, 0.24, 0.30)], [0.25, 1]),
    startCenter: CGPoint(x: bg.midX, y: bg.midY),
    startRadius: bg.width * 0.18,
    endCenter: CGPoint(x: bg.midX, y: bg.midY),
    endRadius: bg.width * 0.78,
    options: []
)
context.restoreGState()

// MARK: - Window shell

let window = CGRect(x: S * 0.135, y: S * 0.155, width: S * 0.73, height: S * 0.68)
let windowRadius = S * 0.064
let windowPath = CGPath(roundedRect: window, cornerWidth: windowRadius, cornerHeight: windowRadius, transform: nil)

drawShadowedRounded(
    window,
    radius: windowRadius,
    fill: color(0.965, 0.985, 1.0, 0.96),
    shadow: color(0.0, 0.06, 0.20, 0.36),
    blur: S * 0.055,
    offset: CGSize(width: 0, height: -S * 0.030)
)

context.saveGState()
context.addPath(windowPath)
context.clip()

let titleHeight = S * 0.095
let title = CGRect(x: window.minX, y: window.maxY - titleHeight, width: window.width, height: titleHeight)
context.drawLinearGradient(
    linearGradient([color(0.92, 0.95, 0.99), color(0.82, 0.88, 0.96)], [0, 1]),
    start: CGPoint(x: title.minX, y: title.maxY),
    end: CGPoint(x: title.minX, y: title.minY),
    options: []
)
fill(0.96, 0.98, 1.0, 0.70)
context.fill(CGRect(x: window.minX, y: window.minY, width: window.width, height: window.height - titleHeight))
context.restoreGState()

context.addPath(windowPath)
stroke(1, 1, 1, 0.78, width: S * 0.008)
context.strokePath()

let lightSize = S * 0.028
let lightY = title.midY - lightSize / 2
let lights: [(CGFloat, CGFloat, CGFloat)] = [(0.98, 0.33, 0.32), (1.0, 0.72, 0.18), (0.24, 0.78, 0.36)]
for (index, rgb) in lights.enumerated() {
    fill(rgb.0, rgb.1, rgb.2)
    context.fillEllipse(in: CGRect(
        x: window.minX + S * 0.047 + CGFloat(index) * S * 0.050,
        y: lightY,
        width: lightSize,
        height: lightSize
    ))
}

// MARK: - Container core

let body = CGRect(
    x: window.minX + S * 0.090,
    y: window.minY + S * 0.085,
    width: window.width - S * 0.180,
    height: window.height - titleHeight - S * 0.145
)

// A subtle board behind the tracks gives the mark depth without becoming a card.
let board = body.insetBy(dx: S * 0.006, dy: S * 0.006)
drawRoundedStroke(
    board,
    radius: S * 0.050,
    fill: color(0.82, 0.89, 0.99, 0.34),
    stroke: color(1, 1, 1, 0.42),
    width: S * 0.006
)

let trackHeight = S * 0.082
let trackGap = S * 0.046
let trackWidth = body.width * 0.72
let dotDiameter = S * 0.064
let startY = body.midY + trackHeight + trackGap * 0.52

let rowSpecs: [(track: [CGColor], dot: CGColor, xShift: CGFloat)] = [
    ([color(0.92, 0.96, 1.00), color(0.72, 0.82, 0.95)], color(0.16, 0.84, 0.58), -S * 0.010),
    ([color(0.88, 0.92, 0.98), color(0.58, 0.69, 0.86)], color(1.00, 0.72, 0.20), S * 0.018),
    ([color(0.80, 0.86, 0.94), color(0.42, 0.54, 0.72)], color(0.40, 0.70, 1.00), -S * 0.002)
]

for (index, spec) in rowSpecs.enumerated() {
    let y = startY - CGFloat(index) * (trackHeight + trackGap)
    let track = CGRect(
        x: body.minX + S * 0.026 + spec.xShift,
        y: y - trackHeight / 2,
        width: trackWidth,
        height: trackHeight
    )
    let radius = trackHeight / 2
    let path = CGPath(roundedRect: track, cornerWidth: radius, cornerHeight: radius, transform: nil)

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -S * 0.010), blur: S * 0.018, color: color(0.02, 0.08, 0.20, 0.20))
    context.addPath(path)
    context.clip()
    context.drawLinearGradient(
        linearGradient(spec.track, [0, 1]),
        start: CGPoint(x: track.minX, y: track.maxY),
        end: CGPoint(x: track.maxX, y: track.minY),
        options: []
    )
    context.restoreGState()

    context.addPath(path)
    stroke(1, 1, 1, 0.68, width: S * 0.005)
    context.strokePath()

    // Small inset grooves: they read as container rails at 1024 and collapse
    // into texture at smaller sizes.
    let grooveW = S * 0.012
    for n in 0..<5 {
        let gx = track.minX + track.width * (0.18 + CGFloat(n) * 0.105)
        fill(0.30, 0.43, 0.62, 0.16)
        context.fill(CGRect(x: gx, y: track.minY + track.height * 0.22, width: grooveW, height: track.height * 0.56))
    }

    let dotRect = CGRect(
        x: track.maxX + S * 0.040,
        y: y - dotDiameter / 2,
        width: dotDiameter,
        height: dotDiameter
    )
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -S * 0.007), blur: S * 0.015, color: color(0.01, 0.05, 0.18, 0.24))
    context.setFillColor(spec.dot)
    context.fillEllipse(in: dotRect)
    context.restoreGState()
    fill(1, 1, 1, 0.55)
    context.fillEllipse(in: dotRect.insetBy(dx: dotDiameter * 0.20, dy: dotDiameter * 0.20).offsetBy(dx: -dotDiameter * 0.10, dy: dotDiameter * 0.10))
}

// Isometric corner cube: this is the "container" hook that makes the mark ours.
let cubeCenter = CGPoint(x: body.maxX - S * 0.060, y: body.minY + S * 0.078)
let cube = S * 0.120
let top = CGMutablePath()
top.move(to: CGPoint(x: cubeCenter.x, y: cubeCenter.y + cube * 0.58))
top.addLine(to: CGPoint(x: cubeCenter.x + cube * 0.62, y: cubeCenter.y + cube * 0.26))
top.addLine(to: CGPoint(x: cubeCenter.x, y: cubeCenter.y - cube * 0.06))
top.addLine(to: CGPoint(x: cubeCenter.x - cube * 0.62, y: cubeCenter.y + cube * 0.26))
top.closeSubpath()
let left = CGMutablePath()
left.move(to: CGPoint(x: cubeCenter.x - cube * 0.62, y: cubeCenter.y + cube * 0.26))
left.addLine(to: CGPoint(x: cubeCenter.x, y: cubeCenter.y - cube * 0.06))
left.addLine(to: CGPoint(x: cubeCenter.x, y: cubeCenter.y - cube * 0.72))
left.addLine(to: CGPoint(x: cubeCenter.x - cube * 0.62, y: cubeCenter.y - cube * 0.40))
left.closeSubpath()
let right = CGMutablePath()
right.move(to: CGPoint(x: cubeCenter.x, y: cubeCenter.y - cube * 0.06))
right.addLine(to: CGPoint(x: cubeCenter.x + cube * 0.62, y: cubeCenter.y + cube * 0.26))
right.addLine(to: CGPoint(x: cubeCenter.x + cube * 0.62, y: cubeCenter.y - cube * 0.40))
right.addLine(to: CGPoint(x: cubeCenter.x, y: cubeCenter.y - cube * 0.72))
right.closeSubpath()

context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -S * 0.014), blur: S * 0.025, color: color(0.01, 0.06, 0.20, 0.30))
context.addPath(left); context.setFillColor(color(0.20, 0.47, 0.78)); context.fillPath()
context.addPath(right); context.setFillColor(color(0.12, 0.36, 0.70)); context.fillPath()
context.addPath(top); context.setFillColor(color(0.36, 0.74, 0.92)); context.fillPath()
context.restoreGState()

for path in [left, right, top] {
    context.addPath(path)
    context.setStrokeColor(color(1, 1, 1, 0.42))
    context.setLineWidth(S * 0.005)
    context.strokePath()
}

// MARK: - Write PNG

guard let image = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: outPath) as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    exit(1)
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else {
    exit(1)
}
