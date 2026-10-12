import Foundation
import MusicLibraryCore
import Network
import Observation
import UIKit

/// The phone's end of Wi-Fi sync. While the Sync tab is on screen (iOS suspends the app in the background), the
/// phone advertises itself on the local network: with a pairing code until it's paired, then with the key the Mac
/// handed over. The Mac starts each sync; files go into the library folder and the library reloads afterwards.
@Observable
final class PhoneSync {
    enum Status: Equatable {
        /// Not listening (not paired, or the tab isn't open).
        case off
        /// Listening for the paired Mac.
        case waiting
        /// Showing this code, listening for the Mac to pair.
        case pairing(String)
        case syncing(SyncProgress)
    }

    private enum Keys {
        static let deviceID = "syncDeviceID"
        static let macID = "syncMacID"
        static let macName = "syncMacName"
        static let lastSync = "syncLastDate"
        static let lastSummary = "syncLastSummary"
        static let key = "syncKey"
    }

    private(set) var status: Status = .off
    /// A key from the Mac is in the keychain.
    private(set) var isPaired = false
    private(set) var macName: String?
    private(set) var lastSync: Date?
    private(set) var lastSummary: SyncSummary?
    private(set) var lastError: String?

    /// Called after a sync changed the library.
    @ObservationIgnored var onLibraryChanged: () -> Void = {}
    /// The plays and likes to send, and the library they were recorded against.
    @ObservationIgnored var pendingEvents: () -> ([SyncEvent], String?) = { ([], nil) }
    /// Called with the events a finished sync handled (the Mac applied, already had, or dropped them).
    @ObservationIgnored var onEventsDelivered: (Set<String>) -> Void = { _ in }
    @ObservationIgnored var isLastFMConnected: () -> Bool = { true }
    /// Gets the Mac's Last.fm account when this phone isn't connected.
    @ObservationIgnored var adoptLastFM: (SyncLastFM) -> Void = { _ in }
    @ObservationIgnored private var advertiser: SyncAdvertiser?
    @ObservationIgnored private var visible = false
    @ObservationIgnored private var busy = false
    @ObservationIgnored private let keychain = KeychainStore.app
    @ObservationIgnored private let identity: SyncIdentity

    init() {
        let defaults = UserDefaults.standard
        let id = defaults.string(forKey: Keys.deviceID) ?? {
            let new = UUID().uuidString
            defaults.set(new, forKey: Keys.deviceID)
            return new
        }()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        identity = SyncIdentity(deviceID: id, deviceName: UIDevice.current.name, appVersion: version)
        macName = defaults.string(forKey: Keys.macName)
        isPaired = key != nil
        lastSync = defaults.object(forKey: Keys.lastSync) as? Date
        lastSummary = defaults.data(forKey: Keys.lastSummary).flatMap { try? JSONDecoder().decode(SyncSummary.self, from: $0) }
    }

    private var key: Data? { keychain.string(for: Keys.key).flatMap { Data(base64Encoded: $0) }.flatMap { $0.count == 32 ? $0 : nil } }

    /// Where synced files go: the library the app already shows (an export dragged in under another name is
    /// kept and updated), or `Documents/Music Library`.
    private var root: URL { LibrarySnapshot.findRoot(in: URL.documentsDirectory) ?? LibraryLocation.defaultRoot }

    // MARK: Listening

    /// The Sync tab appeared or went away, or the app became active or went to the background.
    func setVisible(_ visible: Bool) {
        self.visible = visible
        if visible {
            if advertiser == nil, let key { listen(key: key, pairing: nil) }
        } else if !busy {
            stopListening()
            if case .pairing = status {} else { status = .off }
        }
    }

    func startPairing() {
        lastError = nil
        let code = SyncPairing.newCode()
        listen(key: SyncPairing.pairingKey(code: code), pairing: code)
    }

    func cancelPairing() {
        stopListening()
        status = .off
        if visible, let key { listen(key: key, pairing: nil) }
    }

