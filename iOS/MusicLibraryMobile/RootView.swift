import MusicLibraryCore
import SwiftUI

struct RootView: View {
    enum Tabs: Hashable { case library, insights, sync, search }

    @Environment(PhoneModel.self) private var model
    @Environment(PhonePlayer.self) private var player
    @Environment(\.scenePhase) private var scenePhase
    @State private var showNowPlaying = false
    @State private var tab = Tabs.library

    var body: some View {
        TabView(selection: $tab) {
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
    }
}

/// What the Library and Search tabs show until the library has loaded.
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
                Text("The library on this iPhone is empty. Add music on the Mac, then sync.")
            } actions: {
                Button("Check Again") { model.reload() }
            }
        }
    }
}
