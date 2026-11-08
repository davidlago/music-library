import MusicLibraryCore
import MusicLibraryUI
import SwiftUI
import VisionKit

/// A page of the Shop: one album's price guide.
struct ShopAlbumRoute: Hashable {
    var request: PriceGuideRequest
}

/// The Radio DJ out crate digging (`camera`: open the camera straight away).
struct ShopDJRoute: Hashable {
    var camera = false
}

/// The Shop tab, for record stores and fairs: look a record or CD up by name or barcode (or, with the Radio DJ on,
/// show the DJ a photo of it) and see what it's worth, whether you have it and where to buy it.
struct ShopTab: View {
    @State private var showSettings = false

    var body: some View {
        LibraryStack {
            ShopHome()
                .navigationTitle("Shop")
                .radioDJPage(.page("the Shop, where they look up what a record or CD is worth, whether they own it and where to buy it"))
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Settings", systemImage: "gearshape") { showSettings = true }
                    }
                }
                .navigationDestination(for: ShopDJRoute.self) { ShopDJPage(route: $0) }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
    }
}

private struct ShopHome: View {
    @Environment(PhoneModel.self) private var model
    @Environment(\.openRoute) private var openRoute
    @AppStorage("shopFormat") private var format = PriceGuideRequest.Format.vinyl
    @State private var text = ""
    @State private var hits: [DiscogsMarketParser.Hit] = []
    @State private var searchedFor: String?
    @State private var searching = false
    @State private var error: String?
    @State private var scanning = false
    @State private var search: Task<Void, Never>?
    @FocusState private var typing: Bool

