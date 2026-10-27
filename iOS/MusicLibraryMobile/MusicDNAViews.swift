import MusicLibraryCore
import SwiftUI

// MARK: Colors

/// Categorical colors for what people do, the Mac's palette (validated together for color-vision deficiency),
/// adapting to light and dark mode.
enum DNAPalette {
    static let performance = Color(uiColor: dynamic(light: 0x2a78d6, dark: 0x3987e5))
    static let writing = Color(uiColor: dynamic(light: 0x1baf7a, dark: 0x199e70))
    static let production = Color(uiColor: dynamic(light: 0xeb6834, dark: 0xd95926))

    static func of(_ c: CollaborationGraph.Category) -> Color {
        switch c {
        case .performance: performance
        case .writing: writing
        case .production: production
        }
    }

    nonisolated private static func dynamic(light: UInt32, dark: UInt32) -> UIColor {
        UIColor { traits in rgb(traits.userInterfaceStyle == .dark ? dark : light) }
    }

    nonisolated private static func rgb(_ hex: UInt32) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }
}

// MARK: Page

/// Music DNA, centered on `name` (nil: the starting page). Each person opened is pushed onto the stack, so Back
/// returns to the previous one; the grid button starts over from the best-connected people.
struct MusicDNAPage: View {
    @Environment(PhoneModel.self) private var model
    @Environment(\.openRoute) private var openRoute
    let name: String?
    @State private var searching = false

    var body: some View {
        Group {
            if let library = model.library {
                let graph = library.collaborations
                if graph.people.isEmpty {
                    ContentUnavailableView("No Credits Yet", systemImage: "point.3.connected.trianglepath.dotted",
                                           description: Text("Music DNA maps who played, wrote and produced together. It fills in as you add music, CDs and records matched to MusicBrainz on your Mac."))
                        .navigationTitle("Music DNA")
                } else if let name {
                    Group {
                        if let center = graph.person(named: name) {
                            DNAPersonPage(graph: graph, center: center)
                                .radioDJPage(.page("Music DNA, centered on \(name)", details: ["Who \(name) played, wrote and produced with across their collection."]))
                        } else {
                            ContentUnavailableView("\(name) Isn't in Your Credits", systemImage: "person.crop.circle.badge.questionmark",
                                                   description: Text("Nobody by that name appears in the credits of your music, digital or physical."))
                                .navigationTitle("Music DNA")
                        }
                    }
                    .toolbar {
                        ToolbarItemGroup(placement: .topBarTrailing) {
                            Button("Find Someone", systemImage: "magnifyingglass") { searching = true }
                            Button("Start Over", systemImage: "square.grid.2x2") { openRoute(DNARoute(name: nil)) }
                                .accessibilityHint("Shows the best-connected people in your music")
                        }
                    }
                    .sheet(isPresented: $searching) {
                        DNASearchSheet(graph: graph) { picked in
                            searching = false
                            openRoute(DNARoute(name: picked))
                        }
                    }
                } else {
                    DNALanding(graph: graph)
                        .radioDJPage(.page("Music DNA", details: ["The best-connected people in their music."]))
                }
            } else {
                LibraryStatusView().navigationTitle("Music DNA")
            }
        }
    }
}

// MARK: Starting page and search

/// Starting points before anyone is picked: a search over the credits and the best-connected people.
private struct DNALanding: View {
    @Environment(\.openRoute) private var openRoute
    let graph: CollaborationGraph
    @State private var query = ""

    var body: some View {
        let results = graph.search(query, limit: 40)
        Group {
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("See who played, wrote and produced with whom across your digital and physical collections. Pick someone to put them at the center; tap any bubble to follow the connections.")
                            .foregroundStyle(.secondary)
                        DNALegend()
                        SectionHeader(title: "Most connected in your music")
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), alignment: .center, spacing: 20) {
                            ForEach(graph.mostConnected(limit: 30)) { p in
                                NavigationLink(value: DNARoute(name: p.name)) {
                                    VStack(spacing: 6) {
                                        DNABubble(person: p, size: 76)
                                        Text(p.name).font(.footnote.weight(.medium)).lineLimit(1)
                                        Text(dnaCollaborators(p.degree)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityElement(children: .combine)
                            }
                        }
                    }
                    .padding()
                }
            } else {
                List(results) { p in
                    NavigationLink(value: DNARoute(name: p.name)) { DNAPersonRow(person: p) }
                }
                .listStyle(.plain)
                .overlay { if results.isEmpty { ContentUnavailableView.search(text: query) } }
            }
        }
        .navigationTitle("Music DNA")
        .searchable(text: $query, prompt: "Find anyone in your credits")
        .onSubmit(of: .search) { if let first = results.first { openRoute(DNARoute(name: first.name)) } }
    }
}

