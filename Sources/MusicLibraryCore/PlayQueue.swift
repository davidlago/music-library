import Foundation

/// The player's queue, Spotify style: the list playback started from (an album, a playlist, the songs on
/// screen) plus songs queued with Play Next, which play before the rest of the list whatever happens to it.
/// Add to Queue appends to the end of the list. Starting something new replaces everything.
///
/// `entries` holds everything in play order with `index` at the current song. Songs queued with Play Next
/// that haven't played yet always sit right after it, so they can be shown as their own section.
public struct PlayQueue: Sendable {
    public struct Entry: Identifiable, Hashable, Sendable {
        public let id: Int
        public let track: Track
        /// Added with Play Next and not played yet.
        public fileprivate(set) var isQueued: Bool
    }

    public private(set) var entries: [Entry] = []
    public private(set) var index: Int?
    /// What the list is ("Kind of Blue", a playlist name), for "Next from …"; nil once songs are appended.
    public private(set) var source: String?
    private var nextID = 0

    public init() {}

    public var currentEntry: Entry? { index.map { entries[$0] } }
    public var current: Track? { currentEntry?.track }
    /// Songs queued with Play Next, in the order they will play.
    public var queued: ArraySlice<Entry> { entries[queuedRange] }
    /// The rest of the list, after the queued songs.
    public var upcoming: ArraySlice<Entry> { entries[queuedRange.upperBound...] }
    public var hasNext: Bool { index.map { $0 + 1 < entries.count } ?? false }

    private var queuedRange: Range<Int> {
        guard let index else { return 0..<0 }
        var end = index + 1
        while end < entries.count, entries[end].isQueued { end += 1 }
        return (index + 1)..<end
    }

    // MARK: Starting and queueing

    /// Plays `tracks` from `startAt`, dropping the old list and everything queued.
    public mutating func replace(with tracks: [Track], startAt: Int, source: String? = nil) {
        guard tracks.indices.contains(startAt) else { clear(); return }
        entries = tracks.map { makeEntry($0, queued: false) }
        index = startAt
        self.source = source
    }

    public mutating func clear() {
        entries = []
        index = nil
        source = nil
    }

    /// Queues `tracks` to play right after the current song, ahead of anything queued with Play Next.
    /// With nothing playing, they become the list.
    public mutating func playNext(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        guard index != nil else { replace(with: tracks, startAt: 0); return }
        entries.insert(contentsOf: tracks.map { makeEntry($0, queued: true) }, at: queuedRange.lowerBound)
    }

    /// Appends `tracks` to the end of the queue. With nothing playing, they become the list.
    public mutating func addToQueue(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        guard index != nil else { replace(with: tracks, startAt: 0); return }
        entries.append(contentsOf: tracks.map { makeEntry($0, queued: false) })
        // The list now holds more than what it was started from.
        source = nil
    }

    private mutating func makeEntry(_ track: Track, queued: Bool) -> Entry {
        nextID += 1
        return Entry(id: nextID, track: track, isQueued: queued)
    }

    // MARK: Moving through it

    /// Moves to the next song; false at the end.
    @discardableResult
    public mutating func advance() -> Bool {
        guard let index, index + 1 < entries.count else { return false }
        setCurrent(index + 1)
        return true
    }

    /// Moves to the previous song in the list; queued songs still come next.
    @discardableResult
    public mutating func goBack() -> Bool {
        guard let index, index > 0 else { return false }
        return jump(to: entries[index - 1].id)
    }

    /// Makes the entry with `id` current. Jumping to a queued song drops the queued songs before it; jumping
    /// anywhere in the list keeps all queued songs next. False if `id` is unknown or already current.
    @discardableResult
    public mutating func jump(to id: Entry.ID) -> Bool {
        guard let index, let target = entries.firstIndex(where: { $0.id == id }), target != index else { return false }
        let queued = queuedRange
        if queued.contains(target) {
            entries.removeSubrange(queued.lowerBound..<target)
            setCurrent(queued.lowerBound)
        } else {
            let block = Array(entries[queued])
            entries.removeSubrange(queued)
            let newTarget = target > index ? target - block.count : target
            entries.insert(contentsOf: block, at: newTarget + 1)
            setCurrent(newTarget)
        }
        return true
    }

