import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Renders the MacStats app icon natively at each required pixel size.
// Design space is 1024pt; the context is scaled so every size is drawn as
// vectors rather than downsampled from one master (sharper at 16/32px).

let outDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: srgb, components: [CGFloat(r) / 255, CGFloat(g) / 255, CGFloat(b) / 255, a])!
}

/// Superellipse (|x/a|^n + |y/b|^n = 1) — a close stand-in for Apple's
/// continuous-corner squircle, which AppKit has no API for.
func squirclePath(in rect: CGRect, exponent n: CGFloat = 5.0, samples: Int = 720) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let cx = rect.midX, cy = rect.midY
    for i in 0..<samples {
        let t = CGFloat(i) / CGFloat(samples) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = cx + a * pow(abs(ct), 2 / n) * (ct < 0 ? -1 : 1)
        let y = cy + b * pow(abs(st), 2 / n) * (st < 0 ? -1 : 1)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

func drawIcon(pixels: Int) -> CGImage? {
    guard let ctx = CGContext(data: nil, width: pixels, height: pixels,
                              bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }

    ctx.interpolationQuality = .high
    ctx.setAllowsAntialiasing(true)
    let scale = CGFloat(pixels) / 1024.0
    ctx.scaleBy(x: scale, y: scale)

    // Near-full-bleed tile: macOS 26 re-frames legacy icons inside its own container,
    // so a Big Sur-style 100pt margin renders as a visible tile-inside-a-tile. Keeping
    // our own squircle (macOS <= 15 does not mask) but nearly edge-to-edge suits both.
    let simplified = pixels <= 32
    let inset: CGFloat = simplified ? 14 : 30
    let tile = CGRect(x: inset, y: inset, width: 1024 - inset * 2, height: 1024 - inset * 2)
    let shape = squirclePath(in: tile)

    // Ambient shadow so the tile sits on light and dark backgrounds alike.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: simplified ? -6 : -14),
                  blur: simplified ? 12 : 30, color: rgb(0, 0, 0, 0.35))
    ctx.addPath(shape)
    ctx.setFillColor(rgb(20, 22, 26))
    ctx.fillPath()
    ctx.restoreGState()

    // Graphite body, lit from the top-left.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let body = CGGradient(colorsSpace: srgb,
                          colors: [rgb(58, 64, 74), rgb(30, 33, 39), rgb(17, 19, 23)] as CFArray,
                          locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(body,
                           start: CGPoint(x: tile.minX, y: tile.maxY),
                           end: CGPoint(x: tile.maxX, y: tile.minY),
                           options: [])
    // Specular sheen across the top third.
    let sheen = CGGradient(colorsSpace: srgb,
                           colors: [rgb(255, 255, 255, 0.16), rgb(255, 255, 255, 0)] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(sheen,
                           start: CGPoint(x: tile.midX, y: tile.maxY),
                           end: CGPoint(x: tile.midX, y: tile.maxY - tile.height * 0.45),
                           options: [])
    ctx.restoreGState()

    // Bars: ascending height paired with an ascending thermal ramp, so the
    // silhouette reads as load even where the colours are lost.
    let heights: [CGFloat] = simplified ? [0.42, 0.70, 1.0] : [0.34, 0.55, 0.76, 1.0]
    let colors: [CGColor] = simplified
        ? [rgb(50, 215, 75), rgb(255, 159, 10), rgb(255, 69, 58)]
        : [rgb(50, 215, 75), rgb(255, 214, 10), rgb(255, 159, 10), rgb(255, 69, 58)]

    let sideInset: CGFloat = simplified ? 0.15 : 0.19
    let bottomInset: CGFloat = simplified ? 0.17 : 0.20
    let region = CGRect(x: tile.minX + tile.width * sideInset,
                        y: tile.minY + tile.height * bottomInset,
                        width: tile.width * (1 - sideInset * 2),
                        height: tile.height * (1 - bottomInset * 2))
    let count = CGFloat(heights.count)
    let barFraction: CGFloat = simplified ? 0.28 : 0.19
    let barW = region.width * barFraction
    let gap = (region.width - barW * count) / (count - 1)

    for (i, h) in heights.enumerated() {
        let x = region.minX + (barW + gap) * CGFloat(i)
        let bar = CGRect(x: x, y: region.minY, width: barW, height: region.height * h)
        let radius = min(barW * 0.32, bar.height / 2)
        ctx.addPath(CGPath(roundedRect: bar, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.setFillColor(colors[i])
        ctx.fillPath()
    }

    return ctx.makeImage()
}

func write(_ image: CGImage, to url: URL) -> Bool {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { return false }
    CGImageDestinationAddImage(dest, image, nil)
    return CGImageDestinationFinalize(dest)
}

// (filename, pixel size)
let variants: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

var failed = false
for (name, px) in variants {
    guard let image = drawIcon(pixels: px) else {
        FileHandle.standardError.write("render failed: \(name)\n".data(using: .utf8)!)
        failed = true
        continue
    }
    let url = URL(fileURLWithPath: outDir).appendingPathComponent(name)
    if write(image, to: url) {
        FileHandle.standardOutput.write("wrote \(name) (\(px)x\(px))\n".data(using: .utf8)!)
    } else {
        FileHandle.standardError.write("write failed: \(name)\n".data(using: .utf8)!)
        failed = true
    }
}
exit(failed ? 1 : 0)
