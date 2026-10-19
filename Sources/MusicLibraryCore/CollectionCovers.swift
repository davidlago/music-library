import Foundation

/// Covers of collection items that have their own (a record never digitized, a CD whose album left the library),
/// in `Music/Collection Covers` as "<item id>-<8 hex>.jpg", a new name on each change (views reload by file name).
/// The folder is under `Music`, so phones accept it from a sync, and it's not an album folder, so removing albums
/// never trashes it. Names come from `collection_items` rows, which are untrusted: only `isFileName` ones are used,
/// and only through `LibraryPath.resolve`.
public enum CollectionCovers {
    public static let folder = "Music/Collection Covers"

    /// `[a-z0-9-]{1,80}.jpg`, not starting with "-".
    public static func isFileName(_ s: String) -> Bool {
        guard s.hasSuffix(".jpg") else { return false }
        let base = s.dropLast(4)
        return (1...80).contains(base.count) && !base.hasPrefix("-") && base.unicodeScalars.allSatisfy(CollectionMedium.isRawScalar)
    }

    /// "Music/Collection Covers/<file>", when the name is allowed.
    public static func path(_ file: String) -> String? {
        isFileName(file) ? "\(folder)/\(file)" : nil
    }

    /// The cover file in the library at `root`, when the name is allowed and the folder stays inside `root`.
    public static func url(_ file: String, root: URL) -> URL? {
        path(file).flatMap { LibraryPath.resolve($0, in: root) }
    }

    /// Writes `jpeg` atomically as "<itemID>-<8 random hex>.jpg" and returns the name; the old file is removed by
    /// the caller after the row is saved.
    public static func write(_ jpeg: Data, itemID: String, root: URL) throws -> String {
        guard CollectionItem.isValidID(itemID), let dir = LibraryPath.resolve(folder, in: root) else { throw CollectionError.invalidCover }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = "\(itemID)-\(String(format: "%08x", UInt32.random(in: .min ... .max))).jpg"
        guard let url = url(name, root: root) else { throw CollectionError.invalidCover }
        try jpeg.write(to: url, options: .atomic)
        return name
    }

    /// Copies an album's cover.jpg in as the item's own cover (before the album leaves the library).
    public static func adopt(albumCover: URL, itemID: String, root: URL) throws -> String {
        try write(try Data(contentsOf: albumCover), itemID: itemID, root: root)
    }
}
