import MusicLibraryCore
import MusicLibraryGlance
import SwiftUI

struct RootView: View {
    /// Raw values are stored (`selectedTab`). `insights` is the Explore tab; versions before 1.28 also had
    /// `library` (Digital) and `sync`, which no longer decode, so those choices start over on Listen Now.
    enum Tabs: String, Hashable { case listenNow, collection, insights, search }

    @Environment(PhoneModel.self) private var model
    @Environment(PhonePlayer.self) private var player
    @Environment(\.scenePhase) private var scenePhase
    @State private var showNowPlaying = false
    /// The tab last chosen, kept when the app is swiped away (scene storage isn't); Listen Now until one is.
    @AppStorage("selectedTab") private var chosenTab: Tabs?
    @AppStorage("insightsPane") private var insightsPane = InsightsPane.owned

    private var tab: Tabs {
        get { chosenTab ?? .listenNow }
        nonmutating set { chosenTab = newValue }
    }

    var body: some View {
        TabView(selection: Binding(get: { tab }, set: { tab = $0 })) {
            Tab("Listen Now", systemImage: "play.circle", value: .listenNow) {
                ListenNowTab()
            }
            Tab("Collection", systemImage: "books.vertical", value: .collection) {
                CollectionTab()
            }
            Tab("Explore", systemImage: "sparkles", value: .insights) {
                InsightsTab()
            }
            Tab(value: .search, role: .search) {
                SearchTab()
            }
        }
        // The phone listens for the Mac only while the Sync screen is open.
        .onChange(of: model.showsSync && scenePhase == .active, initial: true) { _, visible in
            model.sync.setVisible(visible)
        }
        .sheet(isPresented: Binding(get: { model.showsSync }, set: { model.showsSync = $0 })) {
            SyncTab()
        }
        .tabViewBottomAccessory {
            MiniPlayer { showNowPlaying = true }
        }
        .sheet(isPresented: $showNowPlaying) {
            NowPlayingView()
        }
        .sheet(item: Binding(get: { model.infoTrack }, set: { model.infoTrack = $0 })) { track in
            SongInfoSheet(track: track)
        }
        .radioDJSheet(model, player: player)
        .onOpenURL { url in GlanceLink(url: url).map(open) }
        // Siri and Shortcuts (`OpenCollectionItemIntent`), possibly before this view existed.
        .onChange(of: model.pendingLink, initial: true) { _, link in
            guard let link else { return }
            model.pendingLink = nil
            open(link)
        }
    }

    /// A widget was tapped: `musiclibrary://` links (`GlanceLink`).
    private func open(_ link: GlanceLink) {
        model.infoTrack = nil
        if link != .nowPlaying { showNowPlaying = false }
        switch link {
        case .nowPlaying:
            showNowPlaying = player.currentTrack != nil
        case .library:
            tab = .collection
        case .insights(let pane):
            insightsPane = switch pane {
            case .library: .library
            case .listening: .listening
            case .owned: .owned
            }
            tab = .insights
        case .album(let key):
            if let id = link.itemID {
                model.pendingItemID = id
                tab = .collection
            } else {
                model.pendingAlbumKey = key
                tab = .collection
            }
        }
    }
}

/// What Listen Now, the Collection tab and Search show until the library has loaded.
struct LibraryStatusView: View {
    @Environment(PhoneModel.self) private var model

    var body: some View {
        switch model.state {
        case .loading:
            ProgressView("Loading Your Music…")
        case .missing where model.cloud.isUsable && (model.cloud.status == .checking || model.cloud.arriving != nil):
            // A new iPhone gets the library from iCloud without the Mac (D22): say so while the first check runs.
            ContentUnavailableView {
                Label("Looking for Your Library in iCloud…", systemImage: "icloud.and.arrow.down")
            } description: {
                if let arriving = model.cloud.arriving {
                    VStack(spacing: 8) {
                        Text("Your library is on its way from \(model.cloud.macName ?? "your Mac")'s iCloud backup: covers and artist photos first, then the library.")
                        ProgressView(value: Double(arriving.done), total: Double(max(1, arriving.total)))
                        Text("\(arriving.done) of \(arriving.total) covers and photos").font(.caption).monospacedDigit()
                    }
                } else {
                    Text("If your Mac backs up to iCloud, your library comes from there, without pairing.")
                }
            } actions: {
                ProgressView()
            }
        case .missing:
            ContentUnavailableView {
                Label("No Music Library Yet", systemImage: "music.note.house")
            } description: {
                Text("""
                Pair with Music Library on your Mac (Sync, at the top of Listen Now) and sync: your digital and physical collections show \
                up here, and you choose what to download. Or export from the Mac to a folder named “\(LibraryLocation.phoneFolderName)” \
                with the database backup on, and drag it onto Music Library in the Finder's Files tab for this iPhone.
                """)
            } actions: {
                Button("Sync with Your Mac") { model.showsSync = true }
                    .buttonStyle(.borderedProminent)
                Button("Check Again") { model.reload() }
                if PhoneModel.sampleRoot != nil {
                    Button("Explore a Sample Library") { model.showSample() }
                }
            }
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't Open the Music Library", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { model.reload() }
            }
        case .loaded:
            ContentUnavailableView {
                Label("No Music Yet", systemImage: "music.note")
            } description: {
                Text("Your digital and physical collections are empty on this iPhone. Add music or your CDs and records on the Mac, then sync.")
            } actions: {
                Button("Check Again") { model.reload() }
            }
        }
    }
}
