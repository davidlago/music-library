import SwiftUI

@main
struct MusicLibraryMobileApp: App {
    @State private var model = PhoneModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(model.player)
                .onChange(of: scenePhase, initial: true) { _, phase in
                    switch phase {
                    case .active:
                        // Finder's Files tab (and later sync) changes the library while the app is in the background.
                        model.reloadIfChanged()
                        model.scrobbler.flush()
                    case .background:
                        model.savePlayerState()
                        model.noteInterruptedPlay()
                    default:
                        break
                    }
                }
        }
    }
}
