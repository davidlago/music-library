import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// Small views both apps draw the same way.

/// Lays children out left to right, wrapping onto new lines as needed.
public struct FlowLayout: Layout {
    var spacing: CGFloat

    public init(spacing: CGFloat = 6) {
        self.spacing = spacing
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal.width ?? .infinity, subviews)
        return CGSize(width: rows.map(\.width).max() ?? 0, height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(bounds.width, subviews) {
            var x = bounds.minX
            for i in row.indices {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private func arrange(_ maxWidth: CGFloat, _ subviews: Subviews) -> [(indices: [Int], y: CGFloat, width: CGFloat, height: CGFloat)] {
        var rows: [(indices: [Int], y: CGFloat, width: CGFloat, height: CGFloat)] = []
        var current: [Int] = [], x: CGFloat = 0, y: CGFloat = 0, height: CGFloat = 0
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            if !current.isEmpty, x + size.width > maxWidth {
                rows.append((current, y, x - spacing, height))
                y += height + spacing
                current = []; x = 0; height = 0
            }
            current.append(i)
            x += size.width + spacing
            height = max(height, size.height)
        }
        if !current.isEmpty { rows.append((current, y, x - spacing, height)) }
        return rows
    }
}

/// An artist without a photo: their initials in a circle ("Rachael & Vilray" → "RV"), or a microphone when the name
/// has no letters.
public struct InitialsBadge: View {
    let name: String
    var size: CGFloat

    public init(name: String, size: CGFloat = 76) {
        self.name = name
        self.size = size
    }

    public var body: some View {
        // "Rachael & Vilray" → "RV": skip words without letters.
        let initials = name.split(separator: " ").filter { $0.contains(where: \.isLetter) }.prefix(2)
            .compactMap { $0.first(where: \.isLetter) }.map(String.init).joined()
        ZStack {
            #if os(macOS)
            Circle().fill(.quaternary)
            #else
            Circle().fill(Color(.tertiarySystemFill))
            #endif
            if initials.isEmpty {
                Image(systemName: "music.mic").font(.system(size: size / 3)).foregroundStyle(.secondary)
            } else {
                Text(initials.uppercased()).font(.system(size: size / 3, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
    }
}

/// Five stars with halves, plus the vote count.
public struct RatingView: View {
    let rating: Double
    let votes: Int

    public init(rating: Double, votes: Int) {
        self.rating = rating
        self.votes = votes
    }

    public var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 1) {
                ForEach(0..<5) { i in
                    let fill = rating - Double(i)
                    Image(systemName: fill >= 0.75 ? "star.fill" : (fill >= 0.25 ? "star.leadinghalf.filled" : "star"))
                }
            }
            .foregroundStyle(Color.accentColor)
            Text(String(format: "%.1f", rating)).monospacedDigit().fontWeight(.semibold)
            Text("· \(votes) MusicBrainz rating\(votes == 1 ? "" : "s")").foregroundStyle(.secondary)
        }
        #if os(macOS)
        .font(.callout)
        .help("Community rating on MusicBrainz")
        #else
        .font(.footnote)
        #endif
        .accessibilityElement(children: .combine)
    }
}

/// "↑ 13%" or "↓ 4%"; on a dark panel it's white, elsewhere the arrow is green or red.
public struct DeltaLabel: View {
    let delta: Double
    var onPanel: Bool

    public init(delta: Double, onPanel: Bool = false) {
        self.delta = delta
        self.onPanel = onPanel
    }

    public var body: some View {
        let up = delta >= 0
        HStack(spacing: 2) {
            Image(systemName: up ? "arrow.up" : "arrow.down").fontWeight(.bold)
                .foregroundStyle(onPanel ? AnyShapeStyle(.white) : AnyShapeStyle(up ? Color.green : Color.red))
            Text(abs(delta).formatted(.percent.precision(.fractionLength(0))))
                .foregroundStyle(onPanel ? AnyShapeStyle(.white.opacity(0.9)) : AnyShapeStyle(.secondary))
        }
        .font(.caption.weight(.semibold)).monospacedDigit()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(up ? "Up" : "Down") \(abs(delta).formatted(.percent.precision(.fractionLength(0))))")
    }
}

/// A row of small bars, the shape of a ranking at a glance.
public struct MiniBars: View {
    let values: [Double]
    var height: CGFloat

    public init(values: [Double], height: CGFloat = Self.defaultHeight) {
        self.values = values
        self.height = height
    }

    #if os(macOS)
    public static let defaultHeight: CGFloat = 26
    #else
    public static let defaultHeight: CGFloat = 24
    #endif

    public var body: some View {
        let top = max(values.max() ?? 1, 0.0001)
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, v in
                RoundedRectangle(cornerRadius: 1).fill(.white.opacity(0.9))
                    .frame(width: 4, height: max(2, height * v / top))
            }
        }
        .frame(height: height, alignment: .bottom)
        .accessibilityHidden(true)
    }
}

// MARK: Radio DJ

/// The DJ's symbol: a chat bubble with sparkles (an AI to talk with), or sparkles alone on systems without it.
public enum RadioDJIcon {
    public static let name = symbol("text.bubble.badge.sparkles")
    public static func name(filled: Bool) -> String { filled ? symbol("text.bubble.badge.sparkles.fill") : name }

    private static func symbol(_ preferred: String) -> String {
        #if os(macOS)
        NSImage(systemSymbolName: preferred, accessibilityDescription: nil) != nil ? preferred : "sparkles"
        #else
        UIImage(systemName: preferred) != nil ? preferred : "sparkles"
        #endif
    }
}

/// The DJ's picture beside its lines: a microphone, or bouncing bars while it speaks.
public struct DJAvatar: View {
    let speaking: Bool

    public init(speaking: Bool) {
        self.speaking = speaking
    }

    public var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [.orange, .pink], startPoint: .topLeading, endPoint: .bottomTrailing))
            if speaking {
                EqualizerBars(color: .white).frame(width: 14, height: 12)
            } else {
                Image(systemName: "music.mic").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
            }
        }
        .frame(width: 30, height: 30)
    }
}

/// Four bars bouncing like a VU meter.
public struct EqualizerBars: View {
    var color: Color

    public init(color: Color = .orange) {
        self.color = color
    }

    public var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                HStack(alignment: .bottom, spacing: geo.size.width * 0.12) {
                    ForEach(0..<4) { i in
                        let level = 0.3 + 0.7 * abs(sin(t * (3.1 + Double(i) * 0.9) + Double(i) * 1.7))
                        RoundedRectangle(cornerRadius: 1.5).fill(color)
                            .frame(height: geo.size.height * level)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
    }
}
