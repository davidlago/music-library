import CoreGraphics
import Foundation

/// Who worked with whom, from the library's credits: everyone credited on a track (players, singers,
/// producers, engineers, writers…) plus the track's artists, linked when they appear on the same track.
public struct CollaborationGraph: Sendable {
    public enum Category: String, CaseIterable, Sendable {
        case performance = "Performance", writing = "Writing", production = "Production"
    }

    public struct Person: Identifiable, Hashable, Sendable {
        public var id: Int
        public var name: String
        /// Role labels, most frequent first ("piano", "composer", "artist"…).
        public var roles: [String]
        public var category: Category
        public var trackCount: Int
        /// Number of distinct collaborators.
        public var degree: Int
    }

    public private(set) var people: [Person] = []
    /// Sorted track IDs per person.
    private var tracksOf: [[Int64]] = []
    /// Collaborator → number of shared tracks, per person.
    private var neighbors: [[Int: Int]] = []
    private var byName: [String: Int] = [:]

    public static let empty = CollaborationGraph(tracks: [])

    /// Credits that aren't about the music (MusicBrainz release relationships). Release credits apply to
    /// every track, so a box set's photographers would otherwise "collaborate" with every musician on it.
    static let nonMusicalRoles: Set<String> = [
        "photography", "design", "design/illustration", "graphic design", "illustration", "art direction", "artwork",
        "liner notes", "booking", "legal representation", "artists and repertoire", "creative direction", "copyright",
        "phonographic copyright", "publishing", "travel", "merchandise", "management", "marketing", "promotion",
    ]

    /// MusicBrainz special-purpose artists and placeholders that aren't people.
    static let excluded: Set<String> = ["various artists", "unknown", "anonymous", "no artist", "traditional", "data", "dialogue"]

    public init(tracks: [Track]) {
        var names: [[String: Int]] = []          // spelling counts per person
        var roleCounts: [[String: Int]] = []
        var trackSets: [Set<Int64>] = []
        var byMBID: [String: Int] = [:]
        var mbidOf: [String?] = []

        func node(_ rawName: String, mbid: String?) -> Int? {
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = Self.key(name)
            guard !key.isEmpty, !Self.excluded.contains(key) else { return nil }
            if let mbid, !mbid.isEmpty, let id = byMBID[mbid] { return id }
            if let id = byName[key], mbid == nil || mbidOf[id] == nil || mbidOf[id] == mbid {
                if let mbid, !mbid.isEmpty, mbidOf[id] == nil { mbidOf[id] = mbid; byMBID[mbid] = id }
                return id
            }
            let id = names.count
            names.append([:]); roleCounts.append([:]); trackSets.append([]); mbidOf.append(mbid)
            if byName[key] == nil { byName[key] = id }
            if let mbid, !mbid.isEmpty { byMBID[mbid] = id }
            return id
        }

        var adjacency: [[Int: Int]] = []
        for t in tracks {
            var onTrack: [Int: Set<String>] = [:]
            func add(_ name: String, mbid: String? = nil, role: String) {
                guard let id = node(name, mbid: mbid) else { return }
                names[id][name.trimmingCharacters(in: .whitespaces), default: 0] += 1
                onTrack[id, default: []].insert(role)
            }
            let m = t.metadata, x = m.extended
            for a in Self.splitArtists(m.artist) { add(a, mbid: x.mbArtistIds.count == 1 ? x.mbArtistIds[0] : nil, role: "artist") }
            for c in x.credits where !Self.nonMusicalRoles.contains(c.role.lowercased()) {
                for role in CreditFormatter.label(c) { add(c.name, mbid: c.artistId, role: role) }
            }
            let fields: [(String, String)] = [
                (m.composer, "composer"), (x.lyricist, "lyricist"), (x.writer, "writer"), (x.arranger, "arranger"),
                (x.conductor, "conductor"), (x.producer, "producer"), (x.engineer, "engineer"), (x.mixer, "mixer"),
                (x.remixer, "remixer"),
            ]
            for (value, role) in fields { for name in Self.splitNames(value) { add(name, role: role) } }
            for p in x.performers { add(Self.stripParenthetical(p), role: "performer") }

            while adjacency.count < names.count { adjacency.append([:]) }
            let ids = Array(onTrack.keys)
            for id in ids {
                trackSets[id].insert(t.id)
                for role in onTrack[id]! { roleCounts[id][role, default: 0] += 1 }
            }
            for i in ids.indices {
                for j in ids.indices where j > i {
                    adjacency[ids[i]][ids[j], default: 0] += 1
                    adjacency[ids[j]][ids[i], default: 0] += 1
                }
            }
        }
        while adjacency.count < names.count { adjacency.append([:]) }

        neighbors = adjacency
        tracksOf = trackSets.map { $0.sorted() }
        people = names.indices.map { id in
            let display = names[id].max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key ?? ""
            let roles = roleCounts[id].sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
            return Person(id: id, name: display, roles: roles, category: Self.category(roleCounts[id]),
                          trackCount: trackSets[id].count, degree: adjacency[id].count)
        }
    }

