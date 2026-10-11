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

    /// Playing A of [A, B, C] with X and Y queued.
    func queueWithXY() -> PlayQueue {
        var q = PlayQueue()
        q.replace(with: tracks("A", "B", "C"), startAt: 0, source: "Album")
        q.addToQueue(tracks("X", "Y"))
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

    @Test func addToQueueKeepsQueueOrderWhilePlayingQueuedSongs() {
        var q = queueWithXY()
        q.advance()
        #expect(q.current?.title == "X")
        #expect(titles(q.queued) == ["Y"])
        q.addToQueue(tracks("Z"))
        #expect(titles(q.queued) == ["Y", "Z"])
        #expect(titles(q.upcoming) == ["B", "C"])
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
        q.addToQueue(tracks("Z"))
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

    @Test func clearQueuedKeepsTheList() {
        var q = queueWithXY()
        q.clearQueued()
        #expect(order(q) == ["A", "B", "C"])
        #expect(q.current?.title == "A")
    }

    @Test func reorderWithinSections() {
        var q = PlayQueue()
        q.replace(with: tracks("A", "B", "C", "D"), startAt: 0)
        q.addToQueue(tracks("X", "Y", "Z"))
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
