import CoreGraphics
import Foundation

/// A color taken from a cover or an artist photo, for the panels the Listening pane draws around them.
public enum ArtworkTint {
    /// The image's average color, or nil when it can't be drawn.
    public static func average(of image: CGImage) -> RGB? {
        var pixel = [UInt8](repeating: 0, count: 4)
        let drawn = pixel.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard drawn, pixel[3] > 0 else { return nil }
        let alpha = Double(pixel[3]) / 255
        return RGB(r: Double(pixel[0]) / 255 / alpha, g: Double(pixel[1]) / 255 / alpha, b: Double(pixel[2]) / 255 / alpha)
    }

    /// `color` made a little more vivid (averages come out muddy), then darkened until white text on it has at least
    /// `contrast` (WCAG; 4.5 is body text).
    public static func panel(from color: RGB, contrast: Double = 4.5) -> RGB {
        let gray = (color.r + color.g + color.b) / 3
        func vivid(_ c: Double) -> Double { min(max(gray + (c - gray) * 1.5, 0), 1) }
        var tint = RGB(r: vivid(color.r), g: vivid(color.g), b: vivid(color.b))
        var step = 0
        while tint.contrast(with: .white) < contrast, step < 40 {
            tint = tint.mix(.black, 0.08)
            step += 1
        }
        return tint
    }
}
