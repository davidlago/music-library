import Foundation

/// The Mac App Store build runs in the App Sandbox (`scripts/build-app.sh SANDBOX=1`, `scripts/mac-app-store.sh`);
/// the Developer ID build from GitHub doesn't. The same code runs in both and asks here when it matters: folders
/// outside the app's container are reachable only through the user's choice (an open panel or a drop), kept across
/// launches as security-scoped bookmarks (`FolderBookmarks`), and only the app's own ffmpeg, ffprobe and fpcalc run.
public enum AppSandbox {
    /// True when this process runs in the App Sandbox.
    public static let isActive: Bool = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil

    /// The user's real home folder. In the sandbox `homeDirectoryForCurrentUser` and `NSHomeDirectory()` are the
    /// app's container, so paths built from them would differ from the Developer ID build's.
    public static var realHome: URL {
        if let dir = getpwuid(getuid())?.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
}

#if os(macOS)
/// Folders the user chose (the library folder, the Export List's destination), kept as security-scoped bookmarks in
/// user defaults next to the plain path the app has always stored, so the sandboxed build can open them again after
/// a relaunch. Outside the sandbox nothing is stored and paths are used as they are.
///
/// Access to a resolved folder is held until another folder replaces it under the same key (`save`/`forget`).
@MainActor
public final class FolderBookmarks {
    public static let shared = FolderBookmarks()

    private let defaults: UserDefaults
    private let sandboxed: Bool
    private var accessing: [String: URL] = [:]

    public init(defaults: UserDefaults = .standard, sandboxed: Bool = AppSandbox.isActive) {
        self.defaults = defaults
        self.sandboxed = sandboxed
    }

    static func bookmarkKey(_ key: String) -> String { key + "Bookmark" }

    /// Remembers `url`, which the user just chose, for `key`, and keeps access to it. Returns false when the
    /// sandboxed build couldn't make a bookmark (the folder is then usable only until the app quits).
    @discardableResult
    public func save(_ url: URL, for key: String) -> Bool {
        guard sandboxed else { return true }
        stop(key)
        guard let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) else {
            defaults.removeObject(forKey: Self.bookmarkKey(key))
            return false
        }
        defaults.set(data, forKey: Self.bookmarkKey(key))
        if url.startAccessingSecurityScopedResource() { accessing[key] = url }
        return true
    }

    /// The folder saved for `key`, with access started, or `path` as it is outside the sandbox. Nil in the sandbox
    /// when there's no usable bookmark: the user has to choose the folder again.
    public func resolve(path: String?, for key: String) -> URL? {
        guard sandboxed else { return path.map { URL(fileURLWithPath: $0, isDirectory: true) } }
        if let url = accessing[key] { return url }
        guard let data = defaults.data(forKey: Self.bookmarkKey(key)) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else { return nil }
        guard url.startAccessingSecurityScopedResource() else { return nil }
        accessing[key] = url
        if stale, let fresh = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            defaults.set(fresh, forKey: Self.bookmarkKey(key))
        }
        return url
    }

    /// Drops the folder saved for `key`.
    public func forget(_ key: String) {
        stop(key)
        defaults.removeObject(forKey: Self.bookmarkKey(key))
    }

    private func stop(_ key: String) {
        accessing.removeValue(forKey: key)?.stopAccessingSecurityScopedResource()
    }
}
#endif
