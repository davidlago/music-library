import MusicLibraryCore
import SwiftUI

struct SettingsView: View {
    @Environment(PhoneModel.self) private var model
    @Environment(PhonePlayer.self) private var player
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var player = player
        NavigationStack {
            Form {
                Section {
                    Toggle("Match the DAC's sample rate", isOn: $player.matchSampleRate)
                    if let output = player.output {
                        LabeledContent("Output", value: "\(output.name) · \(AudioFormat.kHzString(output.sampleRate)) kHz")
                    }
                } header: {
                    Text("Playback")
                } footer: {
                    Text("Before each song, the output switches to the song's sample rate, so a USB DAC plays it at its own rate. Songs at the same rate play without gaps. For bit-perfect output, keep the iPhone's volume at maximum and use the DAC's or amplifier's volume.")
                }
                NavigationLink {
                    LastFMSettings()
                } label: {
                    LabeledContent("Last.fm") {
                        Text(lastFMSummary)
                    }
                }
                if let library = model.library {
                    Section("Library") {
                        LabeledContent("Songs on this iPhone", value: "\(library.presentIDs.count) of \(library.tracks.count)")
                        LabeledContent("Folder", value: library.root.lastPathComponent)
                        Button("Reload Library") { model.reload() }
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var lastFMSummary: String {
        switch model.scrobbler.status {
        case .notConfigured, .disconnected: return "Off"
        case .authorizing: return "Connecting…"
        case .connected(let user): return model.scrobbler.scrobblingEnabled ? user : "Paused"
        case .needsReauthorization: return "Reconnect"
        }
    }
}

/// The Mac app's Last.fm settings, for the phone. The account is the phone's own (its keychain), so the API key
/// and secret are entered here too; Universal Clipboard makes pasting them from the Mac easy.
struct LastFMSettings: View {
    @Environment(PhoneModel.self) private var model

    var body: some View {
        @Bindable var scrobbler = model.scrobbler
        Form {
            Section {
                Text("Scrobbling sends the songs you play to your Last.fm profile. A song counts once you've listened to half of it or 4 minutes, whichever comes first (songs under 30 seconds don't count).")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                TextField("API key", text: $scrobbler.apiKey)
                    .font(.system(.body, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Shared secret", text: $scrobbler.sharedSecret)
                Link("Create a free API account at last.fm (the callback URL can stay empty)",
                     destination: URL(string: "https://www.last.fm/api/account/create")!)
                    .font(.caption)
            } header: {
                Text("API account")
            } footer: {
                Text("Last.fm needs an API key and shared secret for each app. You can reuse the ones from the Mac app. Both are stored in this iPhone's keychain.")
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
                        if scrobbler.isSending { ProgressView() }
                        Text(scrobbler.pendingCount == 0 ? "Nothing" : "\(scrobbler.pendingCount) scrobble\(scrobbler.pendingCount == 1 ? "" : "s")")
                    }
                }
                if scrobbler.pendingCount > 0 {
                    Button("Send Now") { scrobbler.flush() }.disabled(scrobbler.isSending)
                }
            }
            if !scrobbler.recent.isEmpty {
                Section("Recently scrobbled") {
                    ForEach(scrobbler.recent) { s in
                        VStack(alignment: .leading) {
                            Text(s.track).lineLimit(1)
                            HStack {
                                Text(s.artist).lineLimit(1)
                                Spacer()
                                Text(Date(timeIntervalSince1970: TimeInterval(s.timestamp)), style: .relative).monospacedDigit()
                            }
                            .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Last.fm")
    }

    @ViewBuilder
    private func accountRow(_ scrobbler: Scrobbler) -> some View {
        switch scrobbler.status {
        case .notConfigured:
            Text("Enter your API key and secret first").foregroundStyle(.secondary)
        case .disconnected:
            Button("Connect…") { scrobbler.connect() }
        case .authorizing:
            HStack {
                ProgressView()
                Text("Allow access in Safari, then come back…").foregroundStyle(.secondary)
            }
            Button("Open Page Again") { scrobbler.reopenAuthorizationPage() }
            Button("Cancel", role: .cancel) { scrobbler.cancelAuthorization() }
        case .connected(let user):
            Label("Connected as \(user)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            if let profile = URL(string: "https://www.last.fm/user/\(user.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? user)") {
                Link("Open Profile", destination: profile)
            }
            Button("Disconnect", role: .destructive) { scrobbler.disconnect() }
        case .needsReauthorization(let user):
            Label("\(user): connection expired", systemImage: "exclamationmark.circle.fill").foregroundStyle(.orange)
            Button("Reconnect…") { scrobbler.connect() }
            Button("Disconnect", role: .destructive) { scrobbler.disconnect() }
        }
    }
}
