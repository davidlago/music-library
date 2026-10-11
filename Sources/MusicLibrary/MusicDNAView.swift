import AppKit
import MusicLibraryCore
import SwiftUI

// MARK: Links to Music DNA

/// A person's name that opens their Music DNA. Looks like plain text until hovered.
/// `open` (usually `model.showMusicDNA`) comes from the parent rather than the environment: these links are
/// used in `Table` cells, which don't always get the app model from the environment and crash reading it.
struct PersonLink: View {
    @Environment(\.theme) private var theme
    let name: String
    let open: (String) -> Void
    @State private var hovering = false

    var body: some View {
        Button {
            open(name)
        } label: {
            Text(name)
                .underline(hovering)
                .foregroundStyle(hovering ? AnyShapeStyle(theme.accent) : AnyShapeStyle(.primary))
        }
        .buttonStyle(.plain)
        .onHover { h in
            guard h != hovering else { return }
            hovering = h
            if h { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .onDisappear { if hovering { hovering = false; NSCursor.pop() } }
        .help("Show \(name)'s Music DNA")
    }
}

/// Several names from a tag value ("A; B") as links, separated by commas.
struct PersonLinks: View {
    let names: [String]
    let open: (String) -> Void

    init(_ value: String, open: @escaping (String) -> Void) {
        names = CollaborationGraph.splitNames(value)
        self.open = open
    }

    init(names: [String], open: @escaping (String) -> Void) {
        self.names = names
        self.open = open
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(names.enumerated()), id: \.offset) { i, name in
                PersonLink(name: name, open: open)
                if i < names.count - 1 { Text(", ") }
            }
        }
        .lineLimit(1)
    }
}

/// Categorical colors for what people do, validated together (all pairs) for color-vision deficiency.
enum DNAColor {
    static func of(_ c: CollaborationGraph.Category) -> Color {
        switch c {
        case .performance: Color(light: 0x2a78d6, dark: 0x3987e5)
        case .writing: Color(light: 0x1baf7a, dark: 0x199e70)
        case .production: Color(light: 0xeb6834, dark: 0xd95926)
        }
    }
}

// MARK: Page

