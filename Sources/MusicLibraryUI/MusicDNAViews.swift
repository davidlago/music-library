import MusicLibraryCore
import SwiftUI

// The pieces of Music DNA both apps draw the same way: the category colours and legend, a person's bubble, the edges
// and the labelled nodes of the graph. The pages around them (navigation, search, the detail panel) stay in each app.

/// Categorical colours for what people do, validated together (all pairs) for colour-vision deficiency.
public enum DNAColor {
    public static func of(_ c: CollaborationGraph.Category) -> Color {
        switch c {
        case .performance: Color(light: 0x2a78d6, dark: 0x3987e5)
        case .writing: Color(light: 0x1baf7a, dark: 0x199e70)
        case .production: Color(light: 0xeb6834, dark: 0xd95926)
        }
    }
}

/// The three categories with their colours.
public struct DNALegend: View {
    public init() {}

    public var body: some View {
        HStack(spacing: 12) {
            ForEach(CollaborationGraph.Category.allCases, id: \.self) { c in
                HStack(spacing: 4) {
                    Circle().fill(DNAColor.of(c)).frame(width: 9, height: 9)
                    Text(c.rawValue).font(.caption).foregroundStyle(.secondary).fixedSize()
                }
            }
        }
        #if os(macOS)
        .help(Self.meaning)
        #endif
        .accessibilityElement(children: .combine)
        .accessibilityHint(Self.meaning)
    }

    static let meaning = "Colored by what each person mostly does in your music"
}

/// "12 collaborators"
public func dnaCollaborators(_ n: Int) -> String { "\(n.formatted()) collaborator\(n == 1 ? "" : "s")" }

/// A circle in the person's category colour with their photo (if they're an artist with one, which the app passes
/// as `photo`) or their initials.
public struct DNABubble<Photo: View>: View {
    let person: CollaborationGraph.Person
    let size: CGFloat
    var highlighted: Bool
    var photo: Photo?

    public init(person: CollaborationGraph.Person, size: CGFloat, highlighted: Bool = false, photo: Photo?) {
        self.person = person
        self.size = size
        self.highlighted = highlighted
        self.photo = photo
    }

    #if os(macOS)
    static var surface: Color { AppColor.card }
    #else
    static var surface: Color { Color(.secondarySystemBackground) }
    #endif

    public var body: some View {
        let color = DNAColor.of(person.category)
        ZStack {
            Circle().fill(Self.surface)
            Circle().fill(color.opacity(0.16))
            if let photo {
                photo
            } else {
                Text(DNABubbleInitials.of(person.name))
                    .font(.system(size: max(9, size * 0.32), weight: .semibold, design: .rounded))
                    .foregroundStyle(color)
                    .minimumScaleFactor(0.5)
            }
        }
        .frame(width: size, height: size)
        .overlay(Circle().strokeBorder(color, lineWidth: highlighted ? 3.5 : max(1.5, size / 28)))
        .shadow(color: .black.opacity(highlighted ? 0.3 : 0.12), radius: highlighted ? 8 : 3, y: 2)
    }
}

extension DNABubble where Photo == EmptyView {
    /// A bubble with initials only.
    public init(person: CollaborationGraph.Person, size: CGFloat, highlighted: Bool = false) {
        self.init(person: person, size: size, highlighted: highlighted, photo: nil)
    }
}

/// "Rachael & Vilray" → "RV": the first letters of the first two words that have letters.
public enum DNABubbleInitials {
    public static func of(_ name: String) -> String {
        name.split(separator: " ").filter { $0.contains(where: \.isLetter) }.prefix(2)
            .compactMap { $0.first(where: \.isLetter) }.map(String.init).joined().uppercased()
    }
}

/// A line between two points whose ends animate when the layout changes.
public struct DNAEdgeShape: Shape {
    public var from: CGPoint
    public var to: CGPoint

    public init(from: CGPoint, to: CGPoint) {
        self.from = from
        self.to = to
    }

    public var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(from.x, from.y), AnimatablePair(to.x, to.y)) }
        set { from = CGPoint(x: newValue.first.first, y: newValue.first.second); to = CGPoint(x: newValue.second.first, y: newValue.second.second) }
    }

    public func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: from)
        p.addLine(to: to)
        return p
    }
}

/// Sizes of the graph's names, which differ between the Mac's window and the phone.
public enum DNANodeMetrics {
    #if os(macOS)
    /// The widest a name gets (outer rings are narrower until highlighted).
    public static let labelWidth: CGFloat = 116
    static let outerLabelWidth: CGFloat = 96
    /// The space between a bubble and its name.
    public static let gap: CGFloat = 6
    static let centerFont: Font = .headline
    static let nearFont: Font = .caption.weight(.medium)
    #else
    public static let labelWidth: CGFloat = 100
    static let outerLabelWidth: CGFloat = 84
    public static let gap: CGFloat = 5
    static let centerFont: Font = .subheadline.weight(.semibold)
    static let nearFont: Font = .caption2.weight(.medium)
    #endif
}

/// One person in the graph: their bubble (drawn by the app, `bubble(size, highlighted)`) and their name on the side
/// facing away from the centre. `isHighlighted` is the hovered bubble on the Mac, the selected one on the iPhone.
public struct DNANodeView<Bubble: View>: View {
    let node: CollaborationGraph.Node
    let size: CGFloat
    let isHighlighted: Bool
    let showsLabel: Bool
    /// Unit vector pointing away from the center; the name sits on that side so neighbors on a ring don't collide.
    let outward: CGVector
    let bubble: (CGFloat, Bool) -> Bubble

    public init(node: CollaborationGraph.Node, size: CGFloat, isHighlighted: Bool, showsLabel: Bool, outward: CGVector,
                @ViewBuilder bubble: @escaping (_ size: CGFloat, _ highlighted: Bool) -> Bubble) {
        self.node = node
        self.size = size
        self.isHighlighted = isHighlighted
        self.showsLabel = showsLabel
        self.outward = outward
        self.bubble = bubble
    }

    public var body: some View {
        let shown = isHighlighted ? size * 1.12 : size
        // Outer rings are denser: one shorter line until highlighted.
        let labelWidth = node.level >= 2 && !isHighlighted ? DNANodeMetrics.outerLabelWidth : DNANodeMetrics.labelWidth
        bubble(shown, isHighlighted || node.level == 0)
            .overlay {
                if showsLabel {
                    let horizontal = abs(outward.dx) > 0.35
                    Text(node.person.name)
                        .font(node.level == 0 ? DNANodeMetrics.centerFont : (node.level == 1 || isHighlighted ? DNANodeMetrics.nearFont : .caption2))
                        .multilineTextAlignment(horizontal ? (outward.dx > 0 ? .leading : .trailing) : .center)
                        .lineLimit(node.level >= 2 && !isHighlighted ? 1 : 2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4).fill(.background.opacity(isHighlighted ? 0.95 : 0.7)))
                        .frame(width: labelWidth, alignment: horizontal ? (outward.dx > 0 ? .leading : .trailing) : .center)
                        .offset(x: outward.dx * (shown / 2 + DNANodeMetrics.gap + (horizontal ? labelWidth / 2 : 0)),
                                y: outward.dy * (shown / 2 + DNANodeMetrics.gap) + (horizontal ? 0 : outward.dy * (DNANodeMetrics.gap + 3)))
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Circle())
            .animation(.easeOut(duration: 0.15), value: isHighlighted)
    }
}
