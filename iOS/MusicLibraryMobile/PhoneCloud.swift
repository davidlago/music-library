import Foundation
import MusicLibraryCore
import Observation

/// The library from the Mac's iCloud backup (`docs/icloud-plan.md` §6, P4): while the app is open (and every couple of
/// minutes then), it brings the database, covers and artist photos up to the newest backup with `CloudReceiver`, so
/// the library stays current without the Mac nearby, and a phone with no library gets one without pairing. A copy
/// from iCloud never replaces a newer one a Wi-Fi sync brought. Music still comes from the Mac. It also sends the
/// phone's plays, likes and Download / Remove requests to the Mac through iCloud (P6: `CloudInbox`), a few seconds
/// after each and at every check, and drops them from the phone once a backup shows the Mac applied them. Hidden in
/// builds without an iCloud container; Use iCloud (user defaults `useICloud`) is on by default.
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
