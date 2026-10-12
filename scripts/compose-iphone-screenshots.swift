// Puts three iPhone screenshots side by side on a 1600×1000 canvas, as in docs/screenshots/iphone*.png.
// Take them with `xcrun simctl io booted screenshot <file>.png` after
// `xcrun simctl status_bar booted override --time 9:41 --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4`.
//
//     swift scripts/compose-iphone-screenshots.swift <out.png> <left.png> <middle.png> <right.png>

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count == 5 else {
    print("usage: compose-iphone-screenshots.swift <out.png> <left.png> <middle.png> <right.png>")
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

let phoneWidth: CGFloat = 413, phoneHeight: CGFloat = 900, radius: CGFloat = 56
for (i, path) in args[2...4].enumerated() {
    let image = load(path)
    let frame = CGRect(x: [90, 593, 1097][i], y: (CGFloat(height) - phoneHeight) / 2, width: phoneWidth, height: phoneHeight)
    let shape = CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: CGColor(gray: 0, alpha: 0.18))
    ctx.addPath(shape)
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()
    // The screenshot fills the frame's width; anything below the frame is cut off.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    ctx.interpolationQuality = .high
    let scaledHeight = CGFloat(image.height) * phoneWidth / CGFloat(image.width)
    ctx.draw(image, in: CGRect(x: frame.minX, y: frame.maxY - scaledHeight, width: phoneWidth, height: scaledHeight))
    ctx.restoreGState()
    ctx.addPath(shape)
    ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.08))
    ctx.setLineWidth(1.5)
    ctx.strokePath()
}

let out = URL(fileURLWithPath: args[1])
guard let image = ctx.makeImage(), let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil) else { exit(1) }
CGImageDestinationAddImage(dest, image, nil)
exit(CGImageDestinationFinalize(dest) ? 0 : 1)
