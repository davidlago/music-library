import AppKit
import MusicLibraryCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            PlaybackSettings().tabItem { Label("Playback", systemImage: "play.circle") }
            AppearanceSettings().tabItem { Label("Appearance", systemImage: "paintpalette") }
            LastFMSettings().tabItem { Label("Last.fm", systemImage: "dot.radiowaves.left.and.right") }
        }
        .frame(width: 600)
        .themedRoot(model.theme)
    }
}

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Library") {
                LabeledContent("Folder") {
                    VStack(alignment: .trailing) {
                        Text(model.libraryRoot.path).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                        Button("Choose…") { model.chooseLibraryRoot() }
                    }
                }
                Text("Changing the folder opens (or creates) a library there. Existing files and the database are not moved or migrated.")
                    .font(.caption).foregroundStyle(.subtext)
            }
            Section("MusicBrainz") {
                TextField("Contact email", text: $model.mbContact, prompt: Text("you@example.com"))
                Text("Sent in the User-Agent of MusicBrainz requests, as their API etiquette asks.")
                    .font(.caption).foregroundStyle(.subtext)
                Toggle("Auto-match confident results (score ≥ 95, duration within 5 s)", isOn: $model.autoMatch)
            }
            Section("AcoustID fingerprinting (optional)") {
                TextField("API key", text: $model.acoustIDKey)
                Link("Get an API key at acoustid.org", destination: URL(string: "https://acoustid.org/new-application")!)
                toolRow("fpcalc", url: model.tools.fpcalc, hint: "Install with `brew install chromaprint`")
            }
            Section("Artist & album info") {
                Toggle("Download artist photos, bios, album descriptions and links automatically", isOn: Binding(
                    get: { model.artistInfo.autoSync }, set: { model.artistInfo.autoSync = $0 }))
                Text("From MusicBrainz, Wikipedia and Wikimedia Commons (and Last.fm when it's connected). Photos are saved in the library's Artist Images folder.")
                    .font(.caption).foregroundStyle(.subtext)
                HStack {
                    Button("Update All Now") { model.refreshArtistInfo(model.artists.map(\.name)) }
                        .disabled(model.artistInfo.isSyncing)
                    SyncStatus(showsUpdateButton: false)
                }
            }
            Section("CD ripping") {
                Toggle("Eject CD after ripping", isOn: $model.ejectAfterRip)
            }
            Section("Tools") {
                toolRow("ffmpeg", url: model.tools.ffmpeg, hint: "Install with `brew install ffmpeg`")
                toolRow("ffprobe", url: model.tools.ffprobe, hint: "Installed together with ffmpeg")
                Button("Re-check") { model.refreshTools() }
            }
        }
        .formStyle(.grouped)
        .themedScrollBackground()
        .onAppear { model.refreshTools() }
    }

    private func toolRow(_ name: String, url: URL?, hint: String) -> some View {
        LabeledContent(name) {
            if let url {
                Label(url.path, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
            } else {
                Label("Not found — \(hint)", systemImage: "xmark.circle.fill").foregroundStyle(.red).font(.caption)
            }
        }
    }
}

struct PlaybackSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Output") {
                Toggle("Match output device sample rate to the song", isOn: $model.matchOutputRate)
                Toggle("Match output bit depth", isOn: $model.matchOutputBitDepth).disabled(!model.matchOutputRate)
                Text("Changes your output device's format for all apps while playing. The original format is restored when you quit or turn this off. Has no effect on devices with a fixed rate (e.g. Bluetooth/AirPlay).")
                    .font(.caption).foregroundStyle(.subtext)
            }
        }
        .formStyle(.grouped)
        .themedScrollBackground()
    }
}

