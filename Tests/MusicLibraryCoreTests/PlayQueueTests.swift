import Foundation
import Testing
@testable import MusicLibraryCore

@Suite struct PlayQueueTests {
    func tracks(_ titles: String...) -> [Track] {
        titles.enumerated().map { i, t in
            Track(id: Int64(i + 1), path: "\(t).flac", metadata: TrackMetadata(title: t), duration: 60, format: "flac", sha256: t)
        }
    }

    func titles(_ entries: ArraySlice<PlayQueue.Entry>) -> [String] { entries.map(\.track.title) }
    func order(_ q: PlayQueue) -> [String] { q.entries.map(\.track.title) }

    /// Playing A of [A, B, C] with X and Y queued with Play Next.
    func queueWithXY() -> PlayQueue {
        var q = PlayQueue()
        q.replace(with: tracks("A", "B", "C"), startAt: 0, source: "Album")
        q.playNext(tracks("X", "Y"))
        return q
    }

    @Test func replaceStartsTheList() {
        var q = PlayQueue()
        q.replace(with: tracks("A", "B", "C"), startAt: 1, source: "Album")
        #expect(q.current?.title == "B")
        #expect(q.queued.isEmpty)
        #expect(titles(q.upcoming) == ["C"])
        #expect(q.source == "Album")
        q.replace(with: tracks("A"), startAt: 3)
        #expect(q.current == nil && q.entries.isEmpty && q.source == nil)
    }

    @Test func queuedSongsPlayBeforeTheRestOfTheList() {
        var q = queueWithXY()
        q.playNext(tracks("N"))
        #expect(titles(q.queued) == ["N", "X", "Y"])
        #expect(titles(q.upcoming) == ["B", "C"])
        var played: [String] = []
        while q.advance() { played.append(q.current!.title) }
        #expect(played == ["N", "X", "Y", "B", "C"])
        #expect(!q.hasNext)
    }

    @Test func playNextGoesAheadOfEarlierQueuedSongs() {
        var q = queueWithXY()
        q.advance()
        #expect(q.current?.title == "X")
        #expect(titles(q.queued) == ["Y"])
        q.playNext(tracks("Z"))
        #expect(titles(q.queued) == ["Z", "Y"])
        #expect(titles(q.upcoming) == ["B", "C"])
    }

    @Test func addToQueueAppendsToTheEnd() {
        var q = queueWithXY()
        q.addToQueue(tracks("D", "E"))
        #expect(titles(q.queued) == ["X", "Y"])
        #expect(titles(q.upcoming) == ["B", "C", "D", "E"])
        #expect(q.source == nil)
        q.addToQueue(tracks("F"))
        var played: [String] = []
        while q.advance() { played.append(q.current!.title) }
        #expect(played == ["X", "Y", "B", "C", "D", "E", "F"])
    }

    @Test func addToQueueAtTheEndOfTheListPlaysNext() {
        var q = PlayQueue()
        q.replace(with: tracks("A", "B"), startAt: 1)
        #expect(!q.hasNext)
        q.addToQueue(tracks("C"))
        #expect(q.hasNext)
        #expect(titles(q.upcoming) == ["C"])
    }

    @Test func queueingWithNothingPlayingStartsTheTracks() {
        var q = PlayQueue()
        q.addToQueue(tracks("A", "B"))
        #expect(q.current?.title == "A")
        #expect(q.queued.isEmpty)
        #expect(titles(q.upcoming) == ["B"])
        q.addToQueue([])
        #expect(q.entries.count == 2)
    }

    @Test func replaceDropsTheQueue() {
        var q = queueWithXY()
        q.replace(with: tracks("D", "E"), startAt: 0)
        #expect(q.queued.isEmpty)
        #expect(order(q) == ["D", "E"])
    }

    @Test func goingBackKeepsQueuedSongsNext() {
        var q = queueWithXY()
        q.advance(); q.advance(); q.advance()
        #expect(q.current?.title == "B")
        q.playNext(tracks("Z"))
        let wentBack = q.goBack()
        #expect(wentBack)
        #expect(q.current?.title == "Y")
        #expect(titles(q.queued) == ["Z"])
        #expect(titles(q.upcoming) == ["B", "C"])
        q.goBack(); q.goBack()
        #expect(q.current?.title == "A")
        let wentBackAtStart = q.goBack()
        #expect(!wentBackAtStart)
        #expect(order(q) == ["A", "Z", "X", "Y", "B", "C"])
    }

    @Test func jumpingIntoTheQueueDropsSkippedQueuedSongs() {
        var q = queueWithXY()
        let y = q.queued.last!.id
        let jumped = q.jump(to: y)
        #expect(jumped)
        #expect(q.current?.title == "Y")
        #expect(order(q) == ["A", "Y", "B", "C"])
        #expect(q.queued.isEmpty)
        let jumpedToCurrent = q.jump(to: y), jumpedToUnknown = q.jump(to: 999)
        #expect(!jumpedToCurrent && !jumpedToUnknown)
    }

    @Test func jumpingAheadInTheListKeepsTheQueue() {
        var q = queueWithXY()
        let c = q.upcoming.last!.id
        let jumped = q.jump(to: c)
        #expect(jumped)
        #expect(q.current?.title == "C")
        #expect(titles(q.queued) == ["X", "Y"])
        #expect(q.upcoming.isEmpty)
        #expect(order(q) == ["A", "B", "C", "X", "Y"])
    }

