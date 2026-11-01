import Foundation
import Testing
@testable import MusicLibraryCore

/// Phones' plays, likes and requests reaching the Mac through iCloud (P6), against a plain folder.
@Suite struct CloudInboxTests {
    let phoneID = "6F9619FF-8B86-D011-B42D-00C04FC964FF"

    func batch(_ f: SyncFixture, events: [SyncEvent], requests: [SyncRequest] = [], at: Date = Date()) throws -> CloudInboxBatch {
        CloudInboxBatch(libraryID: try #require(f.db.libraryID()), phoneID: phoneID, phoneName: "iPhone", writtenAt: at,
                        events: events, requests: requests)
    }

    @Test func aPhoneKeepsOneBatchWithEverythingPending() async throws {
        let f = try SyncFixture()
        let store = try FolderCloudStore(root: try TestSupport.tempDir())
        let like = SyncEvent(track: f.tracks[0], at: Date(timeIntervalSince1970: 1_793_456_712), kind: .like(true))
        let first = try batch(f, events: [like])
        try CloudInbox.send(first, phoneID: phoneID, to: store)
        let play = SyncEvent(track: f.tracks[1], at: Date(timeIntervalSince1970: 1_793_456_800), kind: .play(listened: 90, counted: true))
        let second = try batch(f, events: [like, play], requests: [SyncRequest(item: .track(f.tracks[2].id), include: true)])
        try CloudInbox.send(second, phoneID: phoneID, to: store)

        let pending = try await CloudInbox.pending(in: store, scratch: try TestSupport.tempDir())
        #expect(pending.count == 1)
        #expect(pending.first?.batch?.events == second.events && pending.first?.batch?.requests == second.requests)
        #expect(CloudInbox.parse(try #require(pending.first?.path))?.phoneID == phoneID)

        // Nothing pending: the phone's batch goes.
        try CloudInbox.send(nil, phoneID: phoneID, to: store)
        #expect(try await CloudInbox.pending(in: store, scratch: try TestSupport.tempDir()).isEmpty)
    }

    @Test func eachEventAndRequestIsAppliedOnceWhicheverWayItCame() throws {
        let f = try SyncFixture()
        let like = SyncEvent(track: f.tracks[0], at: Date(), kind: .like(true))
        let b = try batch(f, events: [like], requests: [SyncRequest(item: .track(f.tracks[1].id), include: true)])
        // Through iCloud, then the same again (a re-sent batch, or a Wi-Fi sync).
        #expect(try f.db.applySyncEvents(b.events, libraryID: b.libraryID).likes == 1)
        #expect(try f.db.applySyncEvents(b.events, libraryID: b.libraryID).likes == 0)
        #expect(try f.db.markRequestsApplied(b.requests) == b.requests)
        #expect(try f.db.markRequestsApplied(b.requests).isEmpty)
        #expect(f.db.appliedSyncIDs(among: b.ids.union(["not-applied"])) == b.ids)
    }

    @Test func anotherLibrarysEventsAreDropped() throws {
        let f = try SyncFixture()
        let like = SyncEvent(track: f.tracks[0], at: Date(), kind: .like(true))
        let result = try f.db.applySyncEvents([like], libraryID: "some-other-library")
        #expect(result.likes == 0 && result.dropped == 1)
        #expect(try f.db.likedTrackDates().isEmpty)
    }

    @Test func badBatchesAndPathsAreRefused() async throws {
        let f = try SyncFixture()
        let store = try FolderCloudStore(root: try TestSupport.tempDir())
        let inbox = store.root.appendingPathComponent("Inbox/\(phoneID)")
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: inbox.appendingPathComponent("11111111-1111-1111-1111-111111111111.json"))
        var newer = try batch(f, events: [])
        newer.format = 2
        try newer.encoded().write(to: inbox.appendingPathComponent("22222222-2222-2222-2222-222222222222.json"))
        try Data("x".utf8).write(to: inbox.appendingPathComponent("notes.txt"))
        let odd = store.root.appendingPathComponent("Inbox/not a phone")
        try FileManager.default.createDirectory(at: odd, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: odd.appendingPathComponent("33333333-3333-3333-3333-333333333333.json"))

        let pending = try await CloudInbox.pending(in: store, scratch: try TestSupport.tempDir())
        #expect(pending.count == 2 && pending.allSatisfy { $0.batch == nil })
        #expect(CloudInboxBatch.decode(Data(repeating: 0x20, count: CloudInboxBatch.sizeLimit + 1)) == nil)
        for bad in ["Inbox/../x.json", "Inbox/\(phoneID)/../x.json", "Inbox/\(phoneID).json", "Inbox/a/b/c.json", "Inbox/\(phoneID)/x.txt"] {
            #expect(CloudInbox.parse(bad) == nil, "\(bad)")
        }
        #expect(throws: CloudStoreError.unsafePath("Inbox/x/../../etc.json")) { try store.write(Data(), to: "Inbox/x/../../etc.json") }
    }

    @Test func thePhoneLearnsWhatTheMacApplied() async throws {
        let f = try SyncFixture()
        let store = try FolderCloudStore(root: try TestSupport.tempDir())
        let like = SyncEvent(track: f.tracks[0], at: Date(), kind: .like(true))
        let later = SyncEvent(track: f.tracks[1], at: Date(), kind: .like(true))
        let request = SyncRequest(item: .track(f.tracks[2].id), include: true)
        // The Mac applied the like and the request; the second like came after its backup.
        _ = try f.db.applySyncEvents([like], libraryID: f.db.libraryID())
        _ = try f.db.markRequestsApplied([request])
        _ = try await CloudBackup.publish(database: f.db, root: f.root, store: store,
                                          identity: CloudBackupIdentity(macID: "m", macName: "Mac", appVersion: "1"), scope: .library,
                                          scratch: try TestSupport.tempDir(), limits: CloudUploadLimits(snapshotTimeout: .seconds(1)))
        let root = try TestSupport.tempDir().appendingPathComponent("Music Library")
        let outcome = try await CloudReceiver.receive(from: store, into: root, scratch: try TestSupport.tempDir(),
                                                      pending: [like.id, later.id, request.id])
        #expect(outcome.database == .replaced && outcome.applied == [like.id, request.id])
    }
}
