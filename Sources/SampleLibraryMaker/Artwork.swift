import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Album covers and artist pictures, drawn from shapes, gradients and type.
enum Artwork {
    enum Style: Sendable { case waves, night, horizon, kitchen, minimal, synthSun, jungle, window, savanna }

    struct Palette: Sendable {
        var colors: [UInt32]
        func color(_ i: Int, alpha: CGFloat = 1) -> CGColor {
            let c = colors[i % colors.count]
            return CGColor(srgbRed: CGFloat((c >> 16) & 0xff) / 255, green: CGFloat((c >> 8) & 0xff) / 255,
                           blue: CGFloat(c & 0xff) / 255, alpha: alpha)
        }
    }

    struct Lettering: Sendable {
        var title: String
        var artist: String
        var font: String
        var artistFont: String
        /// Index in the palette.
        var color: Int
        var top: Bool
    }

    static func cover(style: Style, palette: Palette, lettering: Lettering, seed: String, size: Int = 1000) -> Data {
        render(size: size) { ctx, s in
            var rng = SeededRandom(seed)
            drawBackground(style, palette: palette, in: ctx, size: s, rng: &rng)
            drawLettering(lettering, palette: palette, in: ctx, size: s)
        }
    }

    /// Soft out-of-focus lights in the artist's colors, like a stage photo with nobody in it.
    static func artistPicture(palette: Palette, seed: String, size: Int = 800) -> Data {
        render(size: size) { ctx, s in
            var rng = SeededRandom(seed)
            linear(ctx, [palette.color(0), palette.color(1)], from: CGPoint(x: 0, y: s), to: CGPoint(x: s, y: 0))
            for i in 0..<38 {
                let r = s * CGFloat(rng.range(0.04...0.2))
                let c = CGPoint(x: s * CGFloat(rng.unit()), y: s * CGFloat(rng.unit()))
                let color = palette.color(2 + i % max(1, palette.colors.count - 2), alpha: CGFloat(rng.range(0.15...0.55)))
                radial(ctx, color, center: c, radius: r)
            }
            grain(ctx, size: s, amount: 0.05, rng: &rng)
        }
    }

    // MARK: Backgrounds

