// Draws the App Store product page header / search results creative asset (one "universal" 16:9 image, 5244×2950
// PNG without alpha) from three iPhone screenshots, in the website's colors. The App Store crops it to 21:9 for the
// header and 3:2 for search results, and an iPhone shows only part of the header (about x 1200…4270, y 0…1920, with
// its buttons over the top 600), so everything that matters stays inside x 1300…4200, y 620…1880. The search results
// asset is a 3:2 crop around the same content (`<out>-search.png`, 1920×1280), so it fills the search card.
//
//     swift scripts/make-store-header.swift <out.png> <left.png> <middle.png> <right.png>
//
// Defaults to the App Store screenshots in docs/app-store/iphone-6.3.
import AppKit

let args = CommandLine.arguments.dropFirst()
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let shots = root.appendingPathComponent("docs/app-store/iphone-6.3")
let out = args.first.map { URL(fileURLWithPath: $0) } ?? root.appendingPathComponent("docs/app-store/header.png")
let phones = args.count == 4
    ? args.dropFirst().map { URL(fileURLWithPath: $0) }
    : ["01-physical.png", "02-item.png", "05-album.png"].map { shots.appendingPathComponent($0) }

let W = 5244, H = 2950
// No alpha channel: the App Store refuses images with one.
guard let cg = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                         bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { fatalError("no bitmap") }
NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)
// Work top-down like a page.
cg.translateBy(x: 0, y: CGFloat(H))
cg.scaleBy(x: 1, y: -1)

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

// Background: the site's near-black with violet and peach glows.
color(0x0c0a14).setFill()
NSRect(x: 0, y: 0, width: W, height: H).fill()
func glow(_ center: CGPoint, _ radius: CGFloat, _ c: NSColor) {
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                       colors: [c.cgColor, c.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
    cg.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
}
glow(CGPoint(x: 1700, y: 1000), 2100, color(0x8b5cf6, 0.42))
glow(CGPoint(x: 3900, y: 2100), 2100, color(0xffb27f, 0.30))
glow(CGPoint(x: 3300, y: 600), 1700, color(0xe0707a, 0.22))

// Text block on the left, inside the safe area.
let left: CGFloat = 1330
func draw(_ text: String, at p: CGPoint, size: CGFloat, weight: NSFont.Weight, color c: NSColor, kern: CGFloat = 0) -> CGFloat {
    let font = NSFont.systemFont(ofSize: size, weight: weight)
    let para = NSMutableParagraphStyle()
    para.lineHeightMultiple = 0.98
    let s = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: c, .kern: kern, .paragraphStyle: para])
    let bounds = s.boundingRect(with: NSSize(width: 2300, height: 2000), options: [.usesLineFragmentOrigin])
    NSGraphicsContext.saveGraphicsState()
    let flip = NSAffineTransform()
    flip.translateX(by: p.x, yBy: p.y + bounds.height)
    flip.scaleX(by: 1, yBy: -1)
    flip.concat()
    s.draw(with: NSRect(x: 0, y: 0, width: 2300, height: bounds.height), options: [.usesLineFragmentOrigin])
    NSGraphicsContext.restoreGraphicsState()
    return bounds.height
}

// The app icon.
if let icon = NSImage(contentsOf: root.appendingPathComponent("Resources/AppIcon-1024.png"))?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
    let r = CGRect(x: left, y: 690, width: 170, height: 170)
    cg.saveGState()
    cg.translateBy(x: r.minX, y: r.maxY)
    cg.scaleBy(x: 1, y: -1)
    cg.draw(icon, in: CGRect(origin: .zero, size: r.size))
    cg.restoreGState()
}

var y: CGFloat = 930
y += draw("Your CDs, your records,\nyour music files.", at: CGPoint(x: left, y: y), size: 130, weight: .bold, color: .white, kern: -3)
y += 40
// A gradient line, as on the website.
let line = "Finally in one place."
let lineFont = NSFont.systemFont(ofSize: 130, weight: .bold)
let lineString = NSAttributedString(string: line, attributes: [.font: lineFont, .kern: -3])
let lineSize = lineString.size()
cg.saveGState()
let path = CGMutablePath()
let ctLine = CTLineCreateWithAttributedString(lineString)
let runs = CTLineGetGlyphRuns(ctLine) as! [CTRun]
for run in runs {
    let count = CTRunGetGlyphCount(run)
    var glyphs = [CGGlyph](repeating: 0, count: count), positions = [CGPoint](repeating: .zero, count: count)
    CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
    CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
    let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
    for (g, p) in zip(glyphs, positions) {
        if let gp = CTFontCreatePathForGlyph(runFont, g, nil) {
            let t = CGAffineTransform(translationX: left + p.x, y: y + lineSize.height * 0.78).scaledBy(x: 1, y: -1)
            path.addPath(gp, transform: t)
        }
    }
}
cg.addPath(path)
cg.clip()
let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                      colors: [color(0xa78bfa).cgColor, color(0xe0707a).cgColor, color(0xffb27f).cgColor] as CFArray,
                      locations: [0, 0.5, 1])!
