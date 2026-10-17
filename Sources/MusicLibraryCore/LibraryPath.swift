import Foundation

/// Track paths come from `library.sqlite`, which may have been made anywhere (a copied library, a backup drive),
/// so they are only turned into file URLs once they're known to stay inside the folder they are relative to.
public enum LibraryPath {
    /// True for a plain relative path such as "Music/Artist/Album/01 - Song.flac": not absolute, and no empty,
    /// "." or ".." components.
    public static func isPlainRelative(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0") else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    /// `base/path`, or nil when `path` isn't plain relative or symlinks take it outside `base`.
    public static func resolve(_ path: String, in base: URL) -> URL? {
        guard isPlainRelative(path), let realBase = realPath(base) else { return nil }
        let url = base.appendingPathComponent(path)
        guard let real = realPath(url), real.hasPrefix(realBase.hasSuffix("/") ? realBase : realBase + "/") else { return nil }
        return url
    }

    /// The `cover.jpg` next to the library file at `trackPath`, if that stays inside `root`.
    public static func coverURL(forTrackAt trackPath: String, root: URL) -> URL? {
        guard isPlainRelative(trackPath) else { return nil }
        return resolve(((trackPath as NSString).deletingLastPathComponent as NSString).appendingPathComponent("cover.jpg"), in: root)
    }

    /// Folders left with nothing worth keeping once the library files `removed` are gone: their folders when only
    /// a `cover.jpg` or hidden files remain, and those folders' parents when that leaves them with only hidden
    /// files. Only folders at least two levels inside `root` (album and artist folders under `Music`) qualify, and
    /// a folder is listed instead of the folders inside it.
    public static func emptiedFolders(after removed: [URL], root: URL) -> [URL] {
        let fm = FileManager.default
        let rootComponents = root.standardizedFileURL.pathComponents
        func qualifies(_ folder: URL) -> Bool {
            let components = folder.standardizedFileURL.pathComponents
            return components.count >= rootComponents.count + 2 && Array(components.prefix(rootComponents.count)) == rootComponents
        }
        func isLeftover(_ folder: URL, allowing: (String) -> Bool) -> Bool {
            guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return false }
            return names.allSatisfy { $0.hasPrefix(".") || allowing($0) }
        }
        var emptied: [URL] = []
        let folders = Set(removed.map { $0.deletingLastPathComponent().standardizedFileURL })
        for folder in folders.sorted(by: { $0.path < $1.path }) where qualifies(folder) {
            guard isLeftover(folder, allowing: { $0 == "cover.jpg" }) else { continue }
            emptied.append(folder)
        }
        let emptiedNames = Set(emptied.map(\.path))
        for parent in Set(emptied.map { $0.deletingLastPathComponent() }).sorted(by: { $0.path < $1.path }) where qualifies(parent) {
            guard isLeftover(parent, allowing: { emptiedNames.contains(parent.appendingPathComponent($0).path) }) else { continue }
            emptied.removeAll { $0.deletingLastPathComponent().path == parent.path }
            emptied.append(parent)
        }
        return emptied
    }

    /// `url` with symlinks resolved in the part that exists and the missing rest appended unchanged.
    /// Nil when a component can't be resolved, e.g. a dangling symlink that a write would follow.
    static func realPath(_ url: URL) -> String? {
        var existing = url.standardizedFileURL.path
        var missing: [String] = []
        var info = stat()
        while lstat(existing, &info) != 0 {
            guard errno == ENOENT, existing != "/" else { return nil }
            missing.insert((existing as NSString).lastPathComponent, at: 0)
            existing = (existing as NSString).deletingLastPathComponent
        }
        guard let resolved = realpath(existing, nil) else { return nil }
        defer { free(resolved) }
        return missing.reduce(String(cString: resolved)) { ($0 as NSString).appendingPathComponent($1) }
    }
}
