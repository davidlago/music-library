import Foundation

/// A file in the iCloud backup, by its path inside the backup's folder (`docs/icloud-plan.md` §3).
public struct CloudEntry: Equatable, Sendable {
    public var path: String
    public var size: Int64
    public var modified: Date?
    /// False while iCloud still has to upload it; always true in a plain folder.
    public var isUploaded: Bool
    /// Why iCloud couldn't upload it, such as iCloud being full.
    public var uploadError: String?
    /// Its data is on this device, not only in iCloud; always true in a plain folder.
    public var isLocal: Bool

    public init(path: String, size: Int64, modified: Date?, isUploaded: Bool = true, uploadError: String? = nil, isLocal: Bool = true) {
        self.path = path; self.size = size; self.modified = modified; self.isUploaded = isUploaded; self.uploadError = uploadError
        self.isLocal = isLocal
    }
}

/// The backup's folder as the rest of the code sees it: the iCloud container on the devices, a plain folder in tests
/// and for a backup copied out by hand. Only the paths a backup holds can be named (`CloudBackup.isBackupPath`).
public protocol CloudStore: Sendable {
    /// Every file, leaving out hidden ones.
    func entries() throws -> [CloudEntry]
    /// Copies `source` (an APFS clone where it can) to `path`, replacing what's there, with `modified` as its
    /// modification date. The copy is made aside and renamed into place, so readers never see half a file.
    func upload(from source: URL, to path: String, modified: Date?) throws
    /// Replaces a small file, such as `backup.json`, atomically.
    func write(_ data: Data, to path: String) throws
    /// A small file's contents (at most `limit` bytes), or nil when there's none.
    func read(_ path: String, limit: Int) throws -> Data?
    func remove(_ path: String) throws
    /// Whether iCloud has uploaded the file (always, in a plain folder).
    func isUploaded(_ path: String) -> Bool
    /// Removes this device's copy of an uploaded file, keeping it in iCloud (nothing, in a plain folder).
    func evict(_ path: String) throws
    /// Waits until iCloud has uploaded the file, up to `timeout`; true when it has.
    func waitUntilUploaded(_ path: String, timeout: Duration) async -> Bool
}

extension CloudStore {
    public func waitUntilUploaded(_ path: String, timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !isUploaded(path) {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .seconds(2))
        }
        return true
    }
}

public enum CloudStoreError: Error, LocalizedError, Equatable {
    case unsafePath(String)
    case tooLarge(String)

    public var errorDescription: String? {
        switch self {
        case .unsafePath(let path): return "Refused to write outside the backup: \(path)"
        case .tooLarge(let path): return "\(path) in the backup is too large"
        }
    }
}

/// A backup in a folder. With `coordinated`, the folder is in the iCloud container: reads and writes go through
/// `NSFileCoordinator`, and upload state comes from iCloud's resource values.
public final class FolderCloudStore: CloudStore {
    public let root: URL
    public let coordinated: Bool

    public init(root: URL, coordinated: Bool = false) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.root = root
        self.coordinated = coordinated
    }

    /// `root/path`, for a path a backup holds that stays inside the folder.
    func url(for path: String) throws -> URL {
        guard CloudBackup.isBackupPath(path), let url = LibraryPath.resolve(path, in: root) else { throw CloudStoreError.unsafePath(path) }
        return url
    }

    public func entries() throws -> [CloudEntry] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey,
                                      .ubiquitousItemIsUploadedKey, .ubiquitousItemUploadingErrorKey, .ubiquitousItemDownloadingStatusKey]
        let rootPath = root.standardizedFileURL.path
        var entries: [CloudEntry] = []
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        for case let url as URL in e {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(rootPath + "/") else { continue }
            entries.append(CloudEntry(path: String(path.dropFirst(rootPath.count + 1)), size: Int64(values.fileSize ?? 0),
                                      modified: values.contentModificationDate,
                                      isUploaded: !coordinated || values.ubiquitousItemIsUploaded != false,
                                      uploadError: values.ubiquitousItemUploadingError?.localizedDescription,
                                      isLocal: !coordinated || values.ubiquitousItemDownloadingStatus == .current))
        }
        return entries.sorted { $0.path < $1.path }
    }

    public func upload(from source: URL, to path: String, modified: Date?) throws {
        let target = try url(for: path)
        try place(at: target) { partial in
            try FileManager.default.copyItem(at: source, to: partial)
            if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: partial.path) }
        }
    }

    public func write(_ data: Data, to path: String) throws {
        let target = try url(for: path)
        try place(at: target) { partial in try data.write(to: partial) }
    }

    public func read(_ path: String, limit: Int) throws -> Data? {
        let target = try url(for: path)
        var data: Data?
        try coordinate(target, writing: false) { url in
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let read = try handle.read(upToCount: limit + 1) ?? Data()
            guard read.count <= limit else { throw CloudStoreError.tooLarge(path) }
            data = read
        }
        return data
    }

    public func remove(_ path: String) throws {
        let target = try url(for: path)
        try coordinate(target, writing: true, options: .forDeleting) { url in
            do { try FileManager.default.removeItem(at: url) } catch CocoaError.fileNoSuchFile {}
        }
    }

    public func isUploaded(_ path: String) -> Bool {
        guard coordinated else { return true }
        guard var target = try? url(for: path) else { return false }
        target.removeAllCachedResourceValues()
        return (try? target.resourceValues(forKeys: [.ubiquitousItemIsUploadedKey]))?.ubiquitousItemIsUploaded == true
    }

    public func evict(_ path: String) throws {
        guard coordinated else { return }
        try FileManager.default.evictUbiquitousItem(at: try url(for: path))
    }

    /// Makes the file aside (in a replacement folder on the same volume, outside the backup) and renames it into place.
    private func place(at target: URL, _ make: (URL) throws -> Void) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let aside = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true)
        defer { try? fm.removeItem(at: aside) }
        let partial = aside.appendingPathComponent(target.lastPathComponent)
        try make(partial)
        try coordinate(target, writing: true, options: .forReplacing) { url in
            guard rename(partial.path, url.path) == 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path]) }
        }
    }

    private func coordinate(_ url: URL, writing: Bool, options: NSFileCoordinator.WritingOptions = [], _ body: (URL) throws -> Void) throws {
        guard coordinated else { return try body(url) }
        var coordinationError: NSError?
        var bodyError: Error?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        if writing {
            coordinator.coordinate(writingItemAt: url, options: options, error: &coordinationError) { url in
                do { try body(url) } catch { bodyError = error }
            }
        } else {
            coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { url in
                do { try body(url) } catch { bodyError = error }
            }
        }
        if let error = coordinationError ?? bodyError { throw error }
    }
}

extension CloudContainer {
    /// The backup in the container (`Music Library`), or nil without iCloud. Blocks while iCloud sets the container
    /// up, so never call it on the main thread.
    public static func backupStore(identifier: String) -> FolderCloudStore? {
        guard let container = url(identifier: identifier) else { return nil }
        return try? FolderCloudStore(root: container.appendingPathComponent("Music Library", isDirectory: true), coordinated: true)
    }
}
