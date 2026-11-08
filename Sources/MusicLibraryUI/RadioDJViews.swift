import MusicLibraryCore
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// The Radio DJ's conversation as both apps draw it: the lines, the DJ's text with its links and icons, the photos the
// listener showed, the status row and the On Air sign. The Mac's panel and the iPhone's sheet (and their stores) stay in
// each app; they pass values in, never the app's model.

/// Sizes that differ between the Mac's panel and the iPhone's sheet; everything else is shared.
enum RadioDJMetrics {
    #if os(macOS)
    /// Room left beside the listener's bubble.
    static let bubbleInset: CGFloat = 40
    static let bubblePadding = EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
    static let bubbleRadius: CGFloat = 14
    /// A photo's side when the line shows several.
    static let smallPhoto: CGFloat = 72
    static let sourcePadding = EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8)
    /// How far around an icon a click still opens its link.
    static let iconSlop: CGFloat = 2
    static let signFont: CGFloat = 10, signTracking: CGFloat = 1.5, signRadius: CGFloat = 5, signGlow: CGFloat = 7
    static let signPadding = EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
    #else
    static let bubbleInset: CGFloat = 48
    static let bubblePadding = EdgeInsets(top: 9, leading: 14, bottom: 9, trailing: 14)
    static let bubbleRadius: CGFloat = 18
    static let smallPhoto: CGFloat = 68
    static let sourcePadding = EdgeInsets(top: 4, leading: 9, bottom: 4, trailing: 9)
    /// A finger is less precise than a pointer.
    static let iconSlop: CGFloat = 4
    static let signFont: CGFloat = 9, signTracking: CGFloat = 1.4, signRadius: CGFloat = 4, signGlow: CGFloat = 6
    static let signPadding = EdgeInsets(top: 3, leading: 6, bottom: 3, trailing: 6)
    #endif
}

// MARK: Lines

/// One line of the conversation: the listener's bubble (with the photos they showed) on the right, or the DJ's words
/// beside its avatar, with the web pages it cited as chips under them.
public struct RadioDJLineView: View {
    let line: RadioDJSession.Line
    let segments: [RadioDJSegment]
    let speaking: Bool

    /// `segments` are the DJ's words resolved into links (`RadioDJSession.segments(_:)`); empty for the listener.
    public init(line: RadioDJSession.Line, segments: [RadioDJSegment], speaking: Bool) {
        self.line = line
        self.segments = segments
        self.speaking = speaking
    }

    public var body: some View {
        switch line.role {
        case .listener:
            VStack(alignment: .trailing, spacing: 6) {
                if !line.photos.isEmpty {
                    HStack(spacing: 6) {
                        Spacer(minLength: RadioDJMetrics.bubbleInset)
                        ForEach(line.photos) {
                            RadioDJPhotoThumb(photo: $0, size: line.photos.count == 1 ? 160 : RadioDJMetrics.smallPhoto)
                        }
                    }
                }
                HStack {
                    Spacer(minLength: RadioDJMetrics.bubbleInset)
                    Text(line.text)
                        .textSelection(.enabled)
                        .foregroundStyle(.white)
                        .padding(RadioDJMetrics.bubblePadding)
                        .background(RoundedRectangle(cornerRadius: RadioDJMetrics.bubbleRadius).fill(AppColor.accent))
                }
            }
        case .dj:
            HStack(alignment: .top, spacing: 10) {
                DJAvatar(speaking: speaking)
                VStack(alignment: .leading, spacing: 10) {
                    words
                    if !line.sources.isEmpty {
                        FlowLayout(spacing: 6) {
                            ForEach(line.sources) { source in
                                Link(destination: source.url) {
                                    Label(source.host, systemImage: "link").font(.caption).lineLimit(1)
                                        .padding(RadioDJMetrics.sourcePadding)
                                        .background(Capsule().fill(AppColor.fill))
                                }
                                #if os(macOS)
                                .buttonStyle(.plain)
                                #endif
                                .help(source.title)
                                .accessibilityLabel("Source: \(source.title)")
                            }
                        }
                    }
                }
            }
        }
    }

    private var words: some View {
        #if os(macOS)
        // Not selectable: on the Mac, selectable text opens its links with the system, not `openURL`. Copy is in the
        // context menu instead.
        RadioDJText.text(segments)
            .font(.body)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .modifier(IconLinks())
            .contextMenu {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(RadioDJText.plain(segments), forType: .string)
                }
            }
        #else
        RadioDJText.text(segments)
            .font(.body)
            .lineSpacing(3)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .modifier(IconLinks())
        #endif
    }
}

/// What the DJ is doing right now ("Searching the web…"), with the bars bouncing.
public struct RadioDJStatusRow: View {
    let text: String

    public init(text: String) { self.text = text }

    public var body: some View {
        HStack(spacing: 10) {
            EqualizerBars().frame(width: 28, height: 16)
            Text(text).font(.callout).italic().foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(.leading, 2)
    }
}

/// A photo the listener showed (or is about to show) the DJ, cropped to a square.
public struct RadioDJPhotoThumb: View {
    let photo: RadioDJPhoto
    let size: CGFloat

    public init(photo: RadioDJPhoto, size: CGFloat) {
        self.photo = photo
        self.size = size
    }

    public var body: some View {
        Group {
            if let image = Self.image(photo.thumbnail) {
                image.resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.15), lineWidth: 1))
        .accessibilityLabel("Photo")
    }