struct MusicDNAView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var hovered: Int?

    var body: some View {
        let graph = model.collaborations
        let center = model.dnaCenter.flatMap(graph.person(named:))
        VStack(spacing: 0) {
            header(center)
                .zIndex(1)
            Divider()
            if graph.people.isEmpty {
                ContentUnavailableView("No Credits Yet", systemImage: "point.3.connected.trianglepath.dotted",
                                       description: Text("Music DNA maps who played, wrote and produced together. It fills in as you import music matched to MusicBrainz."))
            } else if let center {
                let hood = graph.neighborhood(of: center.id, depth: model.dnaDepth)
                HStack(spacing: 0) {
                    DNAGraphView(neighborhood: hood, hovered: $hovered) { model.showMusicDNA($0.name) }
                    Divider()
                    DNADetailPanel(center: center, hovered: hovered.flatMap { id in hood.nodes.first { $0.id == id }?.person })
                        .frame(width: 300)
                }
                .onChange(of: center.id) { hovered = nil }
            } else if let name = model.dnaCenter {
                ContentUnavailableView("\(name) Isn't in Your Credits", systemImage: "person.crop.circle.badge.questionmark",
                                       description: Text("Nobody by that name appears in the credits of the music in your library."))
            } else {
                DNALanding()
            }
        }
        .navigationTitle("Music DNA")
        .navigationSubtitle(center?.name ?? "")
    }

    private func header(_ center: CollaborationGraph.Person?) -> some View {
        @Bindable var model = model
        return HStack(spacing: 12) {
            Button { model.musicDNABack() } label: { Image(systemName: "chevron.backward") }
                .disabled(model.dnaHistory.isEmpty)
                .help("Back to \(model.dnaHistory.last ?? "the previous person")")
            if center != nil {
                Button { model.clearMusicDNA() } label: { Image(systemName: "square.grid.2x2") }
                    .help("Start over with the best-connected people")
            }
            PersonPicker()
            Spacer()
            if center != nil {
                HStack(spacing: 6) {
                    Text("Levels").font(.callout).foregroundStyle(.subtext)
                    Picker("Levels", selection: $model.dnaDepth) {
                        Text("1").tag(1); Text("2").tag(2); Text("3").tag(3)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    .help("How many steps away from the center to show: collaborators, their collaborators, and so on")
                }
                DNALegend()
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}

struct DNALegend: View {
    var body: some View {
        HStack(spacing: 10) {
            ForEach(CollaborationGraph.Category.allCases, id: \.self) { c in
                HStack(spacing: 4) {
                    Circle().fill(DNAColor.of(c)).frame(width: 9, height: 9)
                    Text(c.rawValue).font(.caption).foregroundStyle(.subtext)
                }
            }
        }
        .help("Colored by what each person mostly does in your library")
    }
}

/// A search field that suggests people from the credits.
struct PersonPicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        let results = model.collaborations.search(text, limit: 8)
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.subtext)
            TextField("Find anyone in your credits", text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit { if let first = results.first { pick(first.name) } }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.fill))
        .frame(width: 300)
        .overlay(alignment: .topLeading) {
            if focused, !results.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(results) { p in
                        Button { pick(p.name) } label: {
                            HStack {
                                Circle().fill(DNAColor.of(p.category)).frame(width: 8, height: 8)
                                Text(p.name).lineLimit(1)
                                Spacer()
                                Text(p.roles.first ?? "").font(.caption).foregroundStyle(.subtext).lineLimit(1)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
                .frame(width: 300)
                .background(RoundedRectangle(cornerRadius: 8).fill(theme.isThemed ? theme.card : Color(nsColor: .windowBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.separator, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
                .offset(y: 36)
            }
        }
    }

    private func pick(_ name: String) {
        text = ""
        focused = false
        model.showMusicDNA(name)
    }
}

/// Starting points before anyone is picked.
struct DNALanding: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Music DNA").font(.largeTitle.bold())
                    Text("See who played, wrote and produced with whom across your library. Pick someone to put them at the center; click any bubble to follow the connections.")
                        .foregroundStyle(.subtext).frame(maxWidth: 640, alignment: .leading)
                }
                SectionHeader(title: "Most connected in your library")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 16)], alignment: .leading, spacing: 18) {
                    ForEach(model.collaborations.mostConnected(limit: 30)) { p in
                        Button { model.showMusicDNA(p.name) } label: {
                            VStack(spacing: 6) {
                                PersonBubble(person: p, size: 72)
                                Text(p.name).font(.callout.weight(.medium)).lineLimit(1)
                                Text("\(p.degree) collaborator\(p.degree == 1 ? "" : "s")").font(.caption).foregroundStyle(.subtext)
                            }
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(24)
        }
    }
}

/// A circle in the person's category color with their photo (if they're an artist with one) or initials.
struct PersonBubble: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    let person: CollaborationGraph.Person
    let size: CGFloat
    var highlighted = false

    var body: some View {
        let color = DNAColor.of(person.category)
        let hasPhoto = model.artistInfo.imageFile(for: person.name) != nil
        ZStack {
            Circle().fill(theme.isThemed ? theme.card : Color(nsColor: .controlBackgroundColor))
            Circle().fill(color.opacity(0.16))
            if hasPhoto {
                ArtistPhoto(name: person.name, size: size - 6)
            } else {
                Text(Self.initials(person.name))
                    .font(.system(size: max(9, size * 0.32), weight: .semibold, design: .rounded))
                    .foregroundStyle(color)
            }
        }
        .frame(width: size, height: size)
        .overlay(Circle().strokeBorder(color, lineWidth: highlighted ? 3.5 : max(1.5, size / 28)))
        .shadow(color: .black.opacity(highlighted ? 0.3 : 0.12), radius: highlighted ? 8 : 3, y: 2)
    }

    static func initials(_ name: String) -> String {
        name.split(separator: " ").filter { $0.contains(where: \.isLetter) }.prefix(2)
            .compactMap { $0.first(where: \.isLetter) }.map(String.init).joined().uppercased()
    }
}

