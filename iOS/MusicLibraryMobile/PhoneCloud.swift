import Foundation
import MusicLibraryCore
import Observation
import UIKit

/// The library from the Mac's iCloud backup (`docs/icloud-plan.md` §6, P4): while the app is open (and every couple of
/// minutes then), it brings the database, covers and artist photos up to the newest backup with `CloudReceiver`, so
/// the library stays current without the Mac nearby, and a phone with no library gets one without pairing. A copy
/// from iCloud never replaces a newer one a Wi-Fi sync brought. Music still comes from the Mac. It also sends the
/// phone's plays, likes and Download / Remove requests to the Mac through iCloud (P6: `CloudInbox`), a few seconds
/// after each and at every check, and drops them from the phone once a backup shows the Mac applied them. Hidden in
/// builds without an iCloud container; Use iCloud (user defaults `useICloud`) is on by default. And when the Mac isn't
/// reachable, it fetches the songs asked for (Download) from the backup (P5, D16); a Wi-Fi sync starting stops it,
/// since the Mac has every song.
@Observable
final class PhoneCloud {
    enum Status: Equatable {
        case idle
        case checking
        case signedOut
        /// The phone holds another library than the one backed up.
        case otherLibrary
        case failed(String)
    }

    private enum Keys {
        static let enabled = "useICloud"
        static let lastUpdate = "iCloudLastUpdate"
        static let backupAt = "iCloudBackupAt"
        static let macName = "iCloudMacName"
    }