struct AppearanceSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let families = Dictionary(grouping: Theme.all, by: \.family)
        let order = Theme.all.map(\.family).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Themes color the whole window, the player and the Insights charts. Themes marked \(Image(systemName: "circle.lefthalf.filled")) follow your Mac's light or dark setting.")
                    .font(.callout).foregroundStyle(.subtext)
                ForEach(order, id: \.self) { family in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(family).font(.headline)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 150), spacing: 14)], alignment: .leading, spacing: 14) {
                            ForEach(families[family] ?? []) { theme in
                                Button { model.themeID = theme.id } label: {
                                    ThemeSwatch(theme: theme, selected: model.themeID == theme.id)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(theme.name)
                                .accessibilityAddTraits(model.themeID == theme.id ? .isSelected : [])
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
        .frame(height: 520)
    }
}

struct LastFMSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var scrobbler = model.scrobbler
        Form {
            Section {
                Text("Scrobbling sends the songs you play to your Last.fm profile. A song counts once you've listened to half of it or 4 minutes, whichever comes first (songs under 30 seconds don't count).")
                    .font(.callout).foregroundStyle(.subtext)
            }
            Section {
                TextField(text: $scrobbler.apiKey) { Text("API key").font(.body) }
                    .font(.system(.body, design: .monospaced))
                SecureField("Shared secret", text: $scrobbler.sharedSecret)
                Link("Create a free API account at last.fm (the callback URL can stay empty)",
                     destination: URL(string: "https://www.last.fm/api/account/create")!)
                    .font(.caption)
            } header: {
                Text("API account")
            } footer: {
                Text("Last.fm needs an API key and shared secret for each app. Both are stored in this app's preferences on this Mac.")
                    .font(.caption).foregroundStyle(.subtext)
            }
            Section("Account") {
                accountRow(scrobbler)
                if let error = scrobbler.lastError {
                    Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
            }
            Section("Scrobbling") {
                Toggle("Scrobble songs I play", isOn: $scrobbler.scrobblingEnabled)
                Toggle("Show what's playing now on my profile", isOn: $scrobbler.sendsNowPlaying)
                    .disabled(!scrobbler.scrobblingEnabled)
                LabeledContent("Waiting to send") {
                    HStack {
                        Text(scrobbler.pendingCount == 0 ? "Nothing" : "\(scrobbler.pendingCount) scrobble\(scrobbler.pendingCount == 1 ? "" : "s")")
                            .foregroundStyle(.subtext)
                        if scrobbler.isSending { ProgressView().controlSize(.small) }
                        if scrobbler.pendingCount > 0 { Button("Send Now") { scrobbler.flush() }.disabled(scrobbler.isSending) }
                    }
                }
            }
            if !scrobbler.recent.isEmpty {
                Section("Recently scrobbled") {
                    ForEach(scrobbler.recent) { s in
                        HStack {
                            Text(s.track).lineLimit(1)
                            Text(s.artist).foregroundStyle(.subtext).lineLimit(1)
                            Spacer()
                            Text(Date(timeIntervalSince1970: TimeInterval(s.timestamp)), style: .relative)
                                .font(.caption).foregroundStyle(.subtext).monospacedDigit()
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .themedScrollBackground()
        .frame(height: 560)
    }

    @ViewBuilder
    private func accountRow(_ scrobbler: Scrobbler) -> some View {
        switch scrobbler.status {
        case .notConfigured:
            LabeledContent("Status") { Text("Enter your API key and secret first").foregroundStyle(.subtext) }
        case .disconnected:
            LabeledContent("Status") {
                HStack {
                    Text("Not connected").foregroundStyle(.subtext)
                    Button("Connect…") { scrobbler.connect() }
                }
            }
        case .authorizing:
            LabeledContent("Status") {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Allow access in your browser…").foregroundStyle(.subtext)
                    Button("Open Page Again") { scrobbler.reopenAuthorizationPage() }
                    Button("Cancel") { scrobbler.cancelAuthorization() }
                }
            }
        case .connected(let user):
            LabeledContent("Status") {
                HStack {
                    Label("Connected as \(user)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Link("Profile", destination: URL(string: "https://www.last.fm/user/\(user.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? user)")!)
                    Button("Disconnect") { scrobbler.disconnect() }
                }
            }
        case .needsReauthorization(let user):
            LabeledContent("Status") {
                HStack {
                    Label("\(user): connection expired", systemImage: "exclamationmark.circle.fill").foregroundStyle(.orange)
                    Button("Reconnect…") { scrobbler.connect() }
                    Button("Disconnect") { scrobbler.disconnect() }
                }
            }
        }
    }
}
