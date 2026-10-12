import AppKit
import CoreGraphics
import Foundation

// Usage: swift scripts/make-icon.swift  (from anywhere; writes into <repo>/Resources and the iPhone and watch asset
// catalogs). Draws the app icon with paths only (no SF Symbols or font glyphs).
//
// The Mac icon is the rounded body on a transparent margin, as macOS expects. iOS and watchOS round (or circle) the
// icon themselves and fill transparency, so theirs is full bleed and opaque: the body fills the square.

let space = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [
        CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, alpha,
    ])!
}

func gradient(_ hexes: [UInt32]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: hexes.map { color($0) } as CFArray, locations: [0, 0.5, 1])!
}

func circle(_ c: CGPoint, _ r: CGFloat) -> CGPath {
    CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r), transform: nil)
}

func render(size: Int, fullBleed: Bool = false) -> CGImage {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: (fullBleed ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast).rawValue)!
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    if fullBleed {
        // The body (100…924) fills the canvas.
        ctx.scaleBy(x: 1024 / 824, y: 1024 / 824)
        ctx.translateBy(x: -100, y: -100)
    }
    let small = size <= 32

    // Body, with a shadow on the Mac
    let rect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let body = fullBleed ? CGPath(rect: rect, transform: nil) : CGPath(roundedRect: rect, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    if !fullBleed { ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 20, color: color(0x000000, alpha: 0.3)) }
    ctx.setFillColor(color(0x3A1C71))
    ctx.addPath(body)
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    ctx.drawLinearGradient(gradient([0x3A1C71, 0xD76D77, 0xFFAF7B]), start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 100), options: [])
    ctx.restoreGState()

    // Vinyl
    let center = CGPoint(x: 470, y: 540)
    ctx.setFillColor(color(0x121212))
    ctx.addPath(circle(center, 300))
    ctx.fillPath()
    if !small {
        ctx.saveGState()
        ctx.setStrokeColor(color(0xFFFFFF, alpha: 0.05))
        ctx.setLineWidth(2)
        var r: CGFloat = 120
        while r <= 290 {
            ctx.addPath(circle(center, r))
            ctx.strokePath()
            r += 14
        }
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(circle(center, 300))
        ctx.clip()
        ctx.setFillColor(color(0xFFFFFF, alpha: 0.07))
        for mid in [45.0, 225.0] {
            let a0 = (mid - 17.5) * .pi / 180, a1 = (mid + 17.5) * .pi / 180
            ctx.move(to: center)
            ctx.addArc(center: center, radius: 300, startAngle: a0, endAngle: a1, clockwise: false)
            ctx.closePath()
            ctx.fillPath()
        }
        ctx.restoreGState()
    }

    // Label
    ctx.saveGState()
    ctx.addPath(circle(center, 105))
    ctx.clip()
    ctx.drawLinearGradient(gradient([0xFFAF7B, 0xD76D77, 0x3A1C71]), start: CGPoint(x: 0, y: center.y + 105), end: CGPoint(x: 0, y: center.y - 105), options: [])
    ctx.restoreGState()
    ctx.setFillColor(color(0x121212))
    ctx.addPath(circle(center, 12))
    ctx.fillPath()

    // Note
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 16, color: color(0x000000, alpha: 0.35))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.setFillColor(color(0xFFFFFF))
    let heads = [CGPoint(x: 600, y: 300), CGPoint(x: 790, y: 340)]
    let stemTops: [CGFloat] = [640, 680]
    for h in heads {
        ctx.saveGState()
        ctx.translateBy(x: h.x, y: h.y)
        ctx.rotate(by: -20 * .pi / 180)
        ctx.fillEllipse(in: CGRect(x: -55, y: -40, width: 110, height: 80))
        ctx.restoreGState()
    }
    let k: CGFloat = small ? 1.6 : 1
    let stemW = 26 * k
    let beamT = 44 * k
    let stemX = heads.map { $0.x + 29 + 13 - stemW / 2 }
    // Beam top line runs through the stem-top corners; stems end exactly on it.
    let topLeft = stemTops[0] - 22 + beamT / 2
    let topRight = stemTops[1] - 22 + beamT / 2
    let xL = stemX[0], xR = stemX[1] + stemW
    func beamTop(_ x: CGFloat) -> CGFloat { topLeft + (topRight - topLeft) * (x - xL) / (xR - xL) }
    for (i, h) in heads.enumerated() {
        let x = stemX[i]
        ctx.move(to: CGPoint(x: x, y: h.y))
        ctx.addLine(to: CGPoint(x: x + stemW, y: h.y))
        ctx.addLine(to: CGPoint(x: x + stemW, y: beamTop(x + stemW)))
        ctx.addLine(to: CGPoint(x: x, y: beamTop(x)))
        ctx.closePath()
        ctx.fillPath()
    }
    for dy: CGFloat in (small ? [0] : [0, -60]) {
        ctx.move(to: CGPoint(x: xL, y: topLeft + dy))
        ctx.addLine(to: CGPoint(x: xR, y: topRight + dy))
        ctx.addLine(to: CGPoint(x: xR, y: topRight + dy - beamT))
        ctx.addLine(to: CGPoint(x: xL, y: topLeft + dy - beamT))
        ctx.closePath()
        ctx.fillPath()
    }
    ctx.endTransparencyLayer()
    ctx.restoreGState()

    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let resources = root.appendingPathComponent("Resources", isDirectory: true)
let iconset = resources.appendingPathComponent("AppIcon.iconset", isDirectory: true)
let fm = FileManager.default
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    try writePNG(render(size: base), to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try writePNG(render(size: base * 2), to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try writePNG(render(size: 1024), to: resources.appendingPathComponent("AppIcon-1024.png"))
for app in ["MusicLibraryMobile", "MusicLibraryWatch"] {
    let url = root.appendingPathComponent("iOS/\(app)/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png")
    try writePNG(render(size: 1024, fullBleed: true), to: url)
}

let icns = resources.appendingPathComponent("AppIcon.icns")
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(1)
}
try fm.removeItem(at: iconset)
print("Wrote \(icns.path)")
