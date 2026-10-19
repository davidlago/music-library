import MusicLibraryCore
import MusicLibraryGlance
import SwiftUI

struct RootView: View {
    enum Tabs: String, Hashable { case collection, library, insights, sync, search }

    @Environment(PhoneModel.self) private var model
    @Environment(PhonePlayer.self) private var player
    @Environment(\.scenePhase) private var scenePhase
    @State private var showNowPlaying = false
    /// The tab last chosen; until then, the collection when there is one, else the library.
    @SceneStorage("selectedTab") private var chosenTab: Tabs?
    @AppStorage("insightsPane") private var insightsPane = InsightsPane.owned

    private var tab: Tabs {
        get { chosenTab ?? (model.collection.items.isEmpty ? .library : .collection) }
        nonmutating set { chosenTab = newValue }
    }

    var body: some View {
        TabView(selection: Binding(get: { tab }, set: { tab = $0 })) {
            Tab("Collection", systemImage: "books.vertical", value: .collection) {
                CollectionTab()
            }
            Tab("Library", systemImage: "square.stack", value: .library) {
                LibraryTab()
            }
            Tab("Insights", systemImage: "chart.bar.xaxis", value: .insights) {
                InsightsTab()
            }
            Tab("Sync", systemImage: "arrow.triangle.2.circlepath", value: .sync) {
                SyncTab()
            }
            Tab(value: .search, role: .search) {
                SearchTab()
            }
        }
        // The phone listens for the Mac only while the Sync tab is on screen.
        .onChange(of: tab == .sync && scenePhase == .active, initial: true) { _, visible in
            model.sync.setVisible(visible)
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
            tab = .library
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
                tab = .library
            }
        }
    }
}

/// What the Collection, Library and Search tabs show until the library has loaded.
struct LibraryStatusView: View {
    @Environment(PhoneModel.self) private var model

    var body: some View {
        switch model.state {
        case .loading:
            ProgressView("Loading Library…")
        case .missing:
            ContentUnavailableView {
                Label("No Library Yet", systemImage: "music.note.house")
            } description: {
                Text("""
                Pair with Music Library on your Mac in the Sync tab and sync: your whole library shows up here, and you \
                choose what to download. Or export from the Mac to a folder named “\(LibraryLocation.phoneFolderName)” \
                with the database backup on, and drag it onto Music Library in the Finder's Files tab for this iPhone.
                """)
            } actions: {
                Button("Check Again") { model.reload() }
                if PhoneModel.sampleRoot != nil {
                    Button("Explore a Sample Library") { model.showSample() }
                        .buttonStyle(.borderedProminent)
                }
            }
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't Open the Library", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { model.reload() }
            }
        case .loaded:
            ContentUnavailableView {
                Label("No Music Yet", systemImage: "music.note")
            } description: {
                Text("The library on this iPhone is empty. Add music or your CDs and records on the Mac, then sync.")
            } actions: {
                Button("Check Again") { model.reload() }
            }
        }
    }
}