cg.drawLinearGradient(grad, start: CGPoint(x: left, y: 0), end: CGPoint(x: left + lineSize.width, y: 0), options: [])
cg.restoreGState()
y += lineSize.height + 60
_ = draw("Find any CD by its label. Play your music offline.\nHear the story behind every record.", at: CGPoint(x: left, y: y),
         size: 61, weight: .regular, color: color(0xb3abc6))

// Three phones, fanned on the right.
func phone(_ url: URL, center: CGPoint, height: CGFloat, angle: CGFloat) {
    guard let img = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
    let width = height * CGFloat(img.width) / CGFloat(img.height)
    let bezel: CGFloat = height * 0.016
    cg.saveGState()
    cg.translateBy(x: center.x, y: center.y)
    cg.rotate(by: angle * .pi / 180)
    let body = CGRect(x: -width / 2 - bezel, y: -height / 2 - bezel, width: width + 2 * bezel, height: height + 2 * bezel)
    let radius = width * 0.135
    cg.setShadow(offset: CGSize(width: 0, height: 40), blur: 110, color: NSColor.black.withAlphaComponent(0.65).cgColor)
    cg.addPath(CGPath(roundedRect: body, cornerWidth: radius + bezel, cornerHeight: radius + bezel, transform: nil))
    cg.setFillColor(color(0x1b1924).cgColor)
    cg.fillPath()
    cg.setShadow(offset: .zero, blur: 0, color: nil)
    cg.addPath(CGPath(roundedRect: body.insetBy(dx: 3, dy: 3), cornerWidth: radius + bezel - 3, cornerHeight: radius + bezel - 3, transform: nil))
    cg.setStrokeColor(NSColor.white.withAlphaComponent(0.16).cgColor)
    cg.setLineWidth(6)
    cg.strokePath()
    let screen = CGRect(x: -width / 2, y: -height / 2, width: width, height: height)
    cg.addPath(CGPath(roundedRect: screen, cornerWidth: radius, cornerHeight: radius, transform: nil))
    cg.clip()
    cg.scaleBy(x: 1, y: -1)
    cg.draw(img, in: CGRect(x: -width / 2, y: -height / 2, width: width, height: height))
    cg.restoreGState()
}
let ph: CGFloat = 1160
phone(phones[0], center: CGPoint(x: 3090, y: 1270), height: ph * 0.9, angle: -7)
phone(phones[2], center: CGPoint(x: 3870, y: 1270), height: ph * 0.9, angle: 7)
phone(phones[1], center: CGPoint(x: 3480, y: 1230), height: ph, angle: 0)

NSGraphicsContext.current = nil
// Drop the lowest bits of each channel so the PNG stays small enough to upload (under 10 MB); invisible at this size.
if let data = cg.data?.assumingMemoryBound(to: UInt8.self) {
    for i in 0..<(cg.bytesPerRow * H) { data[i] &= 0xFC }
}
guard let image = cg.makeImage(), let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
else { fatalError("no png") }
try png.write(to: out)
print("Wrote \(out.path) (\(W)×\(H))")

// The search results asset: a 3:2 crop around the content, scaled to 1920×1280.
let crop = CGRect(x: 1080, y: 130, width: 3360, height: 2240)
if let cropped = image.cropping(to: crop),
   let small = CGContext(data: nil, width: 1920, height: 1280, bitsPerComponent: 8, bytesPerRow: 0,
                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
    small.interpolationQuality = .high
    small.draw(cropped, in: CGRect(x: 0, y: 0, width: 1920, height: 1280))
    let searchURL = out.deletingPathExtension().appendingPathExtension("search.png")
    if let scaled = small.makeImage(), let data = NSBitmapImageRep(cgImage: scaled).representation(using: .png, properties: [:]) {
        try data.write(to: searchURL)
        print("Wrote \(searchURL.path) (1920×1280)")
    }
}
