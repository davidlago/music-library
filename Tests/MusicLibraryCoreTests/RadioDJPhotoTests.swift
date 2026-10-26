import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import MusicLibraryCore

@Suite struct RadioDJPhotoTests {
    /// A `width`×`height` JPEG stored with an EXIF orientation and a GPS position, as a phone camera writes it.
    static func cameraJPEG(width: Int, height: Int, orientation: Int = 1) throws -> Data {
        let ctx = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(ctx.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: orientation,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 42.28, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 71.35, kCGImagePropertyGPSLongitudeRef: "W"],
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    static func properties(_ data: Data) -> [CFString: Any] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return [:] }
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
    }

    @Test func turnedUprightScaledDownAndStripped() throws {
        // Stored landscape, tagged "rotate 90°": the photo was taken in portrait.
        let original = try Self.cameraJPEG(width: 4032, height: 3024, orientation: 6)
        #expect(Self.properties(original)[kCGImagePropertyGPSDictionary] != nil)
        let photo = try #require(RadioDJPhoto(imageData: original))
        #expect(photo.width == 1536 && photo.height == 2048)
        let sent = Self.properties(photo.jpeg)
        #expect(sent[kCGImagePropertyGPSDictionary] == nil)
        #expect((sent[kCGImagePropertyOrientation] as? Int ?? 1) == 1)
        #expect(sent[kCGImagePropertyPixelHeight] as? Int == 2048)
        #expect(Self.properties(photo.thumbnail)[kCGImagePropertyPixelHeight] as? Int == RadioDJPhoto.thumbnailPixels)
        #expect(photo.jpeg.count < 3_500_000)

        let block = photo.block
        #expect(block["type"]?.string == "image")
        #expect(block["source"]?["media_type"]?.string == "image/jpeg")
        #expect(block["source"]?["data"]?.string.flatMap { Data(base64Encoded: $0) } == photo.jpeg)
    }

    @Test func smallPhotosStayTheirSizeAndNonImagesAreRefused() throws {
        let photo = try #require(RadioDJPhoto(imageData: try Self.cameraJPEG(width: 640, height: 480)))
        #expect(photo.width == 640 && photo.height == 480)
        #expect(RadioDJPhoto(imageData: Data("not a picture".utf8)) == nil)
        #expect(RadioDJPhoto(imageData: Data()) == nil)
    }

    @Test func personaReadsPhotos() {
        let phone = RadioDJ.persona(name: "Max", canSearchCollection: true)
        #expect(phone.contains("The listener can show you photos"))
        #expect(phone.contains("check search_collection to tell them whether they already own it"))
        #expect(!phone.contains("open the Shop on it"))
        #expect(RadioDJ.persona(name: "Max", canShop: true).contains("offer to open the Shop on it"))
        #expect(RadioDJ.photoQuestions(canSearchCollection: true, canShop: true)
            == ["What's this? Do I have it?", "What else do I have by them?", "What do the reviews say?",
                "What's a fair price for it?", "Find me a copy to buy"])
        #expect(RadioDJ.photoQuestions(count: 2).first == "What are these?")
    }
}

@MainActor @Suite struct RadioDJPhotoSessionTests {
    let subject = RadioDJSubject(kind: .page, title: "the Shelf")

    func waitIdle(_ session: RadioDJSession) async {
        for _ in 0..<200 where session.isBusy || session.lines.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        for _ in 0..<200 where session.isBusy { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func photosGoBeforeTheQuestionAndComeBackOnRetry() async throws {
        let transport = ScriptedClaudeTransport([
            .failure(.overloaded),
            .lines(textReply("That's *Blue*, an original Reprise pressing.")),
            .lines(textReply("Around $40 in that shape.")),
        ])
        let session = RadioDJSession(name: "Max", subject: subject, client: ClaudeClient(apiKey: "k", transport: transport)) { _ in }
        session.start()
        let photo = try #require(RadioDJPhoto(imageData: try RadioDJPhotoTests.cameraJPEG(width: 800, height: 800)))
        let photos = Array(repeating: photo, count: RadioDJPhoto.maxPerMessage + 2)

        // Photos alone ask what they are; at most four go.
        session.send("  ", photos: photos)
        await waitIdle(session)
        #expect(session.error != nil)
        #expect(session.lines.last?.role == .listener && session.lines.last?.photos.count == RadioDJPhoto.maxPerMessage)
        #expect(session.lines.last?.text == "What are these?")

        session.retry()
        await waitIdle(session)
        #expect(session.error == nil)
        let first = try #require(transport.bodies[1]["messages"]?.array?.first?["content"]?.array)
        #expect(first.count == RadioDJPhoto.maxPerMessage + 1)
        #expect(first.prefix(RadioDJPhoto.maxPerMessage).allSatisfy { $0["type"]?.string == "image" })
        #expect(first.last?["type"]?.string == "text")
        #expect(first.last?["text"]?.string?.hasPrefix("(The listener just switched you on from the Shelf") == true)

        // A question with no photo is text only; the earlier photos stay in the conversation.
        session.send("What should I pay?")
        await waitIdle(session)
        let messages = try #require(transport.bodies[2]["messages"]?.array)
        #expect(messages.count == 3)
        #expect(messages[0]["content"]?.array?.first?["type"]?.string == "image")
        #expect(messages[2]["content"]?.array?.map { $0["type"]?.string } == ["text"])
    }
}
