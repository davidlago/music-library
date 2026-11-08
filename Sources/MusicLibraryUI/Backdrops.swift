import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A picture (an album's cover, an artist's photo), blurred and faded into the page background, filling the page
/// behind album, artist, collection item and Listen Now pages. Without a picture it's just the page background.
public struct AlbumBackdrop: View {
    let image: Image?

    public init(picture: Image?) {
        self.image = picture
    }

    #if os(macOS)
    public init(image: NSImage?) {
        self.image = image.map { Image(nsImage: $0) }
    }

    /// The blur scales with the window, which is larger than a phone's screen.
    static let blur: CGFloat = 70
    #else
    public init(image: UIImage?) {
        self.image = image.map { Image(uiImage: $0) }
    }

    static let blur: CGFloat = 50
    #endif

    public var body: some View {
        GeometryReader { geo in
            ZStack {
                AppColor.background
                if let image {
                    image.resizable().scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .blur(radius: Self.blur)
                        .saturation(1.3)
                        .opacity(0.7)
                        .clipped()
                    // Lightly tinted at the top, then into the plain background so a long page ends cleanly.
                    LinearGradient(colors: [AppColor.background.opacity(0.1), AppColor.background.opacity(0.75), AppColor.background],
                                   startPoint: .top, endPoint: .bottom)
                }
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}
