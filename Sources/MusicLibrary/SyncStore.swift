import Foundation
import MusicLibraryCore
import Observation
import SystemConfiguration

/// Wi-Fi sync to the iPhone app: phones nearby, pairing, the list of what to keep on the phone (its own list, apart
/// from the Export List, because the phone mirrors it), and running syncs.
@MainActor @Observable
final class SyncStore {
    struct PairedPhone: Codable, Hashable, Identifiable {
        var id: String
        var name: String
        var lastSync: Date?
        var lastSummary: SyncSummary?
    }

    enum Activity: Equatable {
        case idle
        case pairing(phoneID: String)
        case syncing(phoneID: String, SyncProgress)
    }

    private enum Keys {
        static let list = "iPhoneSyncList"
        static let phones = "iPhonePairedPhones"
        static let macID = "syncMacID"
        static func key(_ phoneID: String) -> String { "syncKey.\(phoneID)" }
    }

    private(set) var list: [ExportItem] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(list), forKey: Keys.list) }
    }
    private(set) var phones: [PairedPhone] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(phones), forKey: Keys.phones) }
    }
    private(set) var nearby: [SyncPeer] = []
    private(set) var activity: Activity = .idle
    private(set) var lastError: String?
    /// The first sync to a phone found files to remove and is waiting for the user to agree.
    private(set) var pendingDeletes: Int?

    /// Called after a sync that added the phone's plays or likes to the library.
    @ObservationIgnored var onHistoryChanged: () -> Void = {}
    @ObservationIgnored private var browser: SyncBrowser?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var deleteApproval: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private let keychain = KeychainStore.app
    @ObservationIgnored let identity: SyncIdentity

    init() {
        let defaults = UserDefaults.standard
        list = defaults.data(forKey: Keys.list).flatMap { try? JSONDecoder().decode([ExportItem].self, from: $0) } ?? []
        phones = defaults.data(forKey: Keys.phones).flatMap { try? JSONDecoder().decode([PairedPhone].self, from: $0) } ?? []
        let id = defaults.string(forKey: Keys.macID) ?? {
            let new = UUID().uuidString
            defaults.set(new, forKey: Keys.macID)
            return new
        }()
        let name = SCDynamicStoreCopyComputerName(nil, nil) as String? ?? "Mac"
        identity = SyncIdentity(deviceID: id, deviceName: name, appVersion: AppInfo.version)
    }

    var isBusy: Bool { activity != .idle }

    // MARK: Discovery

    /// Looks for phones while the iPhone page is open.
    func startBrowsing() {
        guard browser == nil else { return }
        let browser = SyncBrowser { [weak self] peers in Task { @MainActor in self?.nearby = peers } }
        browser.start()
        self.browser = browser
    }

    func stopBrowsing() {
        browser?.stop()
        browser = nil
        nearby = []
    }

    /// The phone, when it's nearby and ready to sync (not showing a pairing code).
    func peer(for phone: PairedPhone) -> SyncPeer? {
        nearby.first { $0.id == phone.id && !$0.isPairing }
    }

    /// Phones nearby showing a pairing code.
    var pairingPeers: [SyncPeer] { nearby.filter(\.isPairing) }

    // MARK: List

    func add(_ items: [ExportItem]) {
        let new = items.filter { !list.contains($0) }
        if !new.isEmpty { list += new }
    }

    func remove(_ items: Set<ExportItem>) { list.removeAll { items.contains($0) } }

    func contains(_ item: ExportItem) -> Bool { list.contains(item) }

    // MARK: Pairing

    func pair(_ peer: SyncPeer, code typed: String) {
        guard !isBusy else { return }
        guard let code = SyncPairing.normalize(typed) else {
            lastError = "That isn't a whole code: it's \(SyncPairing.codeLength) letters and digits, like \(SyncPairing.display("ABCDE12345"))."
            return
        }
        lastError = nil
        activity = .pairing(phoneID: peer.id)
        let identity = identity
        task = Task {
            defer { activity = .idle }
            do {
                let (phone, key) = try await SyncMacSession.pair(endpoint: peer.endpoint, code: code, identity: identity)
                keychain.set(key.base64EncodedString(), for: Keys.key(phone.deviceID))
                phones.removeAll { $0.id == phone.deviceID }
                phones.append(PairedPhone(id: phone.deviceID, name: phone.deviceName))
            } catch {
                lastError = "Couldn't pair with \(peer.name): \(Self.describe(error, pairing: true))"
            }
        }
    }

    func unpair(_ phone: PairedPhone) {
        keychain.remove(Keys.key(phone.id))
        phones.removeAll { $0.id == phone.id }
    }

    // MARK: Syncing

    /// Syncs `tracks` to `phone`, bringing back its plays and likes; `lastFM` goes to a phone that isn't connected.
    func sync(_ phone: PairedPhone, tracks: [Track], libraryRoot: URL, database: Database, lastFM: SyncLastFM?) {
        guard !isBusy, let peer = peer(for: phone) else { return }
        guard let key = keychain.string(for: Keys.key(phone.id)).flatMap({ Data(base64Encoded: $0) }) else {
            lastError = SyncError.notPaired.localizedDescription
            return
        }
        lastError = nil
        activity = .syncing(phoneID: phone.id, SyncProgress())
        let identity = identity
        let firstSync = phone.lastSync == nil
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("MusicLibrarySync", isDirectory: true)
        task = Task {
            defer { activity = .idle }
            do {
                let summary = try await SyncMacSession.sync(
                    endpoint: peer.endpoint, key: key, identity: identity, tracks: tracks, libraryRoot: libraryRoot,
                    database: database, scratch: scratch, lastFM: lastFM,
                    approveDeletes: { count in firstSync ? await self.askToDelete(count) : true },
                    progress: { progress in await self.report(phone.id, progress) })
                if let i = phones.firstIndex(where: { $0.id == phone.id }) {
                    phones[i].lastSync = Date()
                    phones[i].lastSummary = summary
                }
                if summary.plays > 0 || summary.likes > 0 { onHistoryChanged() }
            } catch is CancellationError {
                lastError = "Sync cancelled. Everything copied so far is on the iPhone."
            } catch {
                lastError = "Sync with \(phone.name) failed: \(Self.describe(error, pairing: false))"
            }
        }
    }

    func cancel() {
        task?.cancel()
        answerDeletes(false)
    }

    /// The answer to `pendingDeletes`: remove those files from the phone, or keep them this time.
    func answerDeletes(_ remove: Bool) {
        pendingDeletes = nil
        deleteApproval?.resume(returning: remove)
        deleteApproval = nil
    }

    private func askToDelete(_ count: Int) async -> Bool {
        await withCheckedContinuation { continuation in
            deleteApproval = continuation
            pendingDeletes = count
        }
    }

    private func report(_ phoneID: String, _ progress: SyncProgress) {
        if case .syncing(phoneID, _) = activity { activity = .syncing(phoneID: phoneID, progress) }
    }

    private static func describe(_ error: Error, pairing: Bool) -> String {
        if pairing, case SyncError.connection = error {
            return "check the code and that the iPhone still shows it."
        }
        return error.localizedDescription
    }
}
