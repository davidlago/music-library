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