// MARK: Graph

/// A line between two points whose ends animate when the layout changes.
struct EdgeShape: Shape {
    var from: CGPoint
    var to: CGPoint

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(from.x, from.y), AnimatablePair(to.x, to.y)) }
        set { from = CGPoint(x: newValue.first.first, y: newValue.first.second); to = CGPoint(x: newValue.second.first, y: newValue.second.second) }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: from)
        p.addLine(to: to)
        return p
    }
}

struct DNAGraphView: View {
    @Environment(\.theme) private var theme
    let neighborhood: CollaborationGraph.Neighborhood
    @Binding var hovered: Int?
    let onSelect: (CollaborationGraph.Person) -> Void
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @GestureState private var dragOffset: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1

    static func bubbleSize(level: Int) -> CGFloat { [104, 60, 42, 32][min(level, 3)] }

    var body: some View {
        let positions = CollaborationGraph.layout(neighborhood)
        let maxLevel = max(1, neighborhood.nodes.map(\.level).max() ?? 1)
        GeometryReader { geo in
            let scale = zoom * pinch
            let unit = max(40, (min(geo.size.width, geo.size.height) / 2 - 70) / CGFloat(maxLevel)) * scale
            let origin = CGPoint(x: geo.size.width / 2 + pan.width + dragOffset.width,
                                 y: geo.size.height / 2 + pan.height + dragOffset.height)
            let point: (Int) -> CGPoint = { id in
                let p = positions[id] ?? .zero
                return CGPoint(x: origin.x + p.x * unit, y: origin.y + p.y * unit)
            }
            // Bubbles shrink on crowded rings so neighbors don't overlap.
            let perLevel = Dictionary(grouping: neighborhood.nodes, by: \.level).mapValues(\.count)
            let size: (Int) -> CGFloat = { level in
                let base = Self.bubbleSize(level: level) * min(1.4, max(0.75, scale))
                guard level > 0, let n = perLevel[level], n > 0 else { return base }
                let room = 2 * .pi * unit * CGFloat(level) / CGFloat(n) * 0.72
                return max(22, min(base, room))
            }
            ZStack {
                // Panning starts on the empty background, so it never competes with clicks on bubbles.
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 3)
                        .updating($dragOffset) { v, s, _ in s = v.translation }
                        .onEnded { v in pan.width += v.translation.width; pan.height += v.translation.height })
                // Rings for the levels.
                ForEach(1...maxLevel, id: \.self) { level in
                    Circle()
                        .stroke(theme.separator.opacity(0.35), lineWidth: 0.5)
                        .frame(width: unit * CGFloat(level) * 2, height: unit * CGFloat(level) * 2)
                        .position(origin)
                        .allowsHitTesting(false)
                }
                ForEach(neighborhood.edges) { e in
                    let active = hovered == e.a || hovered == e.b
                    EdgeShape(from: point(e.a), to: point(e.b))
                        .stroke(active ? theme.accent : Color.primary.opacity(e.isTree ? 0.3 : 0.1),
                                lineWidth: active ? 2 : (e.isTree ? min(4, 1 + log2(CGFloat(e.weight))) : 0.75))
                        .allowsHitTesting(false)
                }
                ForEach(neighborhood.nodes) { node in
                    let bubble = size(node.level)
                    // Hover and clicks attach to the bubble itself, before it's positioned; after `.position`
                    // they would cover the whole graph.
                    Button { if node.level > 0 { onSelect(node.person) } } label: {
                        DNANodeView(node: node, size: bubble,
                                    isHovered: hovered == node.id, showsLabel: node.level <= 2 || hovered == node.id,
                                    outward: Self.labelDirection(layout: positions[node.id] ?? .zero, at: point(node.id),
                                                                 bubble: bubble, width: geo.size.width))
                    }
                    .buttonStyle(.plain)
                    .onHover { h in hovered = h ? node.id : (hovered == node.id ? nil : hovered) }
                    .help(help(for: node))
                    .position(point(node.id))
                    .transition(.scale.combined(with: .opacity))
                    .zIndex(hovered == node.id ? 2 : (node.level == 0 ? 1 : 0))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .simultaneousGesture(MagnifyGesture()
                .updating($pinch) { v, s, _ in s = v.magnification }
                .onEnded { v in zoom = min(3, max(0.4, zoom * v.magnification)) })
            .animation(.spring(duration: 0.6), value: neighborhood.center)
            .animation(.spring(duration: 0.4), value: neighborhood.nodes.count)
            .overlay(alignment: .bottomLeading) { controls }
        }
        .clipped()
        .onChange(of: neighborhood.center) { withAnimation(.spring(duration: 0.5)) { pan = .zero } }
    }