/// Finding someone from a person's page.
private struct DNASearchSheet: View {
    @Environment(\.dismiss) private var dismiss
    let graph: CollaborationGraph
    let pick: (String) -> Void
    @State private var query = ""

    var body: some View {
        let empty = query.trimmingCharacters(in: .whitespaces).isEmpty
        let results = empty ? graph.mostConnected(limit: 30) : graph.search(query, limit: 40)
        NavigationStack {
            List {
                Section {
                    ForEach(results) { p in
                        Button { pick(p.name) } label: { DNAPersonRow(person: p).contentShape(Rectangle()) }
                            .buttonStyle(.plain)
                    }
                } header: {
                    if empty { Text("Most connected in your music") }
                }
            }
            .listStyle(.plain)
            .overlay { if !empty, results.isEmpty { ContentUnavailableView.search(text: query) } }
            .navigationTitle("Find Someone")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Find anyone in your credits")
            .onSubmit(of: .search) { if let first = results.first, !empty { pick(first.name) } }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", role: .cancel) { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// A search result: category color, name, main role.
private struct DNAPersonRow: View {
    let person: CollaborationGraph.Person

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(DNAPalette.of(person.category)).frame(width: 9, height: 9)
                .accessibilityLabel(person.category.rawValue)
            Text(person.name).lineLimit(1)
            Spacer(minLength: 8)
            Text(person.roles.first ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

private struct DNALegend: View {
    var body: some View {
        HStack(spacing: 12) {
            ForEach(CollaborationGraph.Category.allCases, id: \.self) { c in
                HStack(spacing: 4) {
                    Circle().fill(DNAPalette.of(c)).frame(width: 9, height: 9)
                    Text(c.rawValue).font(.caption).foregroundStyle(.secondary).fixedSize()
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Colored by what each person mostly does in your music")
    }
}

private func dnaCollaborators(_ n: Int) -> String { "\(n.formatted()) collaborator\(n == 1 ? "" : "s")" }

/// A circle in the person's category color with their photo (if they're an artist with one) or initials.
private struct DNABubble: View {
    @Environment(PhoneModel.self) private var model
    let person: CollaborationGraph.Person
    let size: CGFloat
    var highlighted = false

    var body: some View {
        let color = DNAPalette.of(person.category)
        let hasPhoto = model.library?.artistImageURL(person.name) != nil
        ZStack {
            Circle().fill(Color(.secondarySystemBackground))
            Circle().fill(color.opacity(0.16))
            if hasPhoto {
                ArtistPhoto(name: person.name, size: size - 6)
            } else {
                Text(Self.initials(person.name))
                    .font(.system(size: max(9, size * 0.32), weight: .semibold, design: .rounded))
                    .foregroundStyle(color)
                    .minimumScaleFactor(0.5)
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

// MARK: Person page

/// The graph around one person, with what they (or the selected bubble) did below it.
private struct DNAPersonPage: View {
    @Environment(\.openRoute) private var openRoute
    @AppStorage("musicDNADepth") private var depth = 2
    let graph: CollaborationGraph
    let center: CollaborationGraph.Person
    @State private var selected: Int?

    var body: some View {
        let levels = min(3, max(1, depth))
        let hood = graph.neighborhood(of: center.id, depth: levels)
        let selectedNode = selected.flatMap { id in hood.nodes.first { $0.id == id && $0.level > 0 } }
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                DNAGraph(neighborhood: hood, selected: $selected) { openRoute(DNARoute(name: $0.name)) }
                    .frame(maxWidth: .infinity)
                    .containerRelativeFrame(.vertical) { height, _ in min(560, max(320, height * 0.55)) }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    DNALegend()
                    Spacer(minLength: 4)
                    if hood.hidden > 0 {
                        Text("+\(hood.hidden) more").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            .accessibilityLabel("\(hood.hidden) more collaborators not shown")
                    }
                }
                .padding(.horizontal).padding(.vertical, 8)
                Divider()
                DNADetail(graph: graph, center: center, selected: selectedNode, hood: hood, selection: $selected)
                    .padding()
            }
        }
        .navigationTitle(center.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Levels", selection: Binding(get: { levels }, set: { depth = $0 })) {
                        Text("1 Level: Collaborators").tag(1)
                        Text("2 Levels: Their Collaborators").tag(2)
                        Text("3 Levels").tag(3)
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Levels", systemImage: "circle.circle")
                }
                .accessibilityHint("How many steps away from the center to show: collaborators, their collaborators, and so on")
            }
        }
        .sensoryFeedback(.selection, trigger: selected)
        .onChange(of: depth) { _, newDepth in
            // Forget a selection the new levels no longer show.
            guard let id = selected else { return }
            let nodes = graph.neighborhood(of: center.id, depth: min(3, max(1, newDepth))).nodes
            if !nodes.contains(where: { $0.id == id }) { selected = nil }
        }
    }
}

// MARK: Graph

/// A line between two points whose ends animate when the layout changes.
nonisolated private struct DNAEdgeShape: Shape {
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

/// Rings, edges and bubbles. Pinch to zoom, drag to pan; tapping a bubble selects it, tapping it again centers
/// on it, tapping the center or the background clears the selection.
private struct DNAGraph: View {
    let neighborhood: CollaborationGraph.Neighborhood
    @Binding var selected: Int?
    let onOpen: (CollaborationGraph.Person) -> Void
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @GestureState private var dragOffset: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1

    static let minZoom: CGFloat = 0.4
    static let maxZoom: CGFloat = 3.5

    static func bubbleSize(level: Int) -> CGFloat { [84, 48, 36, 28][min(level, 3)] }

    var body: some View {
        let positions = CollaborationGraph.layout(neighborhood)
        let maxLevel = max(1, neighborhood.nodes.map(\.level).max() ?? 1)
        GeometryReader { geo in
            let scale = zoom * pinch
            let unit = max(34, (min(geo.size.width, geo.size.height) / 2 - 46) / CGFloat(maxLevel)) * scale
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
                return max(20, min(base, room))
            }
            ZStack {
                // Tapping empty space clears the selection.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.snappy) { selected = nil } }
                ForEach(1...maxLevel, id: \.self) { level in
                    Circle()
                        .stroke(Color(.separator).opacity(0.5), lineWidth: 0.5)
                        .frame(width: unit * CGFloat(level) * 2, height: unit * CGFloat(level) * 2)
                        .position(origin)
                        .allowsHitTesting(false)
                }
                ForEach(neighborhood.edges) { e in
                    let active = selected == e.a || selected == e.b
                    DNAEdgeShape(from: point(e.a), to: point(e.b))
                        .stroke(active ? Color.accentColor : Color.primary.opacity(e.isTree ? 0.3 : 0.1),
                                lineWidth: active ? 2 : (e.isTree ? min(4, 1 + log2(CGFloat(max(1, e.weight)))) : 0.75))
                        .allowsHitTesting(false)
                }
                ForEach(neighborhood.nodes) { node in
                    let bubble = size(node.level)
                    let isSelected = selected == node.id
                    // Taps attach to the bubble itself, before it's positioned; after `.position` they would
                    // cover the whole graph.
                    Button { tap(node) } label: {
                        DNANodeView(node: node, size: bubble, isSelected: isSelected,
                                    showsLabel: node.level <= 1 || isSelected || (node.level == 2 && scale >= 1.6) || scale >= 2.4,
                                    outward: Self.labelDirection(layout: positions[node.id] ?? .zero, at: point(node.id),
                                                                 bubble: bubble, width: geo.size.width))
                            // A slightly bigger target than the bubble, for fingers.
                            .padding(bubble < 40 ? 6 : 2)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(node.person.name)
                    .accessibilityValue(accessibilityValue(node))
                    .accessibilityHint(node.level == 0 ? "" : (isSelected ? "Double-tap to put them at the center" : "Double-tap to select"))
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                    .position(point(node.id))
                    .transition(.scale.combined(with: .opacity))
                    .zIndex(isSelected ? 2 : (node.level == 0 ? 1 : 0))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 8)
                .updating($dragOffset) { v, s, _ in s = v.translation }
                .onEnded { v in pan.width += v.translation.width; pan.height += v.translation.height })
            .simultaneousGesture(MagnifyGesture()
                .updating($pinch) { v, s, _ in s = Self.clamp(zoom * v.magnification) / zoom }
                .onEnded { v in zoom = Self.clamp(zoom * v.magnification) })
            .animation(.spring(duration: 0.6), value: neighborhood.center)
            .animation(.spring(duration: 0.4), value: neighborhood.nodes.count)
        }
        .clipped()
        .overlay(alignment: .bottomTrailing) { controls }
    }

    private func tap(_ node: CollaborationGraph.Node) {
        if node.level == 0 {
            withAnimation(.snappy) { selected = nil }
        } else if selected == node.id {
            onOpen(node.person)
        } else {
            withAnimation(.snappy) { selected = node.id }
        }
    }

    static func clamp(_ z: CGFloat) -> CGFloat { min(maxZoom, max(minZoom, z)) }

    /// Away from the center, flipped horizontally when the name would run off the side of the graph.
    static func labelDirection(layout p: CGPoint, at: CGPoint, bubble: CGFloat, width: CGFloat) -> CGVector {
        let length = hypot(p.x, p.y)
        var v = length > 0 ? CGVector(dx: p.x / length, dy: p.y / length) : CGVector(dx: 0, dy: 1)
        let reach = bubble / 2 + 6 + DNANodeView.labelWidth
        if abs(v.dx) > 0.35, (v.dx > 0 && at.x + reach > width - 4) || (v.dx < 0 && at.x - reach < 4) { v.dx = -v.dx }
        return v
    }

    private var controls: some View {
        HStack(spacing: 0) {
            Button { withAnimation { zoom = Self.clamp(zoom / 1.25) } } label: {
                Image(systemName: "minus.magnifyingglass").frame(width: 40, height: 36)
            }
            .accessibilityLabel("Zoom Out")
            Button { withAnimation { zoom = 1; pan = .zero } } label: {
                Image(systemName: "scope").frame(width: 40, height: 36)
            }
            .accessibilityLabel("Fit")
            Button { withAnimation { zoom = Self.clamp(zoom * 1.25) } } label: {
                Image(systemName: "plus.magnifyingglass").frame(width: 40, height: 36)
            }
            .accessibilityLabel("Zoom In")
        }
        .buttonStyle(.borderless)
        .background(Capsule().fill(.regularMaterial))
        .padding(10)
    }

    private func accessibilityValue(_ node: CollaborationGraph.Node) -> String {
        var s = node.person.roles.prefix(3).joined(separator: ", ")
        if node.level > 0 { s += ". \(songCount(node.shared)) with the person they connect to" }
        return s
    }
}

private struct DNANodeView: View {
    let node: CollaborationGraph.Node
    let size: CGFloat
    let isSelected: Bool
    let showsLabel: Bool
    /// Unit vector pointing away from the center; the name sits on that side so neighbors on a ring
    /// don't collide.
    let outward: CGVector

    static let labelWidth: CGFloat = 100

    var body: some View {
        let shown = isSelected ? size * 1.15 : size
        // Outer rings are denser: one shorter line until selected.
        let labelWidth = node.level >= 2 && !isSelected ? 84 : Self.labelWidth
        DNABubble(person: node.person, size: shown, highlighted: isSelected || node.level == 0)
            .overlay {
                if showsLabel {
                    let horizontal = abs(outward.dx) > 0.35
                    Text(node.person.name)
                        .font(node.level == 0 ? .subheadline.weight(.semibold) : (node.level == 1 || isSelected ? .caption2.weight(.medium) : .caption2))
                        .multilineTextAlignment(horizontal ? (outward.dx > 0 ? .leading : .trailing) : .center)
                        .lineLimit(node.level >= 2 && !isSelected ? 1 : 2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color(.systemBackground).opacity(isSelected ? 0.95 : 0.7)))
                        .frame(width: labelWidth, alignment: horizontal ? (outward.dx > 0 ? .leading : .trailing) : .center)
                        .offset(x: outward.dx * (shown / 2 + 5 + (horizontal ? labelWidth / 2 : 0)),
                                y: outward.dy * (shown / 2 + 5) + (horizontal ? 0 : outward.dy * 8))
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeOut(duration: 0.15), value: isSelected)
    }
}

// MARK: Details

/// The center (or the selected bubble): who they are, play, their artist page, top collaborators and songs.
private struct DNADetail: View {
    @Environment(PhoneModel.self) private var model
    @Environment(PhonePlayer.self) private var player
    @Environment(\.openRoute) private var openRoute
    let graph: CollaborationGraph
    let center: CollaborationGraph.Person
    let selected: CollaborationGraph.Node?
    let hood: CollaborationGraph.Neighborhood
    @Binding var selection: Int?

    var body: some View {
        let person = selected?.person ?? center
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                DNABubble(person: person, size: 64, highlighted: true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(person.name).font(.title3.bold()).lineLimit(2)
                    HStack(spacing: 4) {
                        Circle().fill(DNAPalette.of(person.category)).frame(width: 7, height: 7)
                        Text(person.category.rawValue).font(.caption).foregroundStyle(.secondary)
                    }
                    Text("\(songCount(person.trackCount)) · \(dnaCollaborators(person.degree))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if selected != nil {
                    Button { withAnimation(.snappy) { selection = nil } } label: {
                        Image(systemName: "xmark.circle.fill").font(.title2).symbolRenderingMode(.hierarchical)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Back to \(center.name)")
                }
            }
            .accessibilityElement(children: .contain)
            if !person.roles.isEmpty {
                FlowLayout(spacing: 5) {
                    ForEach(person.roles.prefix(8), id: \.self) { r in
                        Text(r).font(.caption).padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Capsule().fill(Color(.tertiarySystemFill)))
                    }
                }
            }
            actions(person)

            if let selected {
                let shared = graph.sharedTracks(center.id, selected.id)
                if shared.isEmpty {
                    Text("Connected to \(center.name) through other collaborators.").font(.callout).foregroundStyle(.secondary)
                } else {
                    DNATrackList(title: "With \(center.name)", ids: shared, source: "\(person.name) with \(center.name)")
                    DNAPhysicalList(title: "With \(center.name), in your physical collection", ids: shared, graph: graph)
                }
                if selected.level >= 2, let parent = selected.parent.flatMap({ id in hood.nodes.first { $0.id == id }?.person }) {
                    Text("Reached through \(parent.name): \(songCount(selected.shared)) together.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Tap the bubble again to put \(person.name) at the center.").font(.caption).foregroundStyle(.secondary)
            } else {
                topCollaborators
                DNATrackList(title: "In your digital collection", ids: graph.tracks(of: center.id), source: center.name)
                DNAPhysicalList(title: "In your physical collection", ids: graph.tracks(of: center.id), graph: graph)
            }
        }
    }

    @ViewBuilder
    private func actions(_ person: CollaborationGraph.Person) -> some View {
        let artist = model.library?.artist(named: person.name)
        HStack(spacing: 10) {
            if let selected {
                Button { openRoute(DNARoute(name: selected.person.name)) } label: {
                    Label("Center on \(selected.person.name)", systemImage: "scope").lineLimit(1)
                }
                .buttonStyle(.borderedProminent)
            } else {
                let tracks = model.playable(graph.tracks(of: person.id).compactMap { model.library?.track(id: $0) })
                Button { player.play(queue: tracks, source: person.name) } label: {
                    Label("Play All", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(tracks.isEmpty)
            }
            if let artist {
                NavigationLink(value: artist) { Label("Artist Page", systemImage: "music.mic") }
                    .buttonStyle(.bordered)
                    .accessibilityHint("Opens \(artist.name)'s artist page")
            }
        }
        .controlSize(.regular)
    }

    private var topCollaborators: some View {
        let top = graph.collaborators(of: center.id, limit: 10)
        return VStack(alignment: .leading, spacing: 8) {
            Text("Top collaborators").font(.headline)
            VStack(spacing: 0) {
                ForEach(Array(top.enumerated()), id: \.element.person.id) { i, c in
                    NavigationLink(value: DNARoute(name: c.person.name)) {
                        HStack(spacing: 10) {
                            Circle().fill(DNAPalette.of(c.person.category)).frame(width: 8, height: 8)
                            Text(c.person.name).foregroundStyle(Color.accentColor).lineLimit(1)
                            Spacer(minLength: 8)
                            Text("\(c.shared)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                                .accessibilityLabel("\(c.shared) shared song\(c.shared == 1 ? "" : "s")")
                            Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 11)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if i < top.count - 1 { Divider().padding(.leading, 30) }
                }
            }
            .card()
        }
    }
}

/// Songs sorted by plays, the first 25 shown. Tapping one plays the ones on the phone from it; a song that isn't
/// here offers to download it.
private struct DNATrackList: View {
    @Environment(PhoneModel.self) private var model
    @Environment(PhonePlayer.self) private var player
    let title: String
    let ids: [Int64]
    let source: String
    @State private var missing: Track?

    static let shownLimit = 25

    var body: some View {
        let tracks = ids.compactMap { model.library?.track(id: $0) }
            .sorted { (model.playTotals[$0.id]?.plays ?? 0) > (model.playTotals[$1.id]?.plays ?? 0) }
        let shown = Array(tracks.prefix(Self.shownLimit))
        if !tracks.isEmpty { list(tracks, shown) }
    }

    private func list(_ tracks: [Track], _ shown: [Track]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            VStack(spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { i, track in
                    let present = model.isPresent(track)
                    Button {
                        if present {
                            let playable = model.playable(tracks)
                            player.play(queue: playable, startAt: playable.firstIndex(of: track) ?? 0, source: source)
                        } else {
                            missing = track
                        }
                    } label: {
                        TrackRow(track: track, library: model.library,
                                 isCurrent: player.currentTrack?.id == track.id, isLiked: model.isLiked(track),
                                 isPresent: present, isPending: model.pendingDownloads.contains(track.id))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { SongMenu(track: track) }
                    if i < shown.count - 1 { Divider().padding(.leading, 68) }
                }
            }
            .card()
            if tracks.count > Self.shownLimit {
                Text("and \(tracks.count - Self.shownLimit) more").font(.caption).foregroundStyle(.secondary)
            }
        }
        .confirmationDialog("“\(missing?.title ?? "")” isn't on this iPhone", isPresented: Binding(get: { missing != nil }, set: { if !$0 { missing = nil } }),
                            titleVisibility: .visible, presenting: missing) { track in
            if model.sync.isPaired {
                Button("Download Song") { model.download(.track(track.id)) }
                if let album = model.library?.album(of: track) {
                    Button("Download Album") { model.download(.album(album: album.album, artist: album.artist)) }
                }
            }
        } message: { _ in
            Text(model.sync.isPaired ? "Download it from your Mac to play it here." : "Pair with your Mac (Sync, on Listen Now) to download music.")
        }
    }
}

/// Songs on CDs and records with no digital copy (`CollaborationGraph.PhysicalSong`, the negative ids), by the copy
/// they're on; tapping one opens that copy.
private struct DNAPhysicalList: View {
    @Environment(PhoneModel.self) private var model
    let title: String
    let ids: [Int64]
    let graph: CollaborationGraph

    var body: some View {
        let songs = ids.compactMap { graph.physicalSong($0) }
            .compactMap { song in model.item(id: song.itemID).map { (song: song, item: $0) } }
        let shown = Array(songs.prefix(DNATrackList.shownLimit))
        if !songs.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                VStack(spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.song.id) { i, entry in
                        NavigationLink(value: CollectionItemRoute(id: entry.item.id)) {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.song.title).lineLimit(1)
                                    Text(entry.item.album).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                if let sticker = entry.item.sticker { StickerPill(sticker: sticker, size: 10) }
                                else { Text(entry.item.medium.name).font(.caption2.weight(.semibold)).foregroundStyle(.secondary) }
                                Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 9)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens your \(entry.item.sticker?.text ?? entry.item.medium.name)")
                        if i < shown.count - 1 { Divider().padding(.leading, 12) }
                    }
                }
                .card()
                if songs.count > DNATrackList.shownLimit {
                    Text("and \(songs.count - DNATrackList.shownLimit) more").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