    private mutating func setCurrent(_ i: Int) {
        index = i
        entries[i].isQueued = false
    }

    // MARK: Saving between launches

    /// The queue as track IDs, saved when the app quits so it can be restored at the next launch.
    public struct Snapshot: Codable, Equatable, Sendable {
        public var trackIds: [Int64]
        public var index: Int
        /// How many entries after the current one were queued with Play Next.
        public var queuedCount: Int
        public var source: String?
        /// Where in the current song playback was.
        public var position: Double

        public init(trackIds: [Int64], index: Int, queuedCount: Int, source: String?, position: Double) {
            self.trackIds = trackIds; self.index = index; self.queuedCount = queuedCount
            self.source = source; self.position = position
        }
    }

    /// Nil when nothing is loaded.
    public func snapshot(position: Double) -> Snapshot? {
        guard let index else { return nil }
        return Snapshot(trackIds: entries.map(\.track.id), index: index, queuedCount: queuedRange.count, source: source,
                        position: position.isFinite ? max(0, position) : 0)
    }

    /// Restores a saved queue, looking its tracks up by ID and dropping the ones no longer in the library. When
    /// the current song is gone, the next one (or else the previous one) becomes current, from its start.
    /// Returns where to resume in the current song, or nil if nothing could be restored.
    @discardableResult
    public mutating func restore(_ snapshot: Snapshot, track: (Int64) -> Track?) -> Double? {
        clear()
        // The file could hold anything: keep the arithmetic in range.
        let count = snapshot.trackIds.count
        let index = min(max(snapshot.index, 0), count)
        let queuedEnd = index + 1 + min(max(snapshot.queuedCount, 0), count)
        var restored: [Entry] = []
        var current: Int?
        var currentKept = false
        for (i, id) in snapshot.trackIds.enumerated() {
            guard let t = track(id) else { continue }
            if i >= index && current == nil {
                current = restored.count
                currentKept = i == index
            }
            // Play Next songs stay queued right after the current song (setCurrent clears the current one's flag).
            restored.append(makeEntry(t, queued: i > index && i < queuedEnd))
        }
        if current == nil, !restored.isEmpty { current = restored.count - 1 }
        guard let current else { return nil }
        entries = restored
        setCurrent(current)
        source = snapshot.source
        return currentKept && snapshot.position.isFinite ? max(0, snapshot.position) : 0
    }

    // MARK: Editing

    /// Removes upcoming entries; the current song and the ones already played stay.
    public mutating func remove(_ ids: Set<Entry.ID>) {
        guard let index else { return }
        entries = entries.enumerated().filter { $0.offset <= index || !ids.contains($0.element.id) }.map(\.element)
    }

    /// Removes everything queued, keeping the list.
    public mutating func clearQueued() { entries.removeSubrange(queuedRange) }

    /// Reorders queued songs; offsets are positions in `queued`.
    public mutating func moveQueued(from offsets: IndexSet, to destination: Int) {
        move(in: queuedRange, from: offsets, to: destination)
    }

    /// Reorders the rest of the list; offsets are positions in `upcoming`.
    public mutating func moveUpcoming(from offsets: IndexSet, to destination: Int) {
        move(in: queuedRange.upperBound..<entries.count, from: offsets, to: destination)
    }

    /// Same semantics as SwiftUI's `move(fromOffsets:toOffset:)`, within one section.
    private mutating func move(in range: Range<Int>, from offsets: IndexSet, to destination: Int) {
        var section = Array(entries[range])
        let valid = offsets.filter(section.indices.contains)
        guard !valid.isEmpty else { return }
        let moving = valid.map { section[$0] }
        for o in valid.reversed() { section.remove(at: o) }
        let insertAt = min(max(destination - valid.filter { $0 < destination }.count, 0), section.count)
        section.insert(contentsOf: moving, at: insertAt)
        entries.replaceSubrange(range, with: section)
    }
}
