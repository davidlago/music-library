import MusicLibraryCore
import SwiftUI

struct RootView: View {
    @Environment(PhoneModel.self) private var model
    @Environment(PhonePlayer.self) private var player
    @State private var showNowPlaying = false

    var body: some View {
        TabView {
            Tab("Library", systemImage: "square.stack") {
                LibraryTab()
            }
            Tab(role: .search) {
                SearchTab()
            }
        }
        .tabViewBottomAccessory {
            MiniPlayer { showNowPlaying = true }
        }
        .sheet(isPresented: $showNowPlaying) {
            NowPlayingView()
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
                On the Mac, export to a folder named “\(LibraryLocation.phoneFolderName)” with the database backup on. \
                Then connect the iPhone, select it in Finder, open the Files tab and drag the folder onto Music Library.
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
        case .loaded(let library):
            ContentUnavailableView {
                Label("No Music Files", systemImage: "music.note")
            } description: {
                Text("The library lists \(library.snapshotTrackCount) songs, but none of their files are on this iPhone. Export the music along with the database.")
            } actions: {
                Button("Check Again") { model.reload() }
            }
        }
    }
}
