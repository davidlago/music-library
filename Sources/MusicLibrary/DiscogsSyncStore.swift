import Foundation
import MusicLibraryCore

/// Sync to Discogs: the user's account (personal access token in the keychain, username and the folder new copies go
/// in in user defaults), and one sync at a time: matching CDs and records to releases, reading the Discogs
/// collection, the plan shown in `DiscogsSyncSheet`, then the changes picked there. One way: nothing on Discogs
/// changes the collection here (see `DiscogsCollection.swift`).
@MainActor @Observable
final class DiscogsSyncStore {
    private enum Keys {
        static let username = "discogsUsername"
        static let folder = "discogsFolderID"
    }

    enum Phase: Equatable {
        case idle
        /// What it's doing, and how far along when that's known (0…1).
        case preparing(String, Double?)
        case ready
        case syncing(done: Int, of: Int)
        case finished(DiscogsSyncOutcome)
        case failed(String)
    }

    private(set) var username: String?
    private(set) var hasToken: Bool
    /// Where added copies go (never 0, "All").
    var folderID: Int {
        didSet { UserDefaults.standard.set(folderID, forKey: Keys.folder) }
    }
    private(set) var folders: [DiscogsFolder] = []
    private(set) var isConnecting = false
    private(set) var connectionError: String?

    private(set) var phase: Phase = .idle
    private(set) var plan: DiscogsSyncPlan?
    var chosenAdditions: Set<String> = []
    /// Never picked for the user: removals are only made when ticked.
    var chosenRemovals: Set<Int> = []
    /// How sure each item's match is, for the plan's additions.
    private(set) var qualities: [String: DiscogsMatchQuality] = [:]
    /// Items that couldn't be looked up this time (no network, MusicBrainz busy): tried again next sync.
    private(set) var lookupFailures = 0
    @ObservationIgnored private var task: Task<Void, Never>?

    init() {
        let defaults = UserDefaults.standard
        username = defaults.string(forKey: Keys.username).flatMap { DiscogsIdentity.isValidUsername($0) ? $0 : nil }
        let folder = defaults.integer(forKey: Keys.folder)
        folderID = folder > 0 ? folder : DiscogsFolder.uncategorized
        hasToken = false
        // The keychain is read only once Discogs was connected, so no one else is asked to allow access for it.
        if username != nil { hasToken = token != nil }
    }

    var isConnected: Bool { username != nil && hasToken }

    var folderName: String {
        folders.first { $0.id == folderID }?.name ?? (folderID == DiscogsFolder.uncategorized ? "Uncategorized" : "Folder \(folderID)")
    }

    private var token: String? {
        KeychainStore.app.string(for: DiscogsToken.keychainAccount).flatMap(DiscogsToken.cleaned)
    }

    // MARK: Account

    func connect(token text: String) {
        guard let token = DiscogsToken.cleaned(text) else {
            connectionError = "That doesn't look like a Discogs access token: it's 40 letters and digits."
            return
        }
        isConnecting = true
        connectionError = nil
        Task {
            defer { isConnecting = false }
            do {
                let client = DiscogsCollectionClient(token: token)
                let me = try await client.identity()
                guard KeychainStore.app.set(token, for: DiscogsToken.keychainAccount) else {
                    connectionError = "The token couldn't be saved in your keychain."
                    return
                }
                hasToken = true
                username = me.username
                UserDefaults.standard.set(me.username, forKey: Keys.username)
                folders = (try? await client.folders(username: me.username)) ?? []
                if !folders.isEmpty, !folders.contains(where: { $0.id == folderID && $0.id > 0 }) { folderID = DiscogsFolder.uncategorized }
            } catch {
                connectionError = Self.message(error)
            }
        }
    }

    func disconnect() {
        cancel()
        KeychainStore.app.remove(DiscogsToken.keychainAccount)
        UserDefaults.standard.removeObject(forKey: Keys.username)
        hasToken = false
        username = nil
        folders = []
        plan = nil
        phase = .idle
    }

    /// The account's folders, for Settings.
    func loadFolders() {
        guard folders.isEmpty, let token, let username else { return }
        Task {
            folders = (try? await DiscogsCollectionClient(token: token).folders(username: username)) ?? []
        }
    }

    // MARK: Syncing

