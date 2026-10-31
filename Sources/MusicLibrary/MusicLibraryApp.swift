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
                // Room for the Radio DJ's pane beside the pages while it's on the air.
                .frame(minWidth: model.radioDJ.session == nil ? 900 : 900 + RadioDJPanel.width, minHeight: 560)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add to Physical Collection…") { model.addToCollection() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(model.collectionSheet != nil || model.smartPlaylistDraft != nil)
                Button("Import…") { model.chooseFilesToImport() }
                    .keyboardShortcut("o", modifiers: .command)
            }
            CommandMenu("Physical Collection") {
                // Also in the File menu, which has its shortcut (one key equivalent per command).
                // Not over a sheet that's showing, which would be replaced (and what's entered in it lost).
                Group {
                    Button("Add to Physical Collection…") { model.addToCollection() }
                    Button("Add Albums You Own…") { model.addLibraryAlbums() }
                    Divider()
                    Button("Find by Label…") { model.findByLabel() }
                        .keyboardShortcut("l", modifiers: .command)
                    Divider()
                    Button("Sync to Discogs…") { model.syncToDiscogs() }
                }
                .disabled(model.collectionSheet != nil || model.smartPlaylistDraft != nil)
            }
            CommandGroup(after: .toolbar) {
                Button(model.showsQueue ? "Hide Queue" : "Show Queue") { model.showsQueue.toggle() }
                    .keyboardShortcut("u", modifiers: [.command, .option])
                Picker("Appearance", selection: Binding(get: { model.appearance }, set: { model.appearance = $0 })) {
                    ForEach(AppearanceMode.allCases) { Text($0.name).tag($0) }
                }
            }
        }
        Settings {
            SettingsView().environment(model)
        }
    }
}
