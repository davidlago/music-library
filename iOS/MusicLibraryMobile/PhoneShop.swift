import Foundation
import MusicLibraryCore
import MusicLibraryUI
import Observation
import SwiftUI

/// The Shop on the phone, for record stores and fairs: look an album up (typed, or a barcode scanned) and see its
/// price guide (Discogs and eBay, `PriceGuides`), whether you already own it, and where to buy it; with the Radio DJ
/// on, show the DJ a photo instead and it works out which record it is, prices it and says whether it's worth taking
/// home (`session`, the DJ in store mode). The Discogs account comes from the Mac at each sync (token in the
/// keychain, username in user defaults); eBay's sold listings need the opt-in eBay sign-in (`ebay`, Settings ▸ Shop).
/// Albums looked up are kept as Recent Finds (`ShopFinds.swift`): synced with the Mac like the Buy List, the DJ's
/// photos kept on the phone (`shop-find-photos.json`).
@Observable
final class PhoneShop {
    /// A find as versions before 1.34 kept them on the phone (`shop-finds.json`), read once and moved into the synced list.
    private struct LegacyFind: Codable {
        var date = Date()
        var album: String
        var artist: String
        var format: String
        var masterID: Int?
        var releaseID: Int?
        var fairPrice: String?
        var photo: Data?
        var thumbnail: URL?
    }

    let ebay = EbaySession()
    /// Albums found on Apple Music for the Shop's track lists, by artist, title and barcode (nil: not there).
    @ObservationIgnored var appleAlbums: [String: AppleAlbum?] = [:]
    @ObservationIgnored let loader = CDShopPageLoader()
    private(set) var discogsUsername: String?
    private(set) var hasDiscogsToken: Bool
    /// Recent Finds, newest first: the copy's (`LibrarySnapshot.shopFinds`) with this phone's since merged in.
    private(set) var finds: [ShopFind] = []
    /// The photos shown to the DJ, by find (small JPEGs; they stay on this phone).
    private(set) var photos: [String: Data] = [:]
    @ObservationIgnored let findsOutbox = ShopFindOutbox(url: URL.applicationSupportDirectory.appendingPathComponent("shop-finds-outbox.json"))
    @ObservationIgnored let sampleFindsOutbox = ShopFindOutbox(url: URL.applicationSupportDirectory.appendingPathComponent("sample-shop-finds.json"))
    @ObservationIgnored private var baseFinds: [ShopFind] = []
    @ObservationIgnored private var isSample = false
    /// Something for the Mac changed (sent through iCloud a few seconds later).
    @ObservationIgnored var onChange: () -> Void = {}
    /// Each guide read (the Buy List keeps it as the album's latest price when it's on the list).
    @ObservationIgnored var onGuide: (PriceGuide) -> Void = { _ in }
    /// The DJ out crate digging with you (nil: not on).
    private(set) var session: RadioDJSession?

    @ObservationIgnored private var cached: (key: String, guides: PriceGuides)?
    @ObservationIgnored private let legacyFindsURL = URL.applicationSupportDirectory.appendingPathComponent("shop-finds.json")
    @ObservationIgnored private let photosURL = URL.applicationSupportDirectory.appendingPathComponent("shop-find-photos.json")
    private static let usernameKey = "discogsUsername"

    init() {
        let username = UserDefaults.standard.string(forKey: Self.usernameKey).flatMap { DiscogsIdentity.isValidUsername($0) ? $0 : nil }
        discogsUsername = username
        // The keychain is read only once Discogs was connected.
        hasDiscogsToken = username != nil && KeychainStore.app.string(for: DiscogsToken.keychainAccount).flatMap(DiscogsToken.cleaned) != nil
        if let data = try? Data(contentsOf: photosURL), let saved = try? JSONDecoder().decode([String: Data].self, from: data) {
            photos = saved
        }
        migrateLegacyFinds()
        rebuildFinds()
    }

    var hasDiscogs: Bool { hasDiscogsToken && discogsUsername != nil }

    /// The price guides (rebuilt when the Discogs account changes).
    func guides() -> PriceGuides {
        let token = hasDiscogs ? KeychainStore.app.string(for: DiscogsToken.keychainAccount) : nil
        let key = "\(token ?? "")|\(discogsUsername ?? "")"
        if let cached, cached.key == key { return cached.guides }
        let made = PriceGuides(token: token, username: discogsUsername, currency: currencyCode, ebay: loader.ebayReader(ebay))
        Task { await made.prefetchCollection() }
        cached = (key, made)
        return made
    }