    /// Matches the CDs and records to releases (saving each match), reads the Discogs collection and makes the plan.
    func prepare(model: AppModel) {
        guard isConnected, let token, let username, let db = model.database else { return }
        cancel()
        let items = model.collection.items
        let musicBrainz = model.musicBrainz
        plan = nil
        lookupFailures = 0
        phase = .preparing("Reading your collection…", nil)
        task = Task {
            do {
                let client = DiscogsCollectionClient(token: token)
                let rows = try db.discogsSyncRows()
                var releases: [String: Int] = [:]
                var qualities: [String: DiscogsMatchQuality] = [:]
                var due: [CollectionItem] = []
                for item in items where DiscogsReleaseMatcher.isSynced(item) {
                    switch DiscogsReleaseMatcher.known(item, row: rows[item.id]) {
                    case .release(let id, let quality):
                        releases[item.id] = id
                        qualities[item.id] = quality
                    case .noMatch: break
                    case .none: if DiscogsReleaseMatcher.canLookUp(item) { due.append(item) }
                    }
                }
                let lookup = DiscogsReleaseLookup(
                    musicBrainz: { try await musicBrainz.editionFacts(releaseId: $0, releaseGroupId: $1) },
                    barcode: { try await client.searchBarcode($0, medium: $1) },
                    versions: { try await client.versions(masterID: $0, medium: $1) },
                    search: { try await client.search($0, medium: $1) })
                var failures = 0
                for (i, item) in due.enumerated() {
                    try Task.checkCancellation()
                    let name = item.album.isEmpty ? item.artist : item.album
                    phase = .preparing("Finding \(i + 1) of \(due.count) on Discogs: \(name)", Double(i) / Double(due.count))
                    do {
                        let match = try await lookup.match(for: item)
                        if let match {
                            releases[item.id] = match.releaseID
                            qualities[item.id] = match.quality
                        }
                        try db.saveDiscogsMatches([DiscogsSyncRow(itemID: item.id, basis: DiscogsReleaseMatcher.basis(of: item),
                                                                  releaseID: match?.releaseID, checkedAt: Date(), quality: match?.quality)])
                    } catch DiscogsError.unauthorized {
                        throw DiscogsError.unauthorized
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        failures += 1
                    }
                }
                phase = .preparing("Reading your collection on Discogs…", nil)
                if let found = try? await client.folders(username: username), !found.isEmpty {
                    folders = found
                    if !found.contains(where: { $0.id == folderID }) { folderID = DiscogsFolder.uncategorized }
                }
                let remote = try await client.collection(username: username) { read, pages in
                    Task { @MainActor [weak self] in
                        guard let self, case .preparing = self.phase else { return }
                        self.phase = .preparing("Reading your collection on Discogs (page \(read) of \(pages))…", Double(read) / Double(pages))
                    }
                }
                try Task.checkCancellation()
                let links = rows.compactMapValues { $0.link(for: username) }
                let plan = DiscogsSyncPlan.make(items: items, releases: releases, links: links, remote: remote)
                self.plan = plan
                self.qualities = qualities
                chosenAdditions = Set(plan.additions.map(\.id))
                chosenRemovals = []
                lookupFailures = failures
                phase = .ready
            } catch is CancellationError {
                phase = .idle
            } catch {
                phase = .failed(Self.message(error))
            }
        }
    }

    /// Makes the picked changes.
    func sync(model: AppModel) {
        guard let plan, let token, let username, let db = model.database else { return }
        let additions = plan.additions.filter { chosenAdditions.contains($0.id) }
        let removals = plan.removals.filter { chosenRemovals.contains($0.id) }
        let folder = folderID
        phase = .syncing(done: 0, of: additions.count + removals.count)
        task = Task {
            do {
                let outcome = try await DiscogsSync.run(
                    plan, additions: additions, removals: removals, client: DiscogsCollectionClient(token: token),
                    username: username, folderID: folder, database: db
                ) { done, total in
                    Task { @MainActor [weak self] in
                        guard let self, case .syncing = self.phase else { return }
                        self.phase = .syncing(done: done, of: total)
                    }
                }
                self.plan = nil
                phase = .finished(outcome)
            } catch {
                phase = .failed(Self.message(error))
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    /// The sheet closed: nothing is kept for next time.
    func reset() {
        if case .syncing = phase { return }
        cancel()
        plan = nil
        phase = .idle
    }

    static func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