    /// Away from the center, flipped horizontally when the name would run off the side of the graph.
    static func labelDirection(layout p: CGPoint, at: CGPoint, bubble: CGFloat, width: CGFloat) -> CGVector {
        let length = hypot(p.x, p.y)
        var v = length > 0 ? CGVector(dx: p.x / length, dy: p.y / length) : CGVector(dx: 0, dy: 1)
        let reach = bubble / 2 + 6 + DNANodeView.labelWidth
        if abs(v.dx) > 0.35, (v.dx > 0 && at.x + reach > width - 4) || (v.dx < 0 && at.x - reach < 4) { v.dx = -v.dx }
        return v
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Button { withAnimation { zoom = max(0.4, zoom / 1.25) } } label: { Image(systemName: "minus.magnifyingglass") }
                .help("Zoom out")
            Button { withAnimation { zoom = 1; pan = .zero } } label: { Image(systemName: "scope") }
                .help("Fit")
            Button { withAnimation { zoom = min(3, zoom * 1.25) } } label: { Image(systemName: "plus.magnifyingglass") }
                .help("Zoom in")
            if neighborhood.hidden > 0 {
                Text("+\(neighborhood.hidden) more collaborators not shown").font(.caption).foregroundStyle(.subtext)
            }
        }
        .buttonStyle(.borderless)
        .padding(10)
    }

    private func help(for node: CollaborationGraph.Node) -> String {
        let p = node.person
        var s = "\(p.name) · \(p.roles.prefix(3).joined(separator: ", "))"
        if node.level > 0 { s += "\n\(node.shared) track\(node.shared == 1 ? "" : "s") with the person they connect to\nClick to center" }
        return s
    }
}

struct DNANodeView: View {
    let node: CollaborationGraph.Node
    let size: CGFloat
    let isHovered: Bool
    let showsLabel: Bool
    /// Unit vector pointing away from the center; the name sits on that side so neighbors on a ring
    /// don't collide.
    let outward: CGVector

    static let labelWidth: CGFloat = 116

    var body: some View {
        let shown = isHovered ? size * 1.12 : size
        // Outer rings are denser: one shorter line until hovered.
        let labelWidth = node.level >= 2 && !isHovered ? 96 : Self.labelWidth
        PersonBubble(person: node.person, size: shown, highlighted: isHovered || node.level == 0)
            .overlay {
                if showsLabel {
                    let horizontal = abs(outward.dx) > 0.35
                    Text(node.person.name)
                        .font(node.level == 0 ? .headline : (node.level == 1 ? .caption.weight(.medium) : .caption2))
                        .multilineTextAlignment(horizontal ? (outward.dx > 0 ? .leading : .trailing) : .center)
                        .lineLimit(node.level >= 2 && !isHovered ? 1 : 2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4).fill(.background.opacity(isHovered ? 0.95 : 0.7)))
                        .frame(width: labelWidth, alignment: horizontal ? (outward.dx > 0 ? .leading : .trailing) : .center)
                        .offset(x: outward.dx * (shown / 2 + 6 + (horizontal ? labelWidth / 2 : 0)),
                                y: outward.dy * (shown / 2 + 6) + (horizontal ? 0 : outward.dy * 9))
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Circle())
            .animation(.easeOut(duration: 0.15), value: isHovered)
    }
}