    /// The Mac's Discogs account (nil: not connected there, which disconnects it here too).
    func adoptDiscogs(token: String?, username: String?) {
        if let token, let username {
            if KeychainStore.app.string(for: DiscogsToken.keychainAccount) != token {
                guard KeychainStore.app.set(token, for: DiscogsToken.keychainAccount) else { return }
            }
            discogsUsername = username
            hasDiscogsToken = true
            UserDefaults.standard.set(username, forKey: Self.usernameKey)
        } else if hasDiscogsToken || discogsUsername != nil {
            KeychainStore.app.remove(DiscogsToken.keychainAccount)
            UserDefaults.standard.removeObject(forKey: Self.usernameKey)
            discogsUsername = nil
            hasDiscogsToken = false
        }
    }

    // MARK: The DJ in the store

    /// Puts the DJ on in store mode (once; `restart` starts a new conversation).
    func startSession(dj: PhoneRadioDJ, library: RadioDJLibrary?, linker: RadioDJLinker?, restart: Bool = false) {
        if session != nil, !restart { return }
        session?.stop()
        let made = dj.makeSession(RadioDJShopping.storeSubject, library: library, linker: linker,
                                  shopping: RadioDJShopping(guides: guides(), inStore: true))
        made.onPriceGuide = { [weak self] guide, photo in self?.record(guide, photo: photo) }
        session = made
        made.start()
    }

    func endSession() {
        session?.stop()
        session = nil
    }

    // MARK: Finds

    /// The finds the Mac hasn't got yet (none from the sample library).
    var pendingFinds: [ShopFind] { isSample ? [] : findsOutbox.changes }

    private var activeFindsOutbox: ShopFindOutbox { isSample ? sampleFindsOutbox : findsOutbox }

    /// A new copy: its finds, and the outbox without what the copy has.
    func update(library: LibrarySnapshot?, isSample: Bool) {
        self.isSample = isSample
        baseFinds = library?.shopFinds ?? []
        if !isSample { findsOutbox.remove(SyncedRecords.applied(findsOutbox.changes, in: baseFinds)) }
        rebuildFinds()
    }

    func forgetSample() { sampleFindsOutbox.removeAll() }

    private func rebuildFinds() {
        finds = ShopFind.shown(SyncedRecords.overlay(baseFinds, activeFindsOutbox.changes))
    }

    func record(_ guide: PriceGuide, photo: RadioDJPhoto? = nil) {
        guard let find = ShopFind(guide: guide) else { return }
        onGuide(guide)
        activeFindsOutbox.put(find)
        if let thumb = photo?.thumbnail {
            photos[find.id] = thumb
            savePhotos()
        }
        rebuildFinds()
        if !isSample { onChange() }
    }

    func remove(_ ids: Set<String>) {
        for find in finds where ids.contains(find.id) { activeFindsOutbox.put(find.removing()) }
        photos = photos.filter { !ids.contains($0.key) }
        savePhotos()
        rebuildFinds()
        if !isSample { onChange() }
    }

    /// Finds kept on the phone by versions before 1.34 join the synced list (so the Mac gets them), once.
    private func migrateLegacyFinds() {
        guard let data = try? Data(contentsOf: legacyFindsURL) else { return }
        if let old = try? JSONDecoder().decode([LegacyFind].self, from: data) {
            for f in old {
                var find = ShopFind(album: f.album, artist: f.artist, format: PriceGuideRequest.Format(rawValue: f.format) ?? .any,
                                    masterID: f.masterID, releaseID: f.releaseID, fairPrice: f.fairPrice, thumbnail: f.thumbnail, at: f.date)
                find = find.sanitized() ?? find
                findsOutbox.put(find)
                if let photo = f.photo { photos[find.id] = photo }
            }
            savePhotos()
        }
        try? FileManager.default.removeItem(at: legacyFindsURL)
    }

    private func savePhotos() {
        let photos = photos, url = photosURL
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(photos).write(to: url, options: .atomic)
        }
    }
}

// MARK: Settings

/// Settings ▸ Shop: the Discogs account the Mac handed over, and the opt-in eBay sign-in for recent sales.
struct ShopSettingsSection: View {
    let shop: PhoneShop
    @State private var signingIn = false

    var body: some View {
        Section {
            LabeledContent("Discogs", value: shop.discogsUsername.map { shop.hasDiscogs ? $0 : "Not connected" } ?? "Not connected")
            if shop.ebay.isSignedIn {
                LabeledContent("eBay") {
                    Button("Sign Out") { Task { await shop.ebay.signOut() } }
                }
            } else {
                Button(shop.ebay.expired ? "Sign In to eBay Again…" : "Sign In to eBay…") { signingIn = true }
            }
        } header: {
            Text("Shop")
        } footer: {
            Text("The price guide uses Discogs and eBay. Connect Discogs on your Mac (Settings ▸ Discogs) and sync to add its suggested prices by condition and the versions in your Discogs collection. eBay shows sold listings only when you're signed in: you sign in on eBay's own page, and Music Library keeps only eBay's cookies, never your password.")
        }
        .sheet(isPresented: $signingIn) {
            EbaySignInView(session: shop.ebay) { signingIn = false }
        }
    }
}