    private static func drawBackground(_ style: Style, palette p: Palette, in ctx: CGContext, size s: CGFloat, rng: inout SeededRandom) {
        switch style {
        case .waves:
            linear(ctx, [p.color(0), p.color(1)], from: CGPoint(x: 0, y: s), to: CGPoint(x: 0, y: 0))
            circle(ctx, p.color(4, alpha: 0.9), center: CGPoint(x: s * 0.68, y: s * 0.62), radius: s * 0.13)
            for band in 0..<6 {
                let base = s * (0.45 - CGFloat(band) * 0.075)
                let path = CGMutablePath()
                path.move(to: CGPoint(x: 0, y: 0))
                for x in stride(from: CGFloat(0), through: s, by: 4) {
                    let y = base + sin(x / s * .pi * CGFloat(2 + band % 3) + CGFloat(band)) * s * 0.025
                    path.addLine(to: CGPoint(x: x, y: y))
                }
                path.addLine(to: CGPoint(x: s, y: 0))
                path.closeSubpath()
                ctx.addPath(path)
                ctx.setFillColor(p.color(2 + band % 2, alpha: 0.55))
                ctx.fillPath()
            }
        case .night:
            linear(ctx, [p.color(0), p.color(1)], from: CGPoint(x: 0, y: s), to: CGPoint(x: 0, y: 0))
            for _ in 0..<160 {
                let r = CGFloat(rng.range(0.6...2.4))
                circle(ctx, CGColor(gray: 1, alpha: CGFloat(rng.range(0.3...0.9))),
                       center: CGPoint(x: s * CGFloat(rng.unit()), y: s * CGFloat(rng.range(0.42...1))), radius: r)
            }
            circle(ctx, p.color(3), center: CGPoint(x: s * 0.3, y: s * 0.72), radius: s * 0.07)
            ctx.setFillColor(p.color(2))
            ctx.fill(CGRect(x: 0, y: 0, width: s, height: s * 0.4))
            // Lights on the water.
            for i in 0..<26 {
                let y = s * 0.38 - CGFloat(i) * s * 0.014
                let w = s * CGFloat(rng.range(0.03...0.16))
                ctx.setFillColor(p.color(4, alpha: CGFloat(0.8 - Double(i) * 0.025)))
                ctx.fill(CGRect(x: s * 0.62 - w / 2 + CGFloat(rng.range(-12...12)), y: y, width: w, height: s * 0.005))
            }
            // A ferry.
            ctx.setFillColor(p.color(5))
            ctx.fill(CGRect(x: s * 0.52, y: s * 0.4, width: s * 0.2, height: s * 0.035))
            ctx.fill(CGRect(x: s * 0.56, y: s * 0.435, width: s * 0.1, height: s * 0.03))
            for k in 0..<5 { circle(ctx, p.color(4), center: CGPoint(x: s * (0.545 + CGFloat(k) * 0.035), y: s * 0.418), radius: s * 0.005) }
        case .horizon:
            ctx.setFillColor(p.color(0))
            ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
            circle(ctx, p.color(1), center: CGPoint(x: s * 0.5, y: s * 0.52), radius: s * 0.24)
            for (i, h) in [0.42, 0.33, 0.24].enumerated() {
                let path = CGMutablePath()
                path.move(to: .zero)
                for x in stride(from: CGFloat(0), through: s, by: 5) {
                    path.addLine(to: CGPoint(x: x, y: s * CGFloat(h) + sin(x / s * 3.1 + CGFloat(i) * 1.7) * s * 0.05))
                }
                path.addLine(to: CGPoint(x: s, y: 0))
                path.closeSubpath()
                ctx.addPath(path)
                ctx.setFillColor(p.color(2 + i))
                ctx.fillPath()
            }
            // Bare trees.
            for k in 0..<7 {
                let x = s * (0.12 + CGFloat(k) * 0.12) + CGFloat(rng.range(-10...10))
                let base = s * 0.36, h = s * CGFloat(rng.range(0.08...0.16))
                ctx.setStrokeColor(p.color(5))
                ctx.setLineWidth(s * 0.006)
                ctx.move(to: CGPoint(x: x, y: base)); ctx.addLine(to: CGPoint(x: x, y: base + h))
                for b in 1...3 {
                    let y = base + h * CGFloat(b) / 4
                    ctx.move(to: CGPoint(x: x, y: y)); ctx.addLine(to: CGPoint(x: x - h * 0.25, y: y + h * 0.22))
                    ctx.move(to: CGPoint(x: x, y: y)); ctx.addLine(to: CGPoint(x: x + h * 0.25, y: y + h * 0.2))
                }
                ctx.strokePath()
            }
            grain(ctx, size: s, amount: 0.07, rng: &rng)
        case .kitchen:
            ctx.setFillColor(p.color(0))
            ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
            // A checked tablecloth and a little radio.
            let tile = s / 10
            for row in 0..<4 {
                for col in 0..<10 where (row + col) % 2 == 0 {
                    ctx.setFillColor(p.color(1, alpha: 0.85))
                    ctx.fill(CGRect(x: CGFloat(col) * tile, y: CGFloat(row) * tile, width: tile, height: tile))
                }
            }
            let radio = CGRect(x: s * 0.27, y: s * 0.36, width: s * 0.46, height: s * 0.28)
            ctx.addPath(CGPath(roundedRect: radio, cornerWidth: s * 0.04, cornerHeight: s * 0.04, transform: nil))
            ctx.setFillColor(p.color(2))
            ctx.fillPath()
            circle(ctx, p.color(3), center: CGPoint(x: radio.minX + radio.width * 0.3, y: radio.midY), radius: radio.height * 0.32)
            for k in 0..<5 {
                ctx.setFillColor(p.color(0, alpha: 0.6))
                ctx.fill(CGRect(x: radio.minX + radio.width * 0.3 - radio.height * 0.24, y: radio.midY - radio.height * 0.2 + CGFloat(k) * radio.height * 0.09,
                                width: radio.height * 0.48, height: radio.height * 0.03))
            }
            ctx.setFillColor(p.color(4))
            ctx.fill(CGRect(x: radio.minX + radio.width * 0.6, y: radio.midY - 2, width: radio.width * 0.3, height: s * 0.012))
            circle(ctx, p.color(4), center: CGPoint(x: radio.minX + radio.width * 0.75, y: radio.minY + radio.height * 0.25), radius: s * 0.025)
            ctx.setStrokeColor(p.color(2))
            ctx.setLineWidth(s * 0.008)
            ctx.move(to: CGPoint(x: radio.maxX - s * 0.06, y: radio.maxY)); ctx.addLine(to: CGPoint(x: radio.maxX + s * 0.06, y: radio.maxY + s * 0.16))
            ctx.strokePath()
            grain(ctx, size: s, amount: 0.06, rng: &rng)
        case .minimal:
            ctx.setFillColor(p.color(0))
            ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
            for k in 0..<9 {
                let x = s * (0.18 + CGFloat(k) * 0.08)
                ctx.setFillColor(p.color(1, alpha: k == 5 ? 1 : 0.35))
                ctx.fill(CGRect(x: x, y: s * 0.25, width: k == 5 ? 3 : 1.5, height: s * (0.25 + CGFloat(rng.range(0...0.3)))))
            }
            circle(ctx, p.color(2), center: CGPoint(x: s * 0.62, y: s * 0.7), radius: s * 0.045)
        case .synthSun:
            linear(ctx, [p.color(0), p.color(1), p.color(2)], from: CGPoint(x: 0, y: s), to: CGPoint(x: 0, y: s * 0.38))
            ctx.setFillColor(p.color(5))
            ctx.fill(CGRect(x: 0, y: 0, width: s, height: s * 0.38))
            // A striped sun.
            ctx.saveGState()
            let sun = CGRect(x: s * 0.3, y: s * 0.38, width: s * 0.4, height: s * 0.4)
            ctx.addEllipse(in: sun)
            ctx.clip()
            linear(ctx, [p.color(3), p.color(4)], from: CGPoint(x: 0, y: sun.maxY), to: CGPoint(x: 0, y: sun.minY))
            ctx.setFillColor(p.color(1))
            for k in 0..<7 {
                let h = s * 0.006 * CGFloat(k + 1)
                ctx.fill(CGRect(x: 0, y: s * 0.4 + CGFloat(k) * s * 0.032, width: s, height: h))
            }
            ctx.restoreGState()
            // The grid.
            ctx.setStrokeColor(p.color(6))
            ctx.setLineWidth(2)
            for k in -10...10 {
                ctx.move(to: CGPoint(x: s / 2 + CGFloat(k) * s * 0.02, y: s * 0.38))
                ctx.addLine(to: CGPoint(x: s / 2 + CGFloat(k) * s * 0.16, y: 0))
            }
            for k in 0..<9 {
                let y = s * 0.38 * pow(CGFloat(k) / 9, 1.8)
                ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: s, y: y))
            }
            ctx.strokePath()
            // Leaves.
            for k in 0..<8 {
                let c = CGPoint(x: k % 2 == 0 ? s * 0.06 : s * 0.94, y: s * (0.42 + CGFloat(k / 2) * 0.09))
                leaf(ctx, p.color(6, alpha: 0.85), at: c, length: s * 0.16, angle: k % 2 == 0 ? 0.4 : .pi - 0.4)
            }
        case .jungle:
            linear(ctx, [p.color(0), p.color(1)], from: CGPoint(x: 0, y: s), to: CGPoint(x: 0, y: 0))
            for _ in 0..<70 {
                let c = CGPoint(x: s * CGFloat(rng.unit()), y: s * CGFloat(rng.unit()))
                leaf(ctx, p.color(2 + Int(rng.next() % 3), alpha: CGFloat(rng.range(0.6...0.95))), at: c,
                     length: s * CGFloat(rng.range(0.1...0.3)), angle: CGFloat(rng.range(0...6.28)))
            }
            ctx.setStrokeColor(p.color(5))
            ctx.setLineWidth(s * 0.01)
            ctx.addEllipse(in: CGRect(x: s * 0.27, y: s * 0.36, width: s * 0.46, height: s * 0.46))
            ctx.strokePath()
            // Shade under the lettering.
            linear(ctx, [p.color(1, alpha: 0.95), p.color(1, alpha: 0)], from: .zero, to: CGPoint(x: 0, y: s * 0.32))
        case .window:
            linear(ctx, [p.color(0), p.color(1)], from: CGPoint(x: 0, y: s), to: CGPoint(x: s, y: 0))
            let frame = CGRect(x: s * 0.2, y: s * 0.22, width: s * 0.6, height: s * 0.56)
            ctx.setFillColor(p.color(2))
            ctx.fill(frame)
            // Rain on the glass.
            for _ in 0..<140 {
                let x = frame.minX + frame.width * CGFloat(rng.unit()), y = frame.minY + frame.height * CGFloat(rng.unit())
                ctx.setStrokeColor(p.color(3, alpha: CGFloat(rng.range(0.25...0.7))))
                ctx.setLineWidth(1.5)
                ctx.move(to: CGPoint(x: x, y: y)); ctx.addLine(to: CGPoint(x: x - 4, y: y - s * CGFloat(rng.range(0.01...0.04))))
                ctx.strokePath()
            }
            ctx.setStrokeColor(p.color(4))
            ctx.setLineWidth(s * 0.018)
            ctx.stroke(frame)
            ctx.move(to: CGPoint(x: frame.midX, y: frame.minY)); ctx.addLine(to: CGPoint(x: frame.midX, y: frame.maxY))
            ctx.move(to: CGPoint(x: frame.minX, y: frame.midY)); ctx.addLine(to: CGPoint(x: frame.maxX, y: frame.midY))
            ctx.strokePath()
            // A mug on the sill.
            ctx.setFillColor(p.color(5))
            ctx.fill(CGRect(x: frame.minX - s * 0.05, y: frame.minY - s * 0.04, width: frame.width + s * 0.1, height: s * 0.04))
            ctx.fill(CGRect(x: s * 0.6, y: frame.minY, width: s * 0.08, height: s * 0.09))
            grain(ctx, size: s, amount: 0.09, rng: &rng)
        case .savanna:
            linear(ctx, [p.color(0), p.color(1)], from: CGPoint(x: 0, y: s), to: CGPoint(x: 0, y: s * 0.3))
            circle(ctx, p.color(2), center: CGPoint(x: s * 0.5, y: s * 0.42), radius: s * 0.3)
            ctx.setFillColor(p.color(3))
            ctx.fill(CGRect(x: 0, y: 0, width: s, height: s * 0.3))
            // An acacia.
            ctx.setFillColor(p.color(4))
            ctx.fill(CGRect(x: s * 0.66, y: s * 0.3, width: s * 0.025, height: s * 0.2))
            ctx.fillEllipse(in: CGRect(x: s * 0.52, y: s * 0.47, width: s * 0.32, height: s * 0.07))
            // Heat haze.
            for k in 0..<12 {
                ctx.setFillColor(p.color(2, alpha: 0.25))
                ctx.fill(CGRect(x: 0, y: s * (0.3 - CGFloat(k) * 0.022), width: s, height: s * 0.004))
            }
            grain(ctx, size: s, amount: 0.05, rng: &rng)
        }
    }

    private static func drawLettering(_ l: Lettering, palette p: Palette, in ctx: CGContext, size s: CGFloat) {
        let margin = s * 0.07
        let title = line(l.title, font: l.font, size: s * 0.075, color: p.color(l.color))
        let artist = line(l.artist.uppercased(), font: l.artistFont, size: s * 0.034, color: p.color(l.color, alpha: 0.85), kern: s * 0.004)
        if l.top {
            draw(artist, at: CGPoint(x: margin, y: s - margin - s * 0.03), in: ctx)
            draw(title, at: CGPoint(x: margin, y: s - margin - s * 0.12), in: ctx)
        } else {
            draw(title, at: CGPoint(x: margin, y: margin + s * 0.06), in: ctx)
            draw(artist, at: CGPoint(x: margin, y: margin), in: ctx)
        }
    }

    // MARK: Helpers

    private static func render(size: Int, draw: (CGContext, CGFloat) -> Void) -> Data {
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setShouldAntialias(true)
        draw(ctx, CGFloat(size))
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    private static func linear(_ ctx: CGContext, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
        ctx.drawLinearGradient(gradient, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    private static func radial(_ ctx: CGContext, _ color: CGColor, center: CGPoint, radius: CGFloat) {
        let clear = color.copy(alpha: 0)!
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color, color, clear] as CFArray, locations: [0, 0.55, 1])!
        ctx.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
    }

    private static func circle(_ ctx: CGContext, _ color: CGColor, center: CGPoint, radius: CGFloat) {
        ctx.setFillColor(color)
        ctx.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    private static func leaf(_ ctx: CGContext, _ color: CGColor, at p: CGPoint, length: CGFloat, angle: CGFloat) {
        ctx.saveGState()
        ctx.translateBy(x: p.x, y: p.y)
        ctx.rotate(by: angle)
        let path = CGMutablePath()
        path.move(to: .zero)
        path.addQuadCurve(to: CGPoint(x: length, y: 0), control: CGPoint(x: length / 2, y: length * 0.32))
        path.addQuadCurve(to: .zero, control: CGPoint(x: length / 2, y: -length * 0.32))
        ctx.addPath(path)
        ctx.setFillColor(color)
        ctx.fillPath()
        ctx.restoreGState()
    }

    private static func grain(_ ctx: CGContext, size s: CGFloat, amount: CGFloat, rng: inout SeededRandom) {
        for _ in 0..<Int(s * s / 40) {
            ctx.setFillColor(CGColor(gray: rng.chance(0.5) ? 1 : 0, alpha: amount))
            ctx.fill(CGRect(x: s * CGFloat(rng.unit()), y: s * CGFloat(rng.unit()), width: 1.5, height: 1.5))
        }
    }

    private static func line(_ text: String, font: String, size: CGFloat, color: CGColor, kern: CGFloat = 0) -> CTLine {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(font as CFString, size, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            NSAttributedString.Key(kCTKernAttributeName as String): kern,
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    }

    private static func draw(_ line: CTLine, at p: CGPoint, in ctx: CGContext) {
        ctx.textPosition = p
        CTLineDraw(line, ctx)
    }
}
