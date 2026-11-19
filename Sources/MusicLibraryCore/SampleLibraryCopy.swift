#if os(macOS)
import Foundation

/// The Mac app's built-in sample library: the iPhone app's `SampleLibrary.bundle` (made by
/// `scripts/make-sample-library.sh`), which `scripts/build-app.sh` puts in the app's resources. Exploring it copies it
/// to a folder of its own and opens that as the library, so App Review (and anyone without music yet) can try the
/// app; the user's own library folder is left alone and comes back with Use My Own Library.
public enum SampleLibraryCopy {
    /// The bundled sample, if this build has it.
    public static func bundled(in bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: "SampleLibrary", withExtension: "bundle")
    }

    /// Where the copy goes: Application Support/MusicLibrary/Sample Library (inside the container when sandboxed).
    public static var copyLocation: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("MusicLibrary/Sample Library", isDirectory: true)
    }

    /// True when `root` is the sample's copy.
    public static func isSample(_ root: URL) -> Bool {
        root.standardizedFileURL.path == copyLocation.standardizedFileURL.path
    }

    /// Replaces `destination` with a fresh copy of `source`, its history moved up so the last play is today
    /// (`LibrarySnapshot.dayShift`, as the iPhone shows it), and returns the copy.
    @discardableResult
    public static func install(from source: URL, to destination: URL = copyLocation, now: Date = Date()) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.copyItem(at: source, to: destination)
        // The bundle's own Info.plist isn't part of a library.
        try? fm.removeItem(at: destination.appendingPathComponent("Info.plist"))
        let db = try Database(path: destination.appendingPathComponent("library.sqlite").path)
        try db.moveSampleHistory(to: now)
        return destination
    }
}

extension Database {
    /// Moves every date of the sample's history (songs added, plays, likes, copies bought and added) forward by
    /// whole days, so its last play is today.
    func moveSampleHistory(to now: Date) throws {
        let latest = try query("SELECT COALESCE((SELECT MAX(started_at) FROM plays), (SELECT MAX(added_at) FROM tracks))") {
            $0.int(0) == nil ? nil : Date(timeIntervalSince1970: $0.double(0))
        }.first ?? nil
        let shift = LibrarySnapshot.dayShift(latest: latest, now: now)
        guard shift > 0 else { return }
        let days = Int(shift / 86_400)
        try transaction {
            try exec("UPDATE tracks SET added_at = added_at + ?", [.double(shift)])
            try exec("UPDATE plays SET started_at = started_at + ?", [.double(shift)])
            try exec("UPDATE liked_tracks SET liked_at = liked_at + ?", [.double(shift)])
            try exec("""
                UPDATE collection_items SET created_at = created_at + ?1, updated_at = updated_at + ?1,
                    purchased_on = CASE WHEN purchased_on IS NULL THEN NULL ELSE date(purchased_on, '+' || ?2 || ' days') END
                """, [.double(shift), .int(Int64(days))])
            try exec("""
                UPDATE track_purchases SET updated_at = updated_at + ?1,
                    purchased_on = CASE WHEN purchased_on IS NULL THEN NULL ELSE date(purchased_on, '+' || ?2 || ' days') END
                """, [.double(shift), .int(Int64(days))])
            // Older readers' album_ownership projection follows the copies, or the next open would take its old
            // dates for an older app's edits (CollectionLegacy).
            try projectLegacyOwnership(keys: nil)
        }
    }
}
#endif
