import Foundation
import MusicLibraryCore
import Network
import Observation
import SystemConfiguration

/// What a sync needs from the library, read when it starts.
struct SyncContext {
    var libraryRoot: URL
    var database: Database
    var lastFM: SyncLastFM?
    var concerts: SyncConcertSettings?
    /// Every track in the library.
    var library: [Track]
    var tracks: (ExportItem) -> [Track]
    /// What you own, for each phone's Collection on iPhone.
    var collection: MusicCollection
}

/// Wi-Fi sync to the iPhone app: phones nearby, pairing, what to keep on the phone (its own selection, apart from the
/// Export List, because the phone mirrors it), and running syncs, started here or from the phone (the Mac listens
/// for each paired phone while it runs).
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
        /// Before the phone could ask for music: a plain list of items.
        static let list = "iPhoneSyncList"
        static let selection = "iPhoneSyncSelection"
        static let phones = "iPhonePairedPhones"
        static let macID = "syncMacID"
        static func key(_ phoneID: String) -> String { "syncKey.\(phoneID)" }
        static func collectionScope(_ phoneID: String) -> String { "iPhoneCollectionScope.\(phoneID)" }
    }

    private(set) var selection: SyncSelection {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(selection), forKey: Keys.selection) }
    }
    private(set) var phones: [PairedPhone] {
        didSet {
            UserDefaults.standard.set(try? JSONEncoder().encode(phones), forKey: Keys.phones)
            if Set(phones.map(\.id)) != Set(oldValue.map(\.id)) { updateListeners() }
        }
    }
    /// Collection on iPhone, per phone: the digital copies of what you own that go to it on top of the list (never
    /// sent to the phone as a setting; only the songs are).
    private(set) var collectionScopes: [String: CollectionSyncScope] = [:]
    private(set) var nearby: [SyncPeer] = []
    private(set) var activity: Activity = .idle
    private(set) var lastError: String?
    /// The first sync to a phone found files to remove and is waiting for the user to agree.
    private(set) var pendingDeletes: Int?

    /// Called after a sync that added the phone's plays, likes or ownership changes to the library.
    @ObservationIgnored var onHistoryChanged: () -> Void = {}
    /// The library as a sync needs it; nil while no library is open.
    @ObservationIgnored var context: () -> SyncContext? = { nil }
    @ObservationIgnored private var browser: SyncBrowser?
    /// One per paired phone, so it can start a sync.
    @ObservationIgnored private var listeners: [String: SyncAdvertiser] = [:]
    @ObservationIgnored private var listening = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var deleteApproval: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private let keychain = KeychainStore.app
    @ObservationIgnored let identity: SyncIdentity

    init() {
        let defaults = UserDefaults.standard
        selection = defaults.data(forKey: Keys.selection).flatMap { try? JSONDecoder().decode(SyncSelection.self, from: $0) }
            ?? SyncSelection(items: defaults.data(forKey: Keys.list).flatMap { try? JSONDecoder().decode([ExportItem].self, from: $0) } ?? [])
        let paired = defaults.data(forKey: Keys.phones).flatMap { try? JSONDecoder().decode([PairedPhone].self, from: $0) } ?? []
        phones = paired
        var scopes: [String: CollectionSyncScope] = [:]
        for phone in paired {
            if let scope = defaults.string(forKey: Keys.collectionScope(phone.id)).flatMap(CollectionSyncScope.init(rawValue:)) {
                scopes[phone.id] = scope
            }
        }
        let id = defaults.string(forKey: Keys.macID) ?? {
            let new = UUID().uuidString
            defaults.set(new, forKey: Keys.macID)
            return new
        }()
        let name = SCDynamicStoreCopyComputerName(nil, nil) as String? ?? "Mac"
        identity = SyncIdentity(deviceID: id, deviceName: name, appVersion: AppInfo.version)
        collectionScopes = scopes
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

    // MARK: Collection on iPhone

    func collectionScope(for phone: PairedPhone) -> CollectionSyncScope { collectionScopes[phone.id] ?? .off }

    func setCollectionScope(_ scope: CollectionSyncScope, for phone: PairedPhone) {
        collectionScopes[phone.id] = scope
        UserDefaults.standard.set(scope.rawValue, forKey: Keys.collectionScope(phone.id))
    }

    /// The albums a phone's Collection on iPhone puts on it, as include rules before the list's own.
    func implicit(for phoneID: String, _ context: SyncContext) -> [ExportItem] {
        context.collection.syncItems(collectionScopes[phoneID] ?? .off)
    }

    /// What every paired phone's scope adds: when the list is tidied, a Remove from iPhone stays while any phone's
    /// scope would put those songs back (the list is shared by the phones).
    private func implicitForAll(_ context: SyncContext) -> [ExportItem] {
        var seen = Set<ExportItem>()
        return Set(collectionScopes.values).sorted { $0.rawValue < $1.rawValue }
            .flatMap { context.collection.syncItems($0) }.filter { seen.insert($0).inserted }
    }

    // MARK: Selection

    /// Puts the items on the phone at the next sync, even where a later rule kept them off.
    func add(_ items: [ExportItem]) {
        guard let context = context() else { return }
        let implicit = implicitForAll(context)
        for item in items { selection.apply(item, include: true, tracks: { Set(context.tracks($0).map(\.id)) }, implicit: implicit) }
    }

    /// Drops albums, artists and songs that left the library from the list (they'd stay there with no songs).
    func dropMissing() {
        guard let context = context(), !context.library.isEmpty else { return }
        var pruned = selection
        pruned.dropMissing(tracks: { Set(context.tracks($0).map(\.id)) }, implicit: implicitForAll(context))
        if pruned != selection { selection = pruned }
    }

    /// Deletes rules from the list (an exclusion deleted puts its songs back).
    func remove(_ rules: Set<SyncSelection.Rule>) { selection.rules.removeAll { rules.contains($0) } }

    func contains(_ item: ExportItem) -> Bool {
        guard let context = context() else { return false }
        return selection.contains(item, tracks: context.tracks)
    }

    /// Everything the selection puts on the phone, each once, with what its Collection on iPhone adds first.
    func tracks(_ context: SyncContext, phoneID: String) -> [Track] {
        selection.resolve(context.tracks, implicit: implicit(for: phoneID, context))
    }

    /// Applies what the phone asked for, in order; on a phone's first sync started from the phone, what's already on
    /// it is added to the selection first (so nothing it has is removed without being asked).
    private func applyRequests(_ manifest: SyncManifest, adopting: Bool, phoneID: String) -> SyncTracks {
        guard let context = context() else { return SyncTracks(tracks: []) }
        let implicit = implicitForAll(context)
        let ids: (ExportItem) -> Set<Int64> = { Set(context.tracks($0).map(\.id)) }
        if adopting {
            let paths = Set(manifest.files.map(\.path))
            let present = context.library.filter { paths.contains($0.path) }
            var albums = Set<String>()
            for t in present {
                let album = ExportItem.album(album: t.album, artist: t.effectiveAlbumArtist)
                let all = context.tracks(album)
                if all.allSatisfy({ paths.contains($0.path) }) {
                    if albums.insert(SearchIndex.albumKey(album: t.album, artist: t.effectiveAlbumArtist)).inserted {
                        selection.apply(album, include: true, tracks: ids, implicit: implicit)
                    }
                } else {
                    selection.apply(.track(t.id), include: true, tracks: ids, implicit: implicit)
                }
            }
        }
        for request in manifest.requests.sorted(by: { $0.at < $1.at }) {
            selection.apply(request.item, include: request.include, tracks: ids, implicit: implicit)
        }
        return SyncTracks(tracks: tracks(context, phoneID: phoneID), library: context.library)
    }

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
        collectionScopes[phone.id] = nil
        UserDefaults.standard.removeObject(forKey: Keys.collectionScope(phone.id))
        phones.removeAll { $0.id == phone.id }
    }

    // MARK: Listening for phones

    /// Advertises this Mac to each paired phone, so the phone can start a sync (to download or remove music).
    func startListening() {
        listening = true
        updateListeners()
    }

    private func updateListeners() {
        guard listening else { return }
        for (id, listener) in listeners where !phones.contains(where: { $0.id == id }) {
            listener.stop()
            listeners[id] = nil
        }
        for phone in phones where listeners[phone.id] == nil {
            guard let key = key(for: phone) else { continue }
            let phoneID = phone.id
            do {
                let listener = try SyncAdvertiser(
                    macID: identity.deviceID, phoneID: phoneID, name: "\(identity.deviceName) (\(phoneID.prefix(4)))", key: key,
                    onConnection: { [weak self] connection in Task { @MainActor in self?.accept(connection, phoneID: phoneID) } })
                listener.start()
                listeners[phoneID] = listener
            } catch {
                lastError = "Couldn't listen for \(phone.name): \(error.localizedDescription)"
            }
        }
    }

    private func key(for phone: PairedPhone) -> Data? {
        keychain.string(for: Keys.key(phone.id)).flatMap { Data(base64Encoded: $0) }.flatMap { $0.count == 32 ? $0 : nil }
    }

    /// A paired phone connected to sync (only that phone has the key its listener uses).
    private func accept(_ connection: NWConnection, phoneID: String) {
        guard let phone = phones.first(where: { $0.id == phoneID }) else { connection.cancel(); return }
        guard !isBusy else {
            let busy = SyncConnection(connection)
            Task {
                try? await busy.open()
                try? await busy.send(.failure("The Mac is busy with another sync. Try again in a moment."))
                await busy.close()
            }
            return
        }
        run(phone, connection: SyncConnection(connection), fromPhone: true)
    }

    // MARK: Syncing

    /// Syncs the selection to `phone` (which must have its Sync tab open), bringing back its plays, likes and
    /// ownership changes and applying what it asked for; `lastFM` goes to a phone that isn't connected.
    func sync(_ phone: PairedPhone) {
        guard !isBusy, let peer = peer(for: phone) else { return }
        guard let key = key(for: phone) else {
            lastError = SyncError.notPaired.localizedDescription
            return
        }
        run(phone, connection: SyncConnection(endpoint: peer.endpoint, key: key), fromPhone: false)
    }

    /// A phone's first sync asks before removing anything from it when it's started here; one started from the
    /// phone keeps what's there instead (it's added to the selection).
    private func run(_ phone: PairedPhone, connection: SyncConnection, fromPhone: Bool) {
        guard let context = context() else {
            Task {
                try? await connection.open()
                try? await connection.send(.failure("No library is open on the Mac."))
                await connection.close()
            }
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
                let (_, summary) = try await SyncMacSession.sync(
                    connection, identity: identity,
                    selection: { manifest in await self.applyRequests(manifest, adopting: fromPhone && firstSync, phoneID: phone.id) },
                    libraryRoot: context.libraryRoot, database: context.database, scratch: scratch,
                    lastFM: context.lastFM, concerts: context.concerts,
                    approveDeletes: { count in firstSync ? (fromPhone ? false : await self.askToDelete(count)) : true },
                    progress: { progress in await self.report(phone.id, progress) })
                if let i = phones.firstIndex(where: { $0.id == phone.id }) {
                    phones[i].lastSync = Date()
                    phones[i].lastSummary = summary
                }
                if summary.plays > 0 || summary.likes > 0 || (summary.purchases ?? 0) > 0 { onHistoryChanged() }
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
