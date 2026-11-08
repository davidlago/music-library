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
/// Albums looked up are kept as recent finds (Application Support `shop-finds.json`, the last 60).
@Observable
final class PhoneShop {
    /// One album looked up in the Shop.
    struct Find: Codable, Hashable, Identifiable {
        var id = UUID()
        var date = Date()
        var album: String
        var artist: String
        var format: String
        var masterID: Int?
        var releaseID: Int?
        /// "$18–$32".
        var fairPrice: String?
        /// The photo shown to the DJ, small (nil: looked up by name).
        var photo: Data?
        var thumbnail: URL?

        var request: PriceGuideRequest {
            PriceGuideRequest(artist: artist, album: album, format: PriceGuideRequest.Format(rawValue: format) ?? .any,
                              releaseID: releaseID, masterID: masterID)
        }
    }

    let ebay = EbaySession()
    @ObservationIgnored let loader = CDShopPageLoader()
    private(set) var discogsUsername: String?
    private(set) var hasDiscogsToken: Bool
    private(set) var finds: [Find] = []
    /// The DJ out crate digging with you (nil: not on).
    private(set) var session: RadioDJSession?

    @ObservationIgnored private var cached: (key: String, guides: PriceGuides)?
    @ObservationIgnored private let findsURL = URL.applicationSupportDirectory.appendingPathComponent("shop-finds.json")
    private static let usernameKey = "discogsUsername"
    static let maxFinds = 60

    init() {
        let username = UserDefaults.standard.string(forKey: Self.usernameKey).flatMap { DiscogsIdentity.isValidUsername($0) ? $0 : nil }
        discogsUsername = username
        // The keychain is read only once Discogs was connected.
        hasDiscogsToken = username != nil && KeychainStore.app.string(for: DiscogsToken.keychainAccount).flatMap(DiscogsToken.cleaned) != nil
        if let data = try? Data(contentsOf: findsURL), let saved = try? JSONDecoder().decode([Find].self, from: data) {
            finds = Array(saved.prefix(Self.maxFinds))
        }
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

    func record(_ guide: PriceGuide, photo: RadioDJPhoto? = nil) {
        guard guide.hasPrices else { return }
        let album = guide.title.isEmpty ? guide.request.album : guide.title
        let artist = guide.artist.isEmpty ? guide.request.artist : guide.artist
        var find = Find(album: album, artist: artist, format: guide.request.format.rawValue, masterID: guide.masterID,
                        releaseID: guide.editions.first { $0.roles.contains(.identified) }?.releaseID,
                        fairPrice: guide.fairPrice?.text, photo: photo?.thumbnail, thumbnail: guide.thumbnail)
        // The same album again moves up (keeping a photo it had).
        if let old = finds.firstIndex(where: { $0.album == find.album && $0.artist == find.artist && $0.format == find.format }) {
            if find.photo == nil { find.photo = finds[old].photo }
            finds.remove(at: old)
        }
        finds.insert(find, at: 0)
        finds = Array(finds.prefix(Self.maxFinds))
        save()
    }

    func remove(_ ids: Set<UUID>) {
        finds.removeAll { ids.contains($0.id) }
        save()
    }

    private func save() {
        let finds = finds, url = findsURL
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(finds).write(to: url, options: .atomic)
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
