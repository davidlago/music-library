import MusicLibraryGlance
import SwiftUI

@main
struct MusicLibraryWatchApp: App {
    @State private var model = WatchModel.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { model.refresh() }
                }
        }
        // What the iPhone sent while the app wasn't running arrives in a background refresh; the complications are
        // reloaded when it does.
        .backgroundTask(.watchConnectivity) {
            _ = await MainActor.run { WatchModel.shared }
            await WatchModel.waitForPendingContent()
        }
    }
}

struct ContentView: View {
    @Environment(WatchModel.self) private var model

    var body: some View {
        NavigationStack {
            if let glance = model.glance {
                TabView {
                    NowPlayingPage(glance: glance)
                    ShelfPage(glance: glance)
                    ListeningPage(glance: glance)
                    PlayPage(glance: glance)
                }
                .tabViewStyle(.verticalPage)
                .navigationDestination(for: Glance.Album.self) { AlbumPage(album: $0) }
                .navigationDestination(for: Glance.Collection.Item.self) { ShelfItemPage(item: $0) }
                .navigationDestination(for: WatchRoute.self) { route in
                    switch route {
                    case .find: WatchFindPage()
                    }
                }
            } else {
                ContentUnavailableView {
                    Label("Open on iPhone", systemImage: "iphone")
                } description: {
                    Text("Open Music Library on your iPhone once, and your collection, listening and what's playing show up here.")
                }
            }
        }
    }
}
