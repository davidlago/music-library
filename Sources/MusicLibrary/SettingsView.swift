import AppKit
import MusicLibraryCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            PlaybackSettings().tabItem { Label("Playback", systemImage: "play.circle") }
            AppearanceSettings().tabItem { Label("Appearance", systemImage: "circle.lefthalf.filled") }
            LastFMSettings().tabItem { Label("Last.fm", systemImage: "dot.radiowaves.left.and.right") }
            ConcertSettings().tabItem { Label("Concerts", systemImage: "ticket") }
            DiscogsSettings().tabItem { Label("Discogs", systemImage: "opticaldisc") }
            RadioDJSettings().tabItem { Label("Radio DJ", systemImage: RadioDJIcon.name) }
            LibraryCatalogSettings().tabItem { Label("Local Library", systemImage: "building.columns") }
        }
        .frame(width: 600)
    }
}

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Library Folder") {
                LabeledContent("Folder") {
                    VStack(alignment: .trailing) {
                        Text(model.libraryRoot.path).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                        Button("Choose…") { model.chooseLibraryRoot() }
                    }
                }
                Text("Changing the folder opens (or creates) a library there. Existing files and the database are not moved or migrated.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Export") {
                LabeledContent("Destination") {
                    VStack(alignment: .trailing) {
                        Text(model.exportDestination?.path ?? "None").textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                        HStack {
                            if model.exportDestination != nil { Button("Clear") { model.clearExportDestination() } }
                            Button("Choose…") { model.chooseExportDestination() }
                        }
                    }
                }
                Text("Where the Export List is copied to, such as a USB music player or a backup drive.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("MusicBrainz") {
                TextField("Contact email", text: $model.mbContact, prompt: Text("you@example.com"))
                Text("Sent in the User-Agent of MusicBrainz requests, as their API etiquette asks.")
                    .font(.caption).foregroundStyle(.secondary)
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
                Text("From MusicBrainz, Wikipedia and Wikimedia Commons (and Last.fm when it's connected). Photos are saved in the Artist Images folder of your library folder.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Update All Now") { model.refreshArtistInfo(model.artists.map(\.name)) }
                        .disabled(model.artistInfo.isSyncing)
                    SyncStatus(showsUpdateButton: false)
                }
            }
            Section("CD ripping") {
                Toggle("Eject CD after ripping", isOn: $model.ejectAfterRip)
            }
            Section("Physical Collection") {
                Toggle("Ask whether a CD is yours when it's inserted", isOn: $model.askCDOwnership)
                    .help("Off: a CD that isn't in your physical collection yet is added to it when you rip it, unless you say otherwise")
                Toggle("Eject after cataloging", isOn: $model.ejectAfterCataloging)
                    .help("Eject a CD once Catalog Without Ripping has added it to your physical collection")
            }
            Section("Tools") {
                toolRow("ffmpeg", url: model.tools.ffmpeg, hint: "Install with `brew install ffmpeg`")
                toolRow("ffprobe", url: model.tools.ffprobe, hint: "Installed together with ffmpeg")
                Button("Re-check") { model.refreshTools() }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refreshTools() }
    }

    private func toolRow(_ name: String, url: URL?, hint: String) -> some View {
        LabeledContent(name) {
            if let url {
                let included = url.deletingLastPathComponent().path == ToolLocator.bundledToolsPath
                Label(included ? "Included with the app" : url.path, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
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
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct AppearanceSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 22) {
                ForEach(AppearanceMode.allCases) { mode in
                    Button { model.appearance = mode } label: {
                        AppearanceSwatch(mode: mode, selected: model.appearance == mode)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(mode.name)
                    .accessibilityAddTraits(model.appearance == mode ? .isSelected : [])
                }
            }
            Text(model.appearance == .system ? "Follows your Mac's light or dark setting." : "Always \(model.appearance.name.lowercased()), whatever your Mac uses.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }
}

struct LastFMSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var scrobbler = model.scrobbler
        Form {
            Section {
                Text("Scrobbling sends the songs you play to your Last.fm profile. A song counts once you've listened to half of it or 4 minutes, whichever comes first (songs under 30 seconds don't count).")
                    .font(.callout).foregroundStyle(.secondary)
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
                Text("Last.fm needs an API key and shared secret for each app. Both are stored in your keychain on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
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
                            .foregroundStyle(.secondary)
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
                            Text(s.artist).foregroundStyle(.secondary).lineLimit(1)
                            Spacer()
                            Text(Date(timeIntervalSince1970: TimeInterval(s.timestamp)), style: .relative)
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 560)
    }

    @ViewBuilder
    private func accountRow(_ scrobbler: Scrobbler) -> some View {
        switch scrobbler.status {
        case .notConfigured:
            LabeledContent("Status") { Text("Enter your API key and secret first").foregroundStyle(.secondary) }
        case .disconnected:
            LabeledContent("Status") {
                HStack {
                    Text("Not connected").foregroundStyle(.secondary)
                    Button("Connect…") { scrobbler.connect() }
                }
            }
        case .authorizing:
            LabeledContent("Status") {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Allow access in your browser…").foregroundStyle(.secondary)
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

struct LibraryCatalogSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var catalog = model.catalog
        Form {
            Section {
                Text("Browse your local library's music CDs, see which libraries have them on the shelf and which are already in your digital or physical collection. Works with library catalogs run on Aspen Discovery, like the Minuteman Library Network.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Catalog") {
                CatalogSiteField()
                Picker("My local library", selection: $catalog.homeLibrary) {
                    Text("None").tag("")
                    ForEach(catalog.libraryChoices) { Text($0.name).tag($0.name) }
                }
                Text("Selected when browsing, listed first in availability, and offered for “Available now at”.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                TextField("Library card number or username", text: $catalog.username)
                SecureField("PIN or password", text: $catalog.password)
                LabeledContent("Status") { accountStatus }
                if catalog.isSignedIn {
                    Picker("List for Music Library", selection: $catalog.listId) {
                        Text("None").tag("")
                        ForEach(catalog.userLists) { Text($0.title).tag($0.id) }
                    }
                    .disabled(catalog.userLists.isEmpty)
                    if catalog.userLists.isEmpty, let url = catalog.webURL("/MyAccount/Lists") {
                        Link("You have no lists yet. Create one on the local library's website.", destination: url).font(.caption)
                    }
                }
            } header: {
                Text("Account")
            } footer: {
                Text("Used to show what you have checked out, and to add CDs to one of your lists on the local library's website so you know what to look for. The password is stored in your keychain on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            CatalogDownloadSettings()
            Section("Album details") {
                Toggle("Look up track lists, covers and info on MusicBrainz as CDs load", isOn: $catalog.autoLookup)
                Text("Each CD is matched by its barcode (or its title and artist) once, then remembered in your library database. This also recognizes CDs you already have when the catalog spells them differently.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: 640)
        .onAppear { if catalog.libraries.isEmpty { catalog.loadLibraries() } }
    }

    @ViewBuilder
    private var accountStatus: some View {
        let catalog = model.catalog
        HStack {
            switch catalog.account {
            case .signedOut:
                Text("Not signed in").foregroundStyle(.secondary)
            case .signingIn:
                ProgressView().controlSize(.small)
                Text("Signing in…").foregroundStyle(.secondary)
            case .signedIn(let name):
                Label("Signed in as \(name)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.circle.fill").foregroundStyle(.orange).lineLimit(2)
            }
            if catalog.isSignedIn {
                Button("Sign Out") { catalog.signOut() }
            } else {
                Button("Sign In") { catalog.signIn() }
                    .disabled(catalog.username.isEmpty || catalog.password.isEmpty || catalog.account == .signingIn)
            }
        }
    }
}

/// The catalog's address, applied when you press Return or leave the field: changing the site signs out and
/// starts over, so it shouldn't happen on every keystroke.
struct CatalogSiteField: View {
    @Environment(AppModel.self) private var model
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Website", text: $draft, prompt: Text(LibraryCatalogStore.defaultSite))
            .focused($focused)
            .onSubmit(apply)
            .onChange(of: focused) { _, isFocused in if !isFocused { apply() } }
            .onAppear { draft = model.catalog.siteAddress }
    }

    private func apply() {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        let candidate = trimmed.isEmpty ? LibraryCatalogStore.defaultSite : trimmed
        // Only addresses that look like a site (a dotted host); otherwise keep the current one.
        guard let url = URL(string: candidate.contains("://") ? candidate : "https://\(candidate)"),
              let host = url.host, host.contains(".") else {
            draft = model.catalog.siteAddress
            return
        }
        model.catalog.siteAddress = candidate
    }
}
