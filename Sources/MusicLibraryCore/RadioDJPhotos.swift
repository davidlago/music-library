import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A photo the listener shows the Radio DJ: a record or CD in a shop, its spine, back or label, a shelf. Made from any
/// image ImageIO reads (HEIC from the iPhone's camera, PNG, a pasted TIFF…), turned upright, scaled down to at most
/// `maxPixels` on the long edge and encoded again as a JPEG, so none of the original's metadata (the place it was taken,
/// the camera) goes to Anthropic. Sent as a base64 `image` block before the question's text.
public struct RadioDJPhoto: Hashable, Sendable, Identifiable {
    public let id: UUID
    /// What's sent.
    public let jpeg: Data
    /// What's shown in the conversation (at most `thumbnailPixels`).
    public let thumbnail: Data
    public let width: Int
    public let height: Int

    /// Enough to read a catalog number or a barcode on a photo of a whole sleeve; Claude Opus 5.5 reads up to 2576.
    public static let maxPixels = 2048
    public static let thumbnailPixels = 360
    /// Photos one message can carry.
    public static let maxPerMessage = 4
    /// The API's limit is 5 MB of base64 per image (3.75 MB of JPEG); this leaves room.
    static let maxBytes = 3_500_000

    /// Nil when `data` isn't an image.
    public init?(imageData data: Data) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let image = Self.upright(source, maxPixels: Self.maxPixels),
              let small = Self.upright(source, maxPixels: Self.thumbnailPixels),
              let jpeg = Self.jpeg(image, under: Self.maxBytes),
              let thumbnail = Self.jpeg(small, under: Self.maxBytes) else { return nil }
        id = UUID()
        self.jpeg = jpeg
        self.thumbnail = thumbnail
        width = image.width
        height = image.height
    }

    /// The content block for the Messages API.
    public var block: JSONValue {
        .object(["type": .string("image"),
                 "source": .object(["type": .string("base64"), "media_type": .string("image/jpeg"),
                                    "data": .string(jpeg.base64EncodedString())])])
    }

    /// The image the right way up (camera photos are stored sideways with an orientation tag), at most `maxPixels`
    /// on the long edge (never enlarged), drawn on white in sRGB: JPEG has no transparency.
    private static func upright(_ source: CGImageSource, maxPixels: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let scaled = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              scaled.width > 0, scaled.height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: scaled.width, height: scaled.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: scaled.width, height: scaled.height)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(rect)
        ctx.interpolationQuality = .high
        ctx.draw(scaled, in: rect)
        return ctx.makeImage()
    }

    /// A JPEG of `image` with no metadata, at the best quality that stays under `limit` bytes.
    private static func jpeg(_ image: CGImage, under limit: Int) -> Data? {
        for quality in [0.85, 0.7, 0.5, 0.3] {
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { return nil }
            if data.length <= limit { return data as Data }
        }
        return nil
    }
}

extension ClaudeMessage {
    /// The listener's message: their photos, then what they wrote.
    public static func user(_ text: String, photos: [RadioDJPhoto]) -> ClaudeMessage {
        var message = user(text)
        message.content.insert(contentsOf: photos.map(\.block), at: 0)
        return message
    }
}

extension RadioDJ {
    /// What the DJ is asked when photos go without a question.
    public static func photoQuestion(count: Int = 1, canSearchCollection: Bool = false) -> String {
        let question = count == 1 ? "What's this?" : "What are these?"
        return canSearchCollection ? question + (count == 1 ? " Do I have it?" : " Do I have them?") : question
    }

    /// Questions offered while photos are attached, the first asked when the listener sends them without one.
    public static func photoQuestions(count: Int = 1, canSearchCollection: Bool = false, canShop: Bool = false) -> [String] {
        let list: [String?] = [
            photoQuestion(count: count, canSearchCollection: canSearchCollection),
            canSearchCollection ? "What else do I have by them?" : nil,
            "What do the reviews say?",
            "What's a fair price for it?",
            canShop ? "Find me a copy to buy" : nil,
        ]
        return list.compactMap { $0 }
    }
}