    @Test func removeOnlyTouchesUpcomingEntries() {
        var q = queueWithXY()
        q.advance()
        let ids = Set([q.entries[0].id, q.entries[1].id, q.queued.first!.id, q.upcoming.last!.id])
        q.remove(ids)
        #expect(order(q) == ["A", "X", "B"])
        #expect(q.current?.title == "X")
    }

    @Test func removingTracksDropsAllTheirEntries() {
        var q = PlayQueue()
        let t = tracks("A", "B", "C", "D")
        q.replace(with: Array(t[0...2]), startAt: 1, source: "Album")
        q.playNext([t[3]])
        let currentChanged = q.removeTracks([1, 3])
        #expect(!currentChanged)
        #expect(order(q) == ["B", "D"])
        #expect(q.current?.title == "B")
        #expect(titles(q.queued) == ["D"])
        // The current song goes: the next one plays.
        let removedCurrent = q.removeTracks([2])
        #expect(removedCurrent)
        #expect(q.current?.title == "D")
        #expect(q.queued.isEmpty)
        let removedLast = q.removeTracks([4])
        #expect(removedLast)
        #expect(q.current == nil && q.entries.isEmpty)
    }

    @Test func clearQueuedKeepsTheList() {
        var q = queueWithXY()
        q.clearQueued()
        #expect(order(q) == ["A", "B", "C"])
        #expect(q.current?.title == "A")
    }

    @Test func reorderWithinSections() {
        var q = PlayQueue()
        q.replace(with: tracks("A", "B", "C", "D"), startAt: 0)
        q.playNext(tracks("X", "Y", "Z"))
        q.moveQueued(from: [0], to: 3)
        #expect(titles(q.queued) == ["Y", "Z", "X"])
        q.moveQueued(from: [2], to: 0)
        #expect(titles(q.queued) == ["X", "Y", "Z"])
        q.moveUpcoming(from: [0, 2], to: 3)
        #expect(titles(q.upcoming) == ["C", "B", "D"])
        q.moveUpcoming(from: [9], to: 0)
        #expect(order(q) == ["A", "X", "Y", "Z", "C", "B", "D"])
    }
}

@Suite struct PlayQueueSnapshotTests {
    let library: [Int64: Track] = Dictionary(uniqueKeysWithValues: ["A", "B", "C", "X", "Y"].enumerated().map { i, t in
        (Int64(i + 1), Track(id: Int64(i + 1), path: "\(t).flac", metadata: TrackMetadata(title: t), duration: 60, format: "flac", sha256: t))
    })

    func tracks(_ titles: String...) -> [Track] { titles.map { t in library.values.first { $0.title == t }! } }
    func order(_ q: PlayQueue) -> [String] { q.entries.map(\.track.title) }

    /// Playing B of [A, B, C] with X and Y queued with Play Next.
    func saved() -> PlayQueue.Snapshot {
        var q = PlayQueue()
        q.replace(with: tracks("A", "B", "C"), startAt: 1, source: "Album")
        q.playNext(tracks("X", "Y"))
        return q.snapshot(position: 42)!
    }

    @Test func roundTrips() throws {
        let snapshot = saved()
        #expect(snapshot == PlayQueue.Snapshot(trackIds: [1, 2, 4, 5, 3], index: 1, queuedCount: 2, source: "Album", position: 42))
        let decoded = try JSONDecoder().decode(PlayQueue.Snapshot.self, from: JSONEncoder().encode(snapshot))
        var q = PlayQueue()
        #expect(q.restore(decoded) { library[$0] } == 42)
        #expect(order(q) == ["A", "B", "X", "Y", "C"])
        #expect(q.current?.title == "B")
        #expect(q.queued.map(\.track.title) == ["X", "Y"])
        #expect(q.source == "Album")
        #expect(PlayQueue().snapshot(position: 0) == nil)
    }

    @Test func dropsRemovedSongs() {
        var q = PlayQueue()
        // A removed: B stays current at its position.
        #expect(q.restore(saved()) { $0 == 1 ? nil : library[$0] } == 42)
        #expect(order(q) == ["B", "X", "Y", "C"] && q.current?.title == "B")
        // B removed: the queued X plays next, from the start, and Y stays queued.
        #expect(q.restore(saved()) { $0 == 2 ? nil : library[$0] } == 0)
        #expect(q.current?.title == "X" && q.queued.map(\.track.title) == ["Y"])
        // Everything from B on removed: falls back to A.
        #expect(q.restore(saved()) { $0 == 1 ? library[$0] : nil } == 0)
        #expect(order(q) == ["A"] && q.current?.title == "A")
        // Nothing left.
        #expect(q.restore(saved()) { _ in nil } == nil)
        #expect(q.current == nil && q.entries.isEmpty)
    }

    @Test func toleratesBadValues() {
        var q = PlayQueue()
        let bad = PlayQueue.Snapshot(trackIds: [1, 2], index: Int.max, queuedCount: Int.max, source: nil, position: .nan)
        #expect(q.restore(bad) { library[$0] } == 0)
        #expect(q.current?.title == "B")
        let negative = PlayQueue.Snapshot(trackIds: [1, 2], index: -5, queuedCount: -1, source: nil, position: -3)
        #expect(q.restore(negative) { library[$0] } == 0)
        #expect(q.current?.title == "A" && q.queued.isEmpty)
    }
}
