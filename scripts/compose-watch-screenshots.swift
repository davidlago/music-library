// Puts Apple Watch screenshots side by side, each in a watch case, on a 1600×1000 canvas, as in
// docs/screenshots/watch.png. Take them with `xcrun simctl io <watch> screenshot <file>.png` (a watch simulator
// paired with the iPhone simulator; the watch's status bar can't be overridden).
//
//     swift scripts/compose-watch-screenshots.swift <out.png> <screen.png>...  (up to 4)

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard (3...6).contains(args.count) else {
    print("usage: compose-watch-screenshots.swift <out.png> <screen.png>... (1 to 4 screens)")
    exit(1)
}

func load(_ path: String) -> CGImage {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        print("Can't read \(path)")
        exit(1)
    }
    return image
}

func color(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: 1)
}

let width = 1600, height = 1000
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let background = CGGradient(colorsSpace: space, colors: [color(0xd6d9e6), color(0xededf5)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(background, start: .zero, end: CGPoint(x: 0, y: height), options: [])

let screens = args[2...].map(load)
// The screen's size on the canvas, and the case around it.
let screenWidth: CGFloat = 276, bezel: CGFloat = 22, gap: CGFloat = 64
let screenHeight = screenWidth * CGFloat(screens[0].height) / CGFloat(screens[0].width)
let caseWidth = screenWidth + 2 * bezel, caseHeight = screenHeight + 2 * bezel
let total = CGFloat(screens.count) * caseWidth + CGFloat(screens.count - 1) * gap
var x = (CGFloat(width) - total) / 2
let y = (CGFloat(height) - caseHeight) / 2

for image in screens {
    let caseRect = CGRect(x: x, y: y, width: caseWidth, height: caseHeight)
    let caseShape = CGPath(roundedRect: caseRect, cornerWidth: 70, cornerHeight: 70, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 34, color: CGColor(gray: 0, alpha: 0.28))
    ctx.addPath(caseShape)
    ctx.setFillColor(color(0x1c1c1e))
    ctx.fillPath()
    ctx.restoreGState()
    // A thin highlight on the case's edge.
    ctx.addPath(caseShape)
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.12))
    ctx.setLineWidth(2)
    ctx.strokePath()

    let screenRect = caseRect.insetBy(dx: bezel, dy: bezel)
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: screenRect, cornerWidth: 44, cornerHeight: 44, transform: nil))
    ctx.clip()
    ctx.setFillColor(CGColor(gray: 0, alpha: 1))
    ctx.fill(screenRect)
    ctx.interpolationQuality = .high
    ctx.draw(image, in: screenRect)
    ctx.restoreGState()
    x += caseWidth + gap
}

let out = URL(fileURLWithPath: args[1])
guard let image = ctx.makeImage(), let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil) else { exit(1) }
CGImageDestinationAddImage(dest, image, nil)
exit(CGImageDestinationFinalize(dest) ? 0 : 1)
