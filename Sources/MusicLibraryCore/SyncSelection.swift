import Foundation

/// Something that resolves to tracks when it's used: the Export List and the iPhone's selection are made of these.
public enum ExportItem: Codable, Hashable, Identifiable, Sendable {
    case library
    case album(album: String, artist: String)
    case artist(String)
    case track(Int64)
    case playlist(Int64)
    case smartPlaylist(Int64)
    case likedSongs

    public var id: Self { self }
}

/// What the iPhone keeps: an ordered list of rules, each adding an item's songs to the phone or keeping them off it.
/// For each song the last rule that covers it decides, so taking an album off the phone works even when its artist
/// is on the list, and putting it back later works too. The Mac's Add to iPhone and the phone's own Download and
/// Remove from iPhone requests all go through `apply`.
public struct SyncSelection: Codable, Equatable, Sendable {
    public struct Rule: Codable, Hashable, Identifiable, Sendable {
        public var item: ExportItem
        /// False: keep the item's songs off the phone.
        public var include: Bool
        public var id: Self { self }
        public init(item: ExportItem, include: Bool) { self.item = item; self.include = include }
    }

    public var rules: [Rule]

    public init(rules: [Rule] = []) { self.rules = rules }

    /// An older selection: a plain list of items, all on the phone.
    public init(items: [ExportItem]) { rules = items.map { Rule(item: $0, include: true) } }

    public var isEmpty: Bool { rules.isEmpty }
    public var included: [ExportItem] { rules.filter(\.include).map(\.item) }
    public var excluded: [ExportItem] { rules.filter { !$0.include }.map(\.item) }

    /// The item is on the list and nothing after it takes it off again, or all its songs are on the phone anyway.
    public func contains(_ item: ExportItem, tracks: (ExportItem) -> [Track]) -> Bool {
        let ids = Set(tracks(item).map(\.id))
        if ids.isEmpty { return rules.last { $0.item == item }?.include == true }
        return ids.isSubset(of: Set(resolve(tracks).map(\.id)))
    }

    /// The songs on the phone, each once, in the order the rules first add them.
    public func resolve(_ tracks: (ExportItem) -> [Track]) -> [Track] {
        var state: [Int64: Bool] = [:]
        var order: [Track] = []
        for rule in rules {
            for t in tracks(rule.item) {
                if rule.include, state[t.id] == nil { order.append(t) }
                state[t.id] = rule.include
            }
        }
        return order.filter { state[$0.id] == true }
    }

    /// Puts the item's songs on the phone (`include`) or takes them off, then drops rules that no longer decide
    /// anything. `tracks` gives each item's songs as they are now.
    public mutating func apply(_ item: ExportItem, include: Bool, tracks: (ExportItem) -> Set<Int64>) {
        rules.removeAll { $0.item == item }
        rules.append(Rule(item: item, include: include))
        compact(tracks)
    }

    /// Removes rules that make no difference: ones whose songs later rules all decide, additions of songs already
    /// added, and exclusions of songs no earlier rule adds. Additions with no songs right now (an empty playlist,
    /// say) are kept.
    mutating func compact(_ tracks: (ExportItem) -> Set<Int64>) {
        let sets = rules.map { tracks($0.item) }
        var keep = Array(repeating: true, count: rules.count)
        var decidedLater = Set<Int64>()
        for i in rules.indices.reversed() {
            let ids = sets[i]
            if !ids.isEmpty, ids.isSubset(of: decidedLater) { keep[i] = false }
            decidedLater.formUnion(ids)
        }
        var added = Set<Int64>()
        for i in rules.indices where keep[i] {
            if rules[i].include {
                if !sets[i].isEmpty, sets[i].isSubset(of: added) { keep[i] = false }
                added.formUnion(sets[i])
            } else if sets[i].isDisjoint(with: added) {
                keep[i] = false
            } else {
                added.subtract(sets[i])
            }
        }
        rules = rules.indices.filter { keep[$0] }.map { rules[$0] }
    }
}

/// A Download or Remove from iPhone made on the phone, waiting to reach the Mac (which changes its selection, then
/// syncs). Removing also deletes the files on the phone right away; downloading needs the Mac.
public struct SyncRequest: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var item: ExportItem
    /// True: download to the phone. False: remove from it.
    public var include: Bool
    public var at: Date

    public init(id: String = UUID().uuidString, item: ExportItem, include: Bool, at: Date = Date()) {
        self.id = id; self.item = item; self.include = include; self.at = at
    }
}

/// The phone's requests not yet delivered, persisted as JSON. A new request for an item replaces an older one
/// for the same item; they're removed once a sync has applied them.
public final class SyncRequestQueue: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var items: [SyncRequest]

    public init(url: URL) {
        self.url = url
        items = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([SyncRequest].self, from: $0) } ?? []
    }

    public var requests: [SyncRequest] {
        lock.lock(); defer { lock.unlock() }
        return items
    }

    public func add(_ request: SyncRequest) {
        lock.lock(); defer { lock.unlock() }
        items.removeAll { $0.item == request.item }
        items.append(request)
        save()
    }

    public func remove(_ ids: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        items.removeAll { ids.contains($0.id) }
        save()
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(items).write(to: url, options: .atomic)
        } catch {}
    }
}
