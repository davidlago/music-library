import AppKit
import MusicLibraryCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct MusicLibraryApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Music Library") {
            ContentView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 560)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Import…") { model.chooseFilesToImport() }
                    .keyboardShortcut("o", modifiers: .command)
            }
            CommandGroup(after: .toolbar) {
                Button(model.showsQueue ? "Hide Queue" : "Show Queue") { model.showsQueue.toggle() }
                    .keyboardShortcut("u", modifiers: [.command, .option])
                Picker("Theme", selection: Binding(get: { model.themeID }, set: { model.themeID = $0 })) {
                    ForEach(Theme.all) { Text($0.name).tag($0.id) }
                }
            }
        }
        Settings {
            SettingsView().environment(model)
        }
    }
}