    private static func image(_ data: Data) -> Image? {
        #if os(macOS)
        NSImage(data: data).map { Image(nsImage: $0) }
        #else
        UIImage(data: data).map { Image(uiImage: $0) }
        #endif
    }
}

/// The red sign over the studio door, glowing while the DJ is talking or looking something up.
public struct OnAirSign: View {
    let live: Bool

    public init(live: Bool) { self.live = live }

    public var body: some View {
        Text("ON AIR")
            .font(.system(size: RadioDJMetrics.signFont, weight: .heavy, design: .rounded))
            .tracking(RadioDJMetrics.signTracking)
            .foregroundStyle(.white)
            .padding(RadioDJMetrics.signPadding)
            .background(RoundedRectangle(cornerRadius: RadioDJMetrics.signRadius).fill(Color.red.gradient))
            .shadow(color: .red.opacity(live ? 0.8 : 0.25), radius: live ? RadioDJMetrics.signGlow : 2)
            .animation(live ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default, value: live)
    }
}

// MARK: The DJ's text

/// The DJ's words in one `Text` (so they select and wrap as one): links to the collection, and songs to play with a
/// play icon before them. Links to what you own are in the accent color, the rest (previews, web pages) in `outside`.
public enum RadioDJText {
    /// The light red at the top of the On Air sign's gradient.
    public static let outside = Color(red: 1, green: 0.42, blue: 0.39)

    /// What the line says, without links (for Copy).
    public static func plain(_ segments: [RadioDJSegment]) -> String {
        segments.map { segment in
            switch segment {
            case .text(let words), .play(let words), .preview(let words), .external(let words): String(words.characters)
            }
        }.joined()
    }

    public static func text(_ segments: [RadioDJSegment], accent: Color = AppColor.accent) -> Text {
        segments.reduce(Text(verbatim: "")) { text, segment in
            switch segment {
            case .text(let words):
                return Text("\(text)\(words)")
            case .play(let title):
                let icon = linked(Text(Image(systemName: "play.circle.fill")).foregroundStyle(accent), to: title)
                return Text("\(text)\(icon)\u{202F}\(title)")
            case .preview(var title):
                // Not yours: a 30-second sample, in headphones rather than the play button, in the not-yours color.
                title.foregroundColor = outside
                let icon = linked(Text(Image(systemName: "headphones.circle")).foregroundStyle(outside), to: title)
                return Text("\(text)\(icon)\u{202F}\(title)")
            case .external(var title):
                // Not yours: opens a page on the web.
                title.foregroundColor = outside
                let icon = linked(Text(Image(systemName: "arrow.up.right.square")).font(.caption).foregroundStyle(outside), to: title)
                return Text("\(text)\(title)\u{202F}\(icon)")
            }
        }
    }

    /// An icon goes where its title's link does (`IconLinks`): a symbol in a `Text` can't carry a link itself.
    private static func linked(_ icon: Text, to title: AttributedString) -> Text {
        guard #available(macOS 15, iOS 18, *), let url = title.runs.first?.link else { return icon }
        return icon.customAttribute(IconLink(url: url))
    }
}

/// Where an icon's run in the DJ's text links to.
@available(macOS 15, iOS 18, *)
public struct IconLink: TextAttribute {
    public let url: URL

    public init(url: URL) { self.url = url }
}

/// Makes the icons beside the DJ's links (play, preview, web page) open like the links: the text is drawn as usual
/// while noting where those icons are, and a click or tap on one opens its link (with `openURL`, as the links do). On
/// the Mac the pointer turns into the pointing hand over an icon. Before macOS 15 only the words are links.
public struct IconLinks: ViewModifier {
    @Environment(\.openURL) private var openURL
    @State private var icons = IconLinkFrames()
    #if os(macOS)
    @State private var overIcon = false
    #endif

    public init() {}

    public func body(content: Content) -> some View {
        if #available(macOS 15, iOS 18, *) {
            content
                .textRenderer(IconLinkRenderer(icons: icons))
                .simultaneousGesture(SpatialTapGesture().onEnded { tap in
                    if let url = icons.url(at: tap.location) { openURL(url) }
                })
                #if os(macOS)
                .onContinuousHover { phase in
                    // The pointing hand over an icon, as over a link; the cursor is left alone elsewhere (links set theirs).
                    var over = false
                    if case .active(let p) = phase { over = icons.url(at: p) != nil }
                    if over { NSCursor.pointingHand.set() } else if overIcon { NSCursor.arrow.set() }
                    overIcon = over
                }
                #endif
        } else {
            content
        }
    }
}

/// The icons' frames as last drawn (a reference, so drawing doesn't update the view).
public final class IconLinkFrames {
    var frames: [(rect: CGRect, url: URL)] = []

    public init() {}

    func url(at point: CGPoint) -> URL? {
        frames.first { $0.rect.insetBy(dx: -RadioDJMetrics.iconSlop, dy: -RadioDJMetrics.iconSlop).contains(point) }?.url
    }
}

@available(macOS 15, iOS 18, *)
private struct IconLinkRenderer: TextRenderer {
    let icons: IconLinkFrames

    func draw(layout: Text.Layout, in ctx: inout GraphicsContext) {
        var frames: [(rect: CGRect, url: URL)] = []
        for line in layout {
            for run in line {
                if let link = run[IconLink.self] { frames.append((run.typographicBounds.rect, link.url)) }
                ctx.draw(run)
            }
        }
        icons.frames = frames
    }
}