    func unpair() {
        stopListening()
        keychain.remove(Keys.key)
        isPaired = false
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Keys.macID)
        defaults.removeObject(forKey: Keys.macName)
        macName = nil
        status = .off
    }

    private func listen(key: Data, pairing code: String?) {
        stopListening()
        do {
            let advertiser = try SyncAdvertiser(
                deviceID: identity.deviceID, name: identity.deviceName, key: key, pairing: code != nil,
                onState: { [weak self] state in Task { @MainActor in self?.listenerChanged(state) } },
                onConnection: { [weak self] connection in Task { @MainActor in self?.accept(connection, pairing: code != nil) } })
            advertiser.start()
            self.advertiser = advertiser
            status = code.map { .pairing($0) } ?? .waiting
        } catch {
            lastError = "Couldn't start listening for the Mac: \(error.localizedDescription)"
            status = .off
        }
    }

    private func stopListening() {
        advertiser?.stop()
        advertiser = nil
    }

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .failed(let error), .waiting(let error):
            if case .dns(let code) = error, code == -65570 /* kDNSServiceErr_PolicyDenied */ {
                lastError = "Allow Music Library to use the local network in Settings ▸ Privacy & Security ▸ Local Network, then open this tab again."
            } else {
                lastError = "Can't listen for the Mac: \(error.localizedDescription)"
            }
        default:
            break
        }
    }

    // MARK: Sessions

    private func accept(_ connection: NWConnection, pairing: Bool) {
        guard !busy else { connection.cancel(); return }
        busy = true
        lastError = nil
        if !pairing { status = .syncing(SyncProgress()) }
        UIApplication.shared.isIdleTimerDisabled = true
        // A few more seconds to finish the current file if the app is sent to the background.
        let background = UIApplication.shared.beginBackgroundTask(withName: "Sync")
        let identity = identity, root = root
        let free = (try? URL.documentsDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
        let (events, libraryID) = pairing ? ([], nil) : pendingEvents()
        let lastFMConnected = isLastFMConnected()
        Task {
            defer {
                busy = false
                UIApplication.shared.isIdleTimerDisabled = false
                UIApplication.shared.endBackgroundTask(background)
            }
            do {
                let result = try await SyncPhoneSession.run(
                    SyncConnection(connection), identity: identity, root: root, freeSpace: free, pairing: pairing,
                    events: events, libraryID: libraryID, lastFMConnected: lastFMConnected,
                    storeGrant: { grant in try await self.store(grant) },
                    adoptLastFM: { account in await self.adopt(account) },
                    progress: { progress in await self.report(progress) })
                if pairing {
                    // Later syncs use the key the Mac just handed over.
                    if visible, let key { listen(key: key, pairing: nil) } else { stopListening(); status = .off }
                } else {
                    onEventsDelivered(Set(events.map(\.id)))
                    finished(result.summary)
                }
            } catch {
                lastError = error.localizedDescription
                if !pairing {
                    status = advertiser == nil ? .off : .waiting
                    // Whatever arrived before the failure is in place; show it.
                    onLibraryChanged()
                }
            }
        }
    }

    /// Keeps the Mac's key. Throws when the keychain won't take it, so the Mac isn't told it's paired.
    private func store(_ grant: SyncGrant) throws {
        guard keychain.set(grant.key, for: Keys.key), key != nil else {
            throw SyncError.remote("The iPhone couldn't save the pairing key in its keychain.")
        }
        isPaired = true
        let defaults = UserDefaults.standard
        defaults.set(grant.macID, forKey: Keys.macID)
        defaults.set(grant.macName, forKey: Keys.macName)
        macName = grant.macName
    }

    private func adopt(_ account: SyncLastFM) {
        adoptLastFM(account)
    }

    private func report(_ progress: SyncProgress) {
        if case .syncing = status { status = .syncing(progress) }
    }

    private func finished(_ summary: SyncSummary) {
        lastSync = Date()
        lastSummary = summary
        let defaults = UserDefaults.standard
        defaults.set(lastSync, forKey: Keys.lastSync)
        defaults.set(try? JSONEncoder().encode(summary), forKey: Keys.lastSummary)
        status = advertiser == nil ? .off : .waiting
        if !visible { stopListening(); status = .off }
        onLibraryChanged()
    }
}
