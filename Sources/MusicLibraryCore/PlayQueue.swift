import Foundation

/// The player's queue, Spotify style: the list playback started from (an album, a playlist, the songs on
/// screen) plus songs queued with Play Next or Add to Queue. Queued songs play before the rest of the list,
/// whatever happens to the list; starting something new replaces both.
///
/// `entries` holds everything in play order with `index` at the current song. Queued songs that haven't
/// played yet always sit right after it, so they can be shown as their own section.
public struct PlayQueue: Sendable {
    public struct Entry: Identifiable, Hashable, Sendable {
        public let id: Int
        public let track: Track
        /// Added with Play Next or Add to Queue and not played yet.
        public fileprivate(set) var isQueued: Bool
    }

    public private(set) var entries: [Entry] = []
    public private(set) var index: Int?
    /// What the list is ("Kind of Blue", a playlist name), for "Next from …".
    public private(set) var source: String?
    private var nextID = 0

    public init() {}

    public var currentEntry: Entry? { index.map { entries[$0] } }
    public var current: Track? { currentEntry?.track }
    /// Queued songs, in the order they will play.
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

    /// Queues `tracks` ahead of anything already queued. With nothing playing, they become the list.
    public mutating func playNext(_ tracks: [Track]) { insertQueued(tracks, at: queuedRange.lowerBound) }

    /// Queues `tracks` after anything already queued. With nothing playing, they become the list.
    public mutating func addToQueue(_ tracks: [Track]) { insertQueued(tracks, at: queuedRange.upperBound) }

    private mutating func insertQueued(_ tracks: [Track], at position: Int) {
        guard !tracks.isEmpty else { return }
        guard index != nil else { replace(with: tracks, startAt: 0); return }
        entries.insert(contentsOf: tracks.map { makeEntry($0, queued: true) }, at: position)
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
