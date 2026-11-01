import MusicLibraryCore
import SwiftUI
import UIKit

@main
struct MusicLibraryMobileApp: App {
    @State private var model = PhoneModel.shared
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppearanceMode.defaultsKey) private var appearance = AppearanceMode.system

    init() {
        CloudContainer.logAvailability()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(model.player)
                .onChange(of: appearance, initial: true) { _, mode in applyAppearance(mode) }
                .onChange(of: scenePhase, initial: true) { _, phase in
                    // While the app is open, it looks for the paired Mac so it can sync what's asked for.
                    model.sync.setActive(phase == .active)
                    switch phase {
                    case .active:
                        applyAppearance(appearance)
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

    /// Light or Dark overrides every window (sheets included); System clears the override. Set on the windows
    /// rather than with `preferredColorScheme`, which doesn't always return to the system's setting once cleared.
    private func applyAppearance(_ mode: AppearanceMode) {
        let style: UIUserInterfaceStyle = switch mode {
        case .system: .unspecified
        case .light: .light
        case .dark: .dark
        }
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows { window.overrideUserInterfaceStyle = style }
        }
    }
}
