import Foundation

/// What a phone sends the Mac through iCloud (`docs/icloud-plan.md` §6, P6): its plays and likes (`SyncEvent`) and its
/// Download / Remove requests (`SyncRequest`), the same things a Wi-Fi sync carries. Each batch holds everything the
/// phone still has pending, so a newer one replaces the phone's older ones and nothing is lost if the Mac reads only
/// the last; the Mac applies each event and request once, by id (`sync_events`), whichever way it arrives first.
/// Batches come from the container, so they're untrusted: size-limited, strictly decoded, and refused when their
/// format is newer.
public struct CloudInboxBatch: Codable, Equatable, Sendable {
    public static let currentFormat = 1
    static let sizeLimit = 8 * 1024 * 1024

    public var format: Int
    public var libraryID: String
    public var phoneID: String
    public var phoneName: String
    public var writtenAt: Date
    public var events: [SyncEvent]
    public var requests: [SyncRequest]

    public init(libraryID: String, phoneID: String, phoneName: String, writtenAt: Date = Date(),
                events: [SyncEvent], requests: [SyncRequest]) {
        format = Self.currentFormat
        self.libraryID = libraryID; self.phoneID = phoneID; self.phoneName = phoneName; self.writtenAt = writtenAt
        self.events = events; self.requests = requests
    }

    public static func decode(_ data: Data) -> CloudInboxBatch? {
        guard data.count <= sizeLimit else { return nil }
        // Dates as Wi-Fi sync sends them, to the fraction of a second (a like and an unlike can be that close).
        guard let batch = try? JSONDecoder().decode(CloudInboxBatch.self, from: data), batch.format == currentFormat,
              CloudInbox.isID(batch.phoneID), !batch.libraryID.isEmpty, batch.phoneName.count <= 200 else { return nil }
        return batch
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    /// The ids of what it carries, for telling which the Mac has applied.
    public var ids: Set<String> { Set(events.map(\.id) + requests.map(\.id)) }
}

public enum CloudInbox {
    public static let folder = "Inbox"

    /// "Inbox/<phone id>/<batch id>.json".
    public static func path(phoneID: String, batchID: String) -> String { "\(folder)/\(phoneID)/\(batchID).json" }

    /// The phone and batch a path names, or nil for anything else.
    public static func parse(_ path: String) -> (phoneID: String, batchID: String)? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == folder, parts[2].hasSuffix(".json") else { return nil }
        let phone = String(parts[1]), batch = String(parts[2].dropLast(".json".count))
        return isID(phone) && isID(batch) ? (phone, batch) : nil
    }

    /// Ids are UUIDs as the apps make them; letters, digits and hyphens, at most 64.
    static func isID(_ s: String) -> Bool {
        (1...64).contains(s.count) && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    /// Phone: puts `batch` in the inbox and removes the phone's earlier batches; with nil (nothing pending), only
    /// removes them.
    public static func send(_ batch: CloudInboxBatch?, phoneID: String, to store: CloudStore) throws {
        let earlier = try store.entries(under: "\(folder)/\(phoneID)").map(\.path).filter { parse($0)?.phoneID == phoneID }
        var written: String?
        if let batch {
            let path = path(phoneID: phoneID, batchID: UUID().uuidString)
            try store.write(try batch.encoded(), to: path)
            written = path
        }
        for path in earlier where path != written { try? store.remove(path) }
    }

    /// Mac: the batches waiting, oldest first, each read (downloaded when it's only in iCloud) and decoded; nil for one
    /// that can't be read, to be deleted.
    public static func pending(in store: CloudStore, scratch: URL) async throws -> [(path: String, batch: CloudInboxBatch?)] {
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        var found: [(path: String, batch: CloudInboxBatch?)] = []
        for entry in try store.entries(under: folder) where parse(entry.path) != nil {
            guard entry.size <= CloudInboxBatch.sizeLimit else { found.append((entry.path, nil)); continue }
            let copy = scratch.appendingPathComponent("inbox-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: copy) }
            try await store.copyOut(entry.path, to: copy)
            found.append((entry.path, (try? Data(contentsOf: copy)).flatMap(CloudInboxBatch.decode)))
        }
        return found.sorted { ($0.batch?.writtenAt ?? .distantPast) < ($1.batch?.writtenAt ?? .distantPast) }
    }
}

extension Database {
    /// Records requests (by id) as applied, like events in `sync_events`, and returns the ones that weren't yet, so a
    /// request that arrives both through iCloud and over Wi-Fi is applied once.
    public func markRequestsApplied(_ requests: [SyncRequest], now: Date = Date()) throws -> [SyncRequest] {
        try transaction {
            try requests.filter { request in
                !(try query("INSERT OR IGNORE INTO sync_events(id,applied_at) VALUES(?,?) RETURNING id",
                            [.text(request.id), .double(now.timeIntervalSince1970)]) { $0.string(0) }).isEmpty
            }
        }
    }

    /// Which of `ids` (events and requests) this library has applied.
    public func appliedSyncIDs(among ids: Set<String>) -> Set<String> {
        var applied = Set<String>()
        let all = Array(ids)
        for start in stride(from: 0, to: all.count, by: 500) {
            let chunk = Array(all[start..<min(start + 500, all.count)])
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let found = (try? query("SELECT id FROM sync_events WHERE id IN (\(marks))", chunk.map { .text($0) }) { $0.string(0) }) ?? []
            applied.formUnion(found.compactMap { $0 })
        }
        return applied
    }
}