    let containerID = CloudContainer.identifier()
    var isAvailable: Bool { containerID != nil }
    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Keys.enabled)
            if isEnabled { check() } else { status = .idle }
        }
    }
    private(set) var status = Status.idle
    /// When a copy from iCloud last replaced the library here.
    private(set) var lastUpdate: Date? { didSet { UserDefaults.standard.set(lastUpdate, forKey: Keys.lastUpdate) } }
    /// The newest backup seen, and the Mac that made it.
    private(set) var backupAt: Date? { didSet { UserDefaults.standard.set(backupAt, forKey: Keys.backupAt) } }
    private(set) var macName: String? { didSet { UserDefaults.standard.set(macName, forKey: Keys.macName) } }

    /// A new database is in place.
    @ObservationIgnored var onLibraryChanged: () -> Void = {}
    /// A Wi-Fi sync is running (it writes the same files).
    @ObservationIgnored var isSyncing: () -> Bool = { false }

    /// What the phone has for the Mac; nil when nothing may be sent (the sample library, or no library).
    struct Outgoing {
        var libraryID: String
        var events: [SyncEvent]
        var requests: [SyncRequest]
    }
    @ObservationIgnored var outgoing: () -> Outgoing? = { nil }
    /// This phone's sync id and name.
    @ObservationIgnored var phone: () -> (id: String, name: String) = { ("", "") }
    /// The Mac applied these plays, likes and requests: they can leave the phone.
    @ObservationIgnored var onApplied: (Set<String>) -> Void = { _ in }
    /// When the phone last sent its changes through iCloud.
    private(set) var lastSent: Date?

    /// Songs asked for that aren't on the phone, and whether the Mac can send them now (nearby, or syncing).
    @ObservationIgnored var downloads: () -> [Track] = { [] }
    @ObservationIgnored var macReachable: () -> Bool = { false }
    struct Progress: Equatable {
        var done: Int
        var total: Int
    }
    /// Songs being fetched from iCloud.
    private(set) var fetching: Progress?
    /// Songs asked for that the backup doesn't hold: they wait for the Mac.
    private(set) var notInCloud: Set<Int64> = []
    /// Why the last fetch stopped, such as no room.
    private(set) var fetchProblem: String?
    @ObservationIgnored private var fetchTask: Task<Void, Never>?

    /// iCloud can be used on this phone.
    var isUsable: Bool { isAvailable && isEnabled }
    @ObservationIgnored private var sentKey: String?
    @ObservationIgnored private var sending: Task<Void, Never>?
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var running: Task<Void, Never>?
    @ObservationIgnored private var timer: Task<Void, Never>?

    init() {
        let defaults = UserDefaults.standard
        isEnabled = defaults.object(forKey: Keys.enabled) == nil ? true : defaults.bool(forKey: Keys.enabled)
        lastUpdate = defaults.object(forKey: Keys.lastUpdate) as? Date
        backupAt = defaults.object(forKey: Keys.backupAt) as? Date
        macName = defaults.string(forKey: Keys.macName)
    }

    /// Checks now and every two minutes while the app is active.
    func setActive(_ active: Bool) {
        timer?.cancel()
        timer = nil
        guard active, isAvailable else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                self?.check()
                try? await Task.sleep(for: .seconds(120))
            }
        }
    }

    func check() {
        guard let containerID, isEnabled, running == nil, !isSyncing() else { return }
        status = .checking
        let root = LibrarySnapshot.findRoot(in: URL.documentsDirectory) ?? LibraryLocation.defaultRoot
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("iCloud", isDirectory: true)
        let out = outgoing()
        let pending = Set((out?.events.map(\.id) ?? []) + (out?.requests.map(\.id) ?? []))
        running = Task {
            defer {
                running = nil
                send()
                fetchDownloads()
            }
            let result = await Self.receive(containerID: containerID, root: root, scratch: scratch, pending: pending)
            switch result {
            case .success(nil):
                status = .signedOut
            case .success(let outcome?):
                status = outcome.database == .otherLibrary ? .otherLibrary : .idle
                if let at = outcome.backupAt { backupAt = at; macName = outcome.macName }
                if outcome.database == .replaced {
                    lastUpdate = Date()
                    if !outcome.applied.isEmpty { onApplied(outcome.applied) }
                    onLibraryChanged()
                }
            case .failure(let error):
                status = .failed(error.localizedDescription)
            }
        }
    }

    /// Off the main thread: finding the container can block while iCloud sets it up.
    // MARK: Downloads

    /// Fetches the songs asked for from iCloud, unless the Mac can send them (D16).
    func fetchDownloads() {
        guard let containerID, isEnabled, fetchTask == nil, !macReachable() else { return }
        let tracks = downloads()
        guard !tracks.isEmpty else {
            notInCloud = []
            fetchProblem = nil
            return
        }
        let root = LibrarySnapshot.findRoot(in: URL.documentsDirectory) ?? LibraryLocation.defaultRoot
        let free = (try? URL.documentsDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
        fetching = Progress(done: 0, total: 0)
        fetchProblem = nil
        // A little more time to finish the song being copied if the app goes to the background; iCloud keeps
        // downloading, and the rest is copied when the app is next active.
        let background = UIApplication.shared.beginBackgroundTask(withName: "iCloud downloads")
        fetchTask = Task {
            defer {
                fetchTask = nil
                fetching = nil
                UIApplication.shared.endBackgroundTask(background)
            }
            let result = await Self.fetch(tracks, containerID: containerID, root: root, free: free) { [weak self] done, total in
                Task { @MainActor in
                    guard let self, self.fetching != nil else { return }
                    self.fetching = Progress(done: done, total: total)
                    // Songs show as on the phone as they arrive, not only at the end.
                    if done > 0, done % 10 == 0 { self.onLibraryChanged() }
                }
            }
            switch result {
            case .success(let outcome?):
                notInCloud = outcome.notInCloud
                if outcome.files > 0 { onLibraryChanged() }
            case .success(nil):
                status = .signedOut
            case .failure(is CancellationError):
                onLibraryChanged()
            case .failure(let error):
                fetchProblem = error.localizedDescription
                onLibraryChanged()
            }
        }
    }

    /// A Wi-Fi sync started: the Mac sends the rest.
    func stopFetching() { fetchTask?.cancel() }

    nonisolated private static func fetch(_ tracks: [Track], containerID: String, root: URL, free: Int64?,
                                          progress: @escaping @Sendable (Int, Int) -> Void) async -> Result<CloudFetchOutcome?, Error> {
        await Task.detached(priority: .userInitiated) {
            guard FileManager.default.ubiquityIdentityToken != nil, let store = CloudContainer.backupStore(identifier: containerID) else {
                return .success(nil)
            }
            do {
                return .success(try await CloudReceiver.fetch(tracks, from: store, into: root, freeSpace: free, progress: progress))
            } catch {
                return .failure(error)
            }
        }.value
    }

    // MARK: Sending

    /// Plays, likes or requests changed: sent a few seconds later, so a run of them goes as one batch.
    func changesPending() {
        guard isAvailable, isEnabled else { return }
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.send()
        }
    }

    /// Replaces this phone's batch in the inbox with what's pending now (or removes it when nothing is). Skipped when
    /// nothing changed since the last one.
    private func send() {
        guard let containerID, isEnabled, sending == nil, let out = outgoing() else { return }
        let phone = phone()
        guard !phone.id.isEmpty else { return }
        let batch = out.events.isEmpty && out.requests.isEmpty ? nil
            : CloudInboxBatch(libraryID: out.libraryID, phoneID: phone.id, phoneName: phone.name, events: out.events, requests: out.requests)
        let key = batch.map { $0.ids.sorted().joined(separator: ",") } ?? ""
        guard key != sentKey else { return }
        sending = Task {
            defer { sending = nil }
            let sent = await Self.send(batch, phoneID: phone.id, containerID: containerID)
            if sent {
                sentKey = key
                if batch != nil { lastSent = Date() }
            }
        }
    }

    nonisolated private static func send(_ batch: CloudInboxBatch?, phoneID: String, containerID: String) async -> Bool {
        await Task.detached(priority: .utility) {
            guard FileManager.default.ubiquityIdentityToken != nil, let store = CloudContainer.backupStore(identifier: containerID) else { return false }
            return (try? CloudInbox.send(batch, phoneID: phoneID, to: store)) != nil
        }.value
    }

    nonisolated private static func receive(containerID: String, root: URL, scratch: URL, pending: Set<String>) async -> Result<CloudReceiveOutcome?, Error> {
        await Task.detached(priority: .utility) {
            guard FileManager.default.ubiquityIdentityToken != nil, let store = CloudContainer.backupStore(identifier: containerID) else {
                return .success(nil)
            }
            do {
                return .success(try await CloudReceiver.receive(from: store, into: root, scratch: scratch, pending: pending))
            } catch {
                return .failure(error)
            }
        }.value
    }
}