// MARK: Side panel

struct DNADetailPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    let center: CollaborationGraph.Person
    let hovered: CollaborationGraph.Person?

    var body: some View {
        let graph = model.collaborations
        let person = hovered ?? center
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    PersonBubble(person: person, size: 64, highlighted: true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(person.name).font(.title3.bold()).lineLimit(2)
                        HStack(spacing: 4) {
                            Circle().fill(DNAColor.of(person.category)).frame(width: 7, height: 7)
                            Text(person.category.rawValue).font(.caption).foregroundStyle(.subtext)
                        }
                        Text("\(songCount(person.trackCount)) · \(person.degree) collaborator\(person.degree == 1 ? "" : "s")")
                            .font(.caption).foregroundStyle(.subtext)
                    }
                }
                if !person.roles.isEmpty {
                    FlowLayout(spacing: 5) {
                        ForEach(person.roles.prefix(8), id: \.self) { r in
                            Text(r).font(.caption).padding(.horizontal, 7).padding(.vertical, 3)
                                .background(Capsule().fill(theme.fill))
                        }
                    }
                }
                HStack {
                    if hovered == nil {
                        Button { play(graph.tracks(of: person.id)) } label: { Label("Play All", systemImage: "play.fill") }
                    }
                    if let artist = model.artistSummary(named: person.name) {
                        Button("Artist Page") { model.navigationPath.append(artist) }
                            .help("Open \(artist.name)'s artist page")
                    }
                }
                .controlSize(.small)

                if let hovered, hovered.id != center.id {
                    let shared = graph.sharedTracks(center.id, hovered.id)
                    if shared.isEmpty {
                        Text("Connected to \(center.name) through other collaborators.").font(.callout).foregroundStyle(.subtext)
                    } else {
                        trackList("With \(center.name)", shared)
                    }
                    Text("Click the bubble to put \(hovered.name) at the center.").font(.caption).foregroundStyle(.subtext)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Top collaborators").font(.headline)
                        ForEach(graph.collaborators(of: center.id, limit: 10), id: \.person.id) { c in
                            HStack {
                                Circle().fill(DNAColor.of(c.person.category)).frame(width: 7, height: 7)
                                PersonLink(name: c.person.name) { model.showMusicDNA($0) }
                                Spacer()
                                Text("\(c.shared)").font(.caption).monospacedDigit().foregroundStyle(.subtext)
                                    .help("\(c.shared) shared track\(c.shared == 1 ? "" : "s")")
                            }
                            .font(.callout)
                        }
                    }
                    trackList("In your library", graph.tracks(of: center.id))
                }
            }
            .padding(16)
        }
    }

    private func trackList(_ title: String, _ ids: [Int64]) -> some View {
        let tracks = ids.compactMap { model.trackByID[$0] }
            .sorted { (model.playTotals[$0.id]?.plays ?? 0) > (model.playTotals[$1.id]?.plays ?? 0) }
        return VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            ForEach(Array(tracks.prefix(25).enumerated()), id: \.element.id) { i, t in
                Button { play(tracks, at: i) } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(t.title).lineLimit(1)
                        Text([t.artist, t.album].filter { !$0.isEmpty }.joined(separator: " — ")).font(.caption).foregroundStyle(.subtext).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Play")
            }
            if tracks.count > 25 { Text("and \(tracks.count - 25) more").font(.caption).foregroundStyle(.subtext) }
        }
    }

    private func play(_ ids: [Int64]) { play(ids.compactMap { model.trackByID[$0] }, at: 0) }

    private func play(_ tracks: [Track], at index: Int) {
        guard tracks.indices.contains(index) else { return }
        model.player.play(queue: tracks, startAt: index)
    }
}