    // MARK: Names and roles

    public static func key(_ name: String) -> String {
        TextNormalizer.normalize(name.replacingOccurrences(of: "&", with: " and "))
    }

    /// "A; B / C" → ["A", "B", "C"]. Commas are left alone ("Earth, Wind & Fire").
    public static func splitNames(_ s: String) -> [String] {
        s.components(separatedBy: ";").flatMap { $0.components(separatedBy: " / ") }
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// "Rachael & Vilray feat. Jon Batiste" → ["Rachael & Vilray", "Jon Batiste"]. "&" and "and" stay,
    /// since they're usually part of a name.
    public static func splitArtists(_ s: String) -> [String] {
        var parts = [s]
        for sep in [" feat. ", " ft. ", " featuring ", " Feat. ", " Featuring ", " with ", ";"] {
            parts = parts.flatMap { $0.components(separatedBy: sep) }
        }
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    public static func stripParenthetical(_ s: String) -> String {
        guard let r = s.range(of: " (") else { return s }
        return String(s[..<r.lowerBound])
    }

    static let writingRoles: Set<String> = ["composer", "lyricist", "writer", "arranger", "orchestrator", "librettist", "translator"]
    static let productionWords = ["producer", "engineer", "mixer", "mastering", "remixer", "programming", "editor", "sound", "audio"]

    public static func category(ofRole role: String) -> Category {
        let r = role.lowercased()
        if writingRoles.contains(r) || r.hasSuffix(" composer") || r.hasSuffix(" arranger") { return .writing }
        if productionWords.contains(where: { r.contains($0) }) { return .production }
        return .performance
    }

    static func category(_ roles: [String: Int]) -> Category {
        var totals: [Category: Int] = [:]
        for (role, n) in roles { totals[category(ofRole: role), default: 0] += n }
        return Category.allCases.max { (totals[$0] ?? 0) < (totals[$1] ?? 0) } ?? .performance
    }

    // MARK: Queries

    public func person(named name: String) -> Person? {
        byName[Self.key(name)].map { people[$0] }
    }

    public func tracks(of id: Int) -> [Int64] { tracksOf.indices.contains(id) ? tracksOf[id] : [] }

    /// Collaborators by number of shared tracks.
    public func collaborators(of id: Int, limit: Int = .max) -> [(person: Person, shared: Int)] {
        guard neighbors.indices.contains(id) else { return [] }
        return neighbors[id].sorted { $0.value != $1.value ? $0.value > $1.value : people[$0.key].name < people[$1.key].name }
            .prefix(limit).map { (people[$0.key], $0.value) }
    }

    public func sharedTrackCount(_ a: Int, _ b: Int) -> Int { neighbors.indices.contains(a) ? neighbors[a][b] ?? 0 : 0 }

    public func sharedTracks(_ a: Int, _ b: Int) -> [Int64] {
        let x = tracks(of: a), y = tracks(of: b)
        var i = 0, j = 0
        var out: [Int64] = []
        while i < x.count && j < y.count {
            if x[i] == y[j] { out.append(x[i]); i += 1; j += 1 } else if x[i] < y[j] { i += 1 } else { j += 1 }
        }
        return out
    }

    /// People whose name contains `text` (word starts first, then by number of tracks).
    public func search(_ text: String, limit: Int = 12) -> [Person] {
        let q = Self.key(text)
        guard !q.isEmpty else { return [] }
        return people.filter { Self.key($0.name).contains(q) }
            .sorted { a, b in
                let pa = (" " + Self.key(a.name)).contains(" " + q), pb = (" " + Self.key(b.name)).contains(" " + q)
                return pa != pb ? pa : (a.trackCount != b.trackCount ? a.trackCount > b.trackCount : a.name < b.name)
            }
            .prefix(limit).map { $0 }
    }

    /// The best-connected people, as starting points.
    public func mostConnected(limit: Int = 24) -> [Person] {
        people.sorted { $0.degree != $1.degree ? $0.degree > $1.degree : $0.trackCount > $1.trackCount }.prefix(limit).map { $0 }
    }

    // MARK: Neighborhood

    public struct Node: Identifiable, Hashable, Sendable {
        public var id: Int { person.id }
        public var person: Person
        public var level: Int
        /// The node this one was reached from (nil for the center).
        public var parent: Int?
        /// Tracks shared with the parent.
        public var shared: Int
    }

    public struct Edge: Identifiable, Hashable, Sendable {
        public var id: String { "\(a)-\(b)" }
        public var a: Int
        public var b: Int
        public var weight: Int
        /// Part of the tree from the center (the rest connect people already shown).
        public var isTree: Bool
    }

    public struct Neighborhood: Sendable {
        public var center: Int
        public var nodes: [Node]
        public var edges: [Edge]
        /// Collaborators left out to keep the graph readable.
        public var hidden: Int
    }

    /// How many collaborators each node at a level may add, by number of levels shown.
    static func fanout(depth: Int) -> [Int] {
        switch depth {
        case ...1: [30]
        case 2: [14, 5]
        default: [10, 4, 3]
        }
    }

    /// The center, its strongest collaborators and (for depth > 1) theirs, breadth first. Each person
    /// appears once, at the level where they're first reached.
    public func neighborhood(of center: Int, depth: Int, maxNodes: Int = 120) -> Neighborhood {
        guard people.indices.contains(center) else { return Neighborhood(center: center, nodes: [], edges: [], hidden: 0) }
        let fan = Self.fanout(depth: depth)
        var nodes = [Node(person: people[center], level: 0, parent: nil, shared: 0)]
        var seen: Set<Int> = [center]
        var frontier = [center]
        var hidden = 0
        for level in 1...max(1, min(depth, fan.count)) {
            var next: [Int] = []
            for parent in frontier {
                let candidates = collaborators(of: parent).filter { !seen.contains($0.person.id) }
                let take = candidates.prefix(fan[level - 1])
                if level == 1 { hidden = candidates.count - take.count }
                for (p, shared) in take where nodes.count < maxNodes {
                    seen.insert(p.id)
                    nodes.append(Node(person: p, level: level, parent: parent, shared: shared))
                    next.append(p.id)
                }
            }
            frontier = next
        }
        var edges: [Edge] = []
        let shown = Array(seen)
        let parentOf = Dictionary(uniqueKeysWithValues: nodes.compactMap { n in n.parent.map { (n.id, $0) } })
        for i in shown.indices {
            for j in shown.indices where j > i {
                let a = shown[i], b = shown[j]
                guard let w = neighbors[a][b] else { continue }
                let tree = parentOf[a] == b || parentOf[b] == a
                edges.append(Edge(a: min(a, b), b: max(a, b), weight: w, isTree: tree))
            }
        }
        edges.sort { $0.id < $1.id }
        return Neighborhood(center: center, nodes: nodes, edges: edges, hidden: hidden)
    }

    /// Radial layout: the center at the origin, each level on its own ring, and every subtree in an arc
    /// sized by how many people it holds, so branches don't cross. Coordinates are in ring units.
    public static func layout(_ n: Neighborhood) -> [Int: CGPoint] {
        var children: [Int: [Node]] = [:]
        for node in n.nodes { if let p = node.parent { children[p, default: []].append(node) } }
        // Subtrees get room for their children, but leaves keep a fair share so inner rings don't bunch up.
        func size(_ id: Int) -> Double { 1 + (children[id] ?? []).reduce(0) { $0 + size($1.id) } * 0.35 }
        var out: [Int: CGPoint] = [n.center: .zero]
        func place(_ id: Int, from start: Double, to end: Double, level: Int) {
            let kids = (children[id] ?? []).sorted { $0.shared != $1.shared ? $0.shared > $1.shared : $0.person.name < $1.person.name }
            let total = kids.reduce(0) { $0 + size($1.id) }
            var a = start
            for k in kids {
                let span = (end - start) * size(k.id) / max(total, 1)
                let mid = a + span / 2
                let r = Double(level)
                out[k.id] = CGPoint(x: cos(mid) * r, y: sin(mid) * r)
                place(k.id, from: a, to: a + span, level: level + 1)
                a += span
            }
        }
        place(n.center, from: -Double.pi / 2, to: 3 * Double.pi / 2, level: 1)
        return out
    }
}