    var body: some View {
        let shop = model.shop
        List {
            if model.radioDJ.isEnabled { djSection }
            Section {
                TextField("Artist and album, or a barcode", text: $text)
                    .focused($typing)
                    .submitLabel(.search)
                    .onSubmit { run(text) }
                    .autocorrectionDisabled()
                Picker("Format", selection: $format) {
                    ForEach(PriceGuideRequest.Format.allCases, id: \.self) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
                HStack {
                    Button("Search", systemImage: "magnifyingglass") { run(text) }
                        .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || searching)
                    Spacer()
                    if BarcodeScanner.isSupported {
                        Button("Scan Barcode", systemImage: "barcode.viewfinder") { scanning = true }
                    }
                }
                .buttonStyle(.borderless)
            } header: {
                Text("Look It Up")
            } footer: {
                Text("Searches Discogs. Each album shows its price guide (Discogs and eBay), whether it's in your collection and where to buy it.")
            }
            if searching {
                HStack { ProgressView(); Text("Searching Discogs…").foregroundStyle(.secondary) }
            } else if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            } else if let searchedFor {
                Section(hits.isEmpty ? "Nothing Found" : "Results") {
                    if hits.isEmpty {
                        Text("Discogs has nothing for “\(searchedFor)”\(format == .any ? "" : " on \(format.name)"). Try fewer words, or another format.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(hits) { hit in
                        NavigationLink(value: ShopAlbumRoute(request: request(for: hit, code: searchedFor))) { HitRow(hit: hit) }
                    }
                }
            }
            Section {
                NavigationLink(value: BuyListRoute.list) {
                    let market = model.market
                    let totals = BuyList.totals(market.shown)
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Buy List")
                            Text(market.shown.isEmpty ? "Albums you're looking for, with what they go for"
                                 : "\(totals.count) album\(totals.count == 1 ? "" : "s")\(totals.deals > 0 ? " · \(totals.deals) at or under your max" : "")")
                                .font(.caption).foregroundStyle(totals.deals > 0 ? .green : .secondary)
                        }
                    } icon: { Image(systemName: "bag") }
                }
            }
            if !shop.finds.isEmpty {
                Section {
                    ForEach(shop.finds) { find in
                        NavigationLink(value: ShopAlbumRoute(request: find.request)) { FindRow(find: find) }
                    }
                    .onDelete { offsets in shop.remove(Set(offsets.map { shop.finds[$0].id })) }
                } header: {
                    Text("Recent Finds")
                } footer: {
                    Text("Albums priced here or in the Shop on your Mac; they sync with it.")
                }
            }
        }
        .sheet(isPresented: $scanning) {
            BarcodeScannerSheet { code in
                scanning = false
                text = code
                run(code, opening: true)
            }
        }
    }

    /// The DJ's way in: a photo of what you're holding.
    private var djSection: some View {
        let dj = model.radioDJ
        return Section {
            NavigationLink(value: ShopDJRoute(camera: dj.model.acceptsImages)) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(dj.model.acceptsImages ? "Show \(dj.name) a Record" : "Ask \(dj.name) About a Record").font(.headline)
                        Text(dj.model.acceptsImages ? "Snap the cover (or the back) and hear what it is, what it's worth and whether it belongs on your shelf."
                             : "Type what the cover says and hear what it is, what it's worth and whether it belongs on your shelf.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: dj.model.acceptsImages ? "camera.viewfinder" : RadioDJIcon.name).font(.title2)
                }
            }
            if model.shop.session?.lines.contains(where: { $0.role == .listener }) == true {
                NavigationLink(value: ShopDJRoute()) {
                    Label("Back to Crate Digging with \(dj.name)", systemImage: RadioDJIcon.name(filled: true))
                }
            }
        }
    }

    private func run(_ query: String, opening: Bool = false) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        typing = false
        search?.cancel()
        searching = true
        error = nil
        let guides = model.shop.guides()
        let format = format
        search = Task {
            defer { searching = false }
            do {
                let found = try await guides.search(query, format: format)
                guard !Task.isCancelled else { return }
                hits = found
                searchedFor = query
                // A scanned barcode that names one album opens it.
                if opening, let only = found.first, Set(found.map { $0.masterID ?? -($0.releaseID ?? 0) }).count == 1 {
                    openRoute(ShopAlbumRoute(request: request(for: only, code: query)))
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
        }
    }

    /// What to price for a result: the release found by its barcode, else the album in the format chosen.
    private func request(for hit: DiscogsMarketParser.Hit, code: String) -> PriceGuideRequest {
        let isBarcode = code.allSatisfy { $0.isNumber || $0 == " " || $0 == "-" }
        let medium = CollectionMedium(musicBrainzFormats: hit.formats)
        let hitFormat: PriceGuideRequest.Format = medium == .vinyl ? .vinyl : medium == .cd ? .cd : format
        return PriceGuideRequest(artist: hit.artist, album: hit.title, format: isBarcode ? hitFormat : format,
                                 barcode: isBarcode ? code : "", releaseID: isBarcode ? hit.releaseID : nil, masterID: hit.masterID)
    }
}

private struct HitRow: View {
    let hit: DiscogsMarketParser.Hit

    var body: some View {
        HStack(spacing: 12) {
            DiscogsThumb(url: hit.thumbnail, side: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(hit.title).font(.body).lineLimit(2)
                Text(hit.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                Text([hit.year.map(String.init) ?? "", hit.label, hit.formats.prefix(3).joined(separator: ", ")]
                        .filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

private struct FindRow: View {
    @Environment(PhoneModel.self) private var model
    let find: ShopFind

    var body: some View {
        HStack(spacing: 12) {
            if let data = model.shop.photos[find.id], let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill().frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                DiscogsThumb(url: find.thumbnail, side: 44)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(find.album).lineLimit(1)
                Text(find.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                Text([find.format.name, find.at.formatted(date: .abbreviated, time: .omitted)]
                        .filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let price = find.fairPrice { Text(price).font(.callout).monospacedDigit().foregroundStyle(.secondary) }
        }
    }
}

private struct DiscogsThumb: View {
    let url: URL?
    let side: CGFloat

    var body: some View {
        Group {
            if let url, DiscogsLink.isImageURL(url) {
                AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: { AppColor.fill }
            } else {
                ZStack { AppColor.fill; Image(systemName: "opticaldisc").foregroundStyle(.secondary) }
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: Album

/// One album in the Shop: what you have of it, its price guide and the stores' searches for it, and the DJ's take.
struct ShopAlbumPage: View {
    @Environment(PhoneModel.self) private var model
    @Environment(\.openRoute) private var openRoute
    let route: ShopAlbumRoute
    @State private var format: PriceGuideRequest.Format
    @State private var guide: PriceGuide?
    @State private var loading = false
    @State private var ownership = ShopOwnership()
    @State private var apple: AppleAlbum?
    @State private var findingApple = true
    @Environment(PhonePlayer.self) private var player

    init(route: ShopAlbumRoute) {
        self.route = route
        _format = State(initialValue: route.request.format)
    }

    private var request: PriceGuideRequest {
        var r = route.request
        if r.format != format {
            // Another format is another set of editions.
            r = PriceGuideRequest(artist: r.artist, album: r.album, format: format, masterID: r.masterID)
        }
        return r
    }

    private var title: String { guide.flatMap { $0.title.isEmpty ? nil : $0.title } ?? route.request.album }
    private var artist: String { guide.flatMap { $0.artist.isEmpty ? nil : $0.artist } ?? route.request.artist }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.title2.bold())
                    if !artist.isEmpty { Text(artist).font(.title3).foregroundStyle(.secondary) }
                }
                Picker("Format", selection: $format) {
                    ForEach(PriceGuideRequest.Format.allCases, id: \.self) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "Your Collection")
                    ShopOwnershipView(ownership: ownership,
                                      openItem: { openRoute(CollectionItemRoute(id: $0.id)) },
                                      openAlbum: { album in
                                          if let found = model.library?.album(forKey: SearchIndex.albumKey(album: album.album, artist: album.artist)) {
                                              openRoute(found)
                                          }
                                      })
                    if let guide { AddToBuyListButton(guide: guide).padding(.top, 4) }
                    if let owned = guide?.ownedOnDiscogs, !owned.isEmpty {
                        Label("\(owned.count) cop\(owned.count == 1 ? "y" : "ies") in your Discogs collection\(owned.contains(where: \.sameEdition) ? ", this edition among them" : "")",
                              systemImage: "checkmark.seal")
                            .font(.subheadline).foregroundStyle(.green)
                    }
                }
                if model.radioDJ.isEnabled {
                    Button { askDJ() } label: {
                        Label("Ask \(model.radioDJ.name) About It", systemImage: RadioDJIcon.name).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(model.shop.session?.isBusy == true)
                }
                if loading {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Checking Discogs\(model.shop.ebay.isSignedIn ? " and eBay's sales" : " and eBay")…").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 20)
                } else if let guide {
                    PriceGuideView(guide: guide, lead: .shop(usShipping: nil))
                }
                AppleAlbumTracks(album: apple, loading: findingApple, controls: model.previewControls(player: player))
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "Find a Copy")
                    ShopStoreLinks(target: guide?.shoppingTarget ?? CDShoppingTarget(byName: CDSearchQuery(album: title, artist: artist, format: format.shopFormat)))
                }
            }
            .padding(16)
        }
        .navigationBarTitleDisplayMode(.inline)
        .radioDJPage(.page("the Shop, looking at *\(route.request.album)* by \(route.request.artist)",
                           details: guide.map { [$0.summary] } ?? []))
        .task(id: format) { await load() }
        .task { await findOnApple() }
    }

    private func load() async {
        loading = true
        let request = request
        let collection = model.collection
        let tracks = model.library?.tracks ?? []
        ownership = await Task.detached(priority: .userInitiated) {
            ShopOwnership.find(album: request.album, artist: request.artist, collection: collection, tracks: tracks)
        }.value
        let found = await model.shop.guides().fullGuide(for: request)
        guard !Task.isCancelled else { return }
        guide = found
        loading = false
        model.shop.record(found)
    }

    /// The album's songs on Apple Music (once per album), for the track list and its previews.
    private func findOnApple() async {
        let r = route.request
        let key = "\(r.artist)|\(r.album)|\(r.barcode)".lowercased()
        if let cached = model.shop.appleAlbums[key] { apple = cached; findingApple = false; return }
        let finder = ApplePreviewFinder(client: model.radioDJ.previewClient)
        let found = try? await finder.album(title: r.album, artist: r.artist, barcodes: r.barcode.isEmpty ? [] : [r.barcode], year: r.year)
        guard !Task.isCancelled else { return }
        if let found { model.shop.appleAlbums[key] = .some(found) } else { model.shop.appleAlbums[key] = .some(nil) }
        apple = found ?? nil
        findingApple = false
    }

    private func askDJ() {
        model.startShopDJ()
        let format = format == .any ? "" : " on \(format.name)"
        model.shop.session?.send("I'm looking at *\(title)* by \(artist)\(format). What is it, is it worth adding to my collection, and what's a fair price?")
        openRoute(ShopDJRoute())
    }
}

// MARK: The DJ

/// The Radio DJ out crate digging with you: photos of what you're holding, the albums it can't tell apart to pick
/// from, its take and the price guide.
private struct ShopDJPage: View {
    @Environment(PhoneModel.self) private var model
    @Environment(PhonePlayer.self) private var player
    let route: ShopDJRoute

    var body: some View {
        Group {
            if let session = model.shop.session {
                RadioDJConversation(session: session, dj: model.radioDJ, open: { model.openRadioDJ($0, player: player) },
                                    autoCamera: route.camera)
                    .id(ObjectIdentifier(session))
            } else {
                ContentUnavailableView("\(model.radioDJ.name) Is Off the Air", systemImage: RadioDJIcon.name,
                                       description: Text("The Radio DJ is on once your Mac hands over an API key when you sync."))
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 8) {
                    OnAirSign(live: model.shop.session?.isBusy == true)
                    Text(model.radioDJ.name).font(.headline).lineLimit(1)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("New Dig", systemImage: "plus") { model.startShopDJ(restart: true) }
                    .disabled(model.shop.session?.lines.contains(where: { $0.role == .listener }) != true)
            }
        }
        .onAppear { model.startShopDJ() }
    }
}

extension PhoneModel {
    /// The DJ in the Shop's store mode, with the collection to search and link to (`restart`: a new conversation).
    func startShopDJ(restart: Bool = false) {
        guard radioDJ.isEnabled else { return }
        shop.startSession(dj: radioDJ, library: radioDJLibrary, linker: radioDJLinker(RadioDJShopping.storeSubject), restart: restart)
    }
}

// MARK: Barcodes

/// The camera, reading the first barcode it sees (UPC/EAN, as on CDs and records).
private struct BarcodeScannerSheet: View {
    let onCode: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if BarcodeScanner.isAvailable {
                    BarcodeScanner(onCode: onCode).ignoresSafeArea()
                } else {
                    ContentUnavailableView("Camera Not Available", systemImage: "barcode.viewfinder",
                                           description: Text("Allow Music Library to use the camera in Settings ▸ Privacy & Security ▸ Camera, or type the barcode's digits."))
                }
            }
            .navigationTitle("Scan a Barcode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}

struct BarcodeScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    static var isSupported: Bool { DataScannerViewController.isSupported }
    static var isAvailable: Bool { DataScannerViewController.isSupported && DataScannerViewController.isAvailable }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.ean13, .ean8, .upce, .code128])],
                                                qualityLevel: .balanced, recognizesMultipleItems: false,
                                                isHighFrameRateTrackingEnabled: false, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        if !scanner.isScanning { try? scanner.startScanning() }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        private var done = false
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !done else { return }
            for case .barcode(let code) in addedItems {
                let digits = (code.payloadStringValue ?? "").filter { ("0"..."9").contains($0) }
                guard (8...14).contains(digits.count) else { continue }
                done = true
                dataScanner.stopScanning()
                onCode(digits)
                return
            }
        }
    }
}
