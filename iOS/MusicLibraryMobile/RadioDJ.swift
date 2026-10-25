import AVFoundation
import MusicLibraryCore
import SwiftUI

/// The Radio DJ on the phone: the Claude API key and DJ name the Mac hands over at each sync (the key in the
/// keychain; without one the feature is off and doesn't show anywhere), and what it has cost on this phone, per
/// month (Application Support `radio-dj-usage.json`), which goes back to the Mac in the sync hello. Also the
/// conversation on the air, which stays while you browse: its sheet can be tucked away (the mini player's ON AIR
/// button brings it back) and only its close button ends it.
@Observable
final class PhoneRadioDJ {
    private(set) var apiKey: String
    private(set) var name: String
    /// The listener's own name, from the Mac (nil: none).
    private(set) var listenerName: String?
    private(set) var usage: RadioDJUsage
    /// The conversation on the air (nil: off).
    private(set) var session: RadioDJSession?
    /// The sheet is up (false: tucked away, still on the air).
    var isShowing = false
    /// The album or artist page showing (nil on other pages): `id` tells pages apart, `subject` is read fresh.
    private(set) var page: (id: UUID, topic: RadioDJSubject, subject: () -> RadioDJSubject)?
    /// Pushes a page onto the tab showing (set by each tab's stack as it appears).
    @ObservationIgnored var navigate: (any Hashable) -> Void = { _ in }
    /// About a preview the DJ's words point to: being looked up, or not found.
    var previewNote: String?
    /// Apple Music previews of songs not in the collection.
    let previews = PhonePreviewPlayer()
    @ObservationIgnored let previewClient = ApplePreviewClient(country: Locale.current.region?.identifier ?? "US")
    /// Previews found (nil: Apple has none), by "title|artist".
    @ObservationIgnored var previewCache: [String: ApplePreviewTrack?] = [:]

    @ObservationIgnored private let usageURL = URL.applicationSupportDirectory.appendingPathComponent("radio-dj-usage.json")

    init() {
        apiKey = KeychainStore.app.string(for: RadioDJ.keyAccount) ?? ""
        name = RadioDJ.displayName(UserDefaults.standard.string(forKey: RadioDJ.nameKey))
        listenerName = UserDefaults.standard.string(forKey: RadioDJ.listenerNameKey)
        usage = RadioDJUsage.load(from: usageURL)
    }

    var isEnabled: Bool { !apiKey.isEmpty }

    func begin(_ session: RadioDJSession) {
        self.session?.stop()
        self.session = session
        isShowing = true
        session.start()
    }

    func endSession() {
        session?.stop()
        session = nil
        isShowing = false
    }

    /// An album or artist page appeared.
    func showing(page id: UUID, subject: @escaping () -> RadioDJSubject) {
        page = (id, subject(), subject)
    }

    /// A page went away (another may already have taken its place).
    func left(page id: UUID) {
        if page?.id == id { page = nil }
    }

    /// Where you are, read now: the page showing, else the tab (`PhoneModel.radioDJLocation`).
    @ObservationIgnored var location: () -> RadioDJSubject? = { nil }
    var here: RadioDJSubject? { location() }
    /// Which page you're on, cheaply (an album or artist page as it was when it appeared), for showing.
    var hereTopic: RadioDJSubject? { page?.topic ?? location() }

    /// The Mac's settings: a nil key turns the DJ off here too.
    func adopt(_ settings: SyncRadioDJ) {
        let key = settings.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if key != apiKey, KeychainStore.app.set(key, for: RadioDJ.keyAccount) { apiKey = key }
        if apiKey.isEmpty { endSession() }
        name = RadioDJ.displayName(settings.name)
        UserDefaults.standard.set(name, forKey: RadioDJ.nameKey)
        listenerName = settings.listenerName
        UserDefaults.standard.set(listenerName, forKey: RadioDJ.listenerNameKey)
    }

    /// `library`: the collection the DJ can search while talking; `linker`: links its words to what you own.
    func makeSession(_ subject: RadioDJSubject, library: RadioDJLibrary?, linker: RadioDJLinker?) -> RadioDJSession {
        RadioDJSession(name: name, subject: subject, client: ClaudeClient(apiKey: apiKey), library: library,
                       linker: linker, listenerName: listenerName, wikipedia: WikipediaArticleFinder()) { [weak self] tally in
            self?.record(tally)
        }
    }

    private func record(_ tally: RadioDJTally) {
        usage.add(tally)
        usage.save(to: usageURL)
    }
}

/// The DJ's symbol: a chat bubble with sparkles (an AI to talk with), or sparkles alone on systems without it.
enum RadioDJIcon {
    static let name = symbol("text.bubble.badge.sparkles")
    static func name(filled: Bool) -> String { filled ? symbol("text.bubble.badge.sparkles.fill") : name }

    private static func symbol(_ preferred: String) -> String {
        UIImage(systemName: preferred) != nil ? preferred : "sparkles"
    }
}

// MARK: Pages

extension View {
    /// Tells the Radio DJ about an album, artist or item page while it shows: what the DJ opens with when it's put on
    /// the air here, and what it hears about when you move here with it on. `subject` is read when needed.
    func radioDJ(_ subject: @escaping () -> RadioDJSubject) -> some View {
        modifier(PhoneRadioDJModifier(subject: subject))
    }
}

/// Tells the DJ which page is showing, while it shows.
private struct PhoneRadioDJModifier: ViewModifier {
    @Environment(PhoneModel.self) private var model
    let subject: () -> RadioDJSubject
    /// Registers again when it changes (another Insights pane, a new search).
    var topic: String?
    @State private var pageID = UUID()

    func body(content: Content) -> some View {
        content
            .onAppear { model.radioDJ.showing(page: pageID, subject: subject) }
            .onDisappear { model.radioDJ.left(page: pageID) }
            .onChange(of: topic) { model.radioDJ.showing(page: pageID, subject: subject) }
    }
}

private struct RadioDJTopButtonModifier: ViewModifier {
    @Environment(PhoneModel.self) private var model
    let shown: Bool

    func body(content: Content) -> some View {
        content.toolbar {
            if shown, model.radioDJ.isEnabled {
                ToolbarItem(placement: .topBarTrailing) { RadioDJTopButton() }
            }
        }
    }
}

extension View {
    /// The DJ's button in the page's navigation bar (with an API key).
    func radioDJButton(_ shown: Bool = true) -> some View { modifier(RadioDJTopButtonModifier(shown: shown)) }

    /// Any other page: what it is and what's on it, for the DJ.
    func radioDJPage(_ subject: RadioDJSubject) -> some View {
        modifier(PhoneRadioDJModifier(subject: { subject }, topic: subject.topic))
    }
}

/// The DJ's button, at the top of every page: puts the DJ on the air about where you are, or brings its sheet back
/// while it's on (red then).
struct RadioDJTopButton: View {
    @Environment(PhoneModel.self) private var model

    var body: some View {
        let dj = model.radioDJ
        Button {
            if dj.session == nil { model.startRadioDJ(model.radioDJLocation) } else { dj.isShowing = true }
        } label: {
            Image(systemName: RadioDJIcon.name(filled: dj.session != nil))
                .foregroundStyle(dj.session == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.red))
                .symbolEffect(.pulse, isActive: dj.session?.isBusy == true)
        }
        .accessibilityLabel(dj.session == nil ? "Ask \(dj.name)" : "Back to \(dj.name)")
    }
}

extension View {
    /// The Radio DJ's sheet, for the root view: it stays over whatever tab and page you browse to.
    func radioDJSheet(_ model: PhoneModel, player: PhonePlayer) -> some View {
        let dj = model.radioDJ
        return sheet(isPresented: Binding(get: { dj.session != nil && dj.isShowing }, set: { if !$0 { dj.isShowing = false } })) {
            if let session = dj.session {
                RadioDJSheet(session: session, dj: dj) { model.openRadioDJ($0, player: player) }
                    .presentationDetents([.medium, .large])
                    .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                    .presentationContentInteraction(.scrolls)
                    // Long answers stay readable over a busy page.
                    .presentationBackground(.thickMaterial)
            }
        }
    }
}

extension PhoneModel {
    /// Puts the DJ on the air about `subject`, with the collection to search and link to.
    func startRadioDJ(_ subject: RadioDJSubject) {
        let present = library?.presentIDs ?? []
        let linker = library.map {
            RadioDJLinker(tracks: $0.tracks, collection: collection, subject: subject, canPlay: { present.contains($0.id) })
        }
        radioDJ.begin(radioDJ.makeSession(subject, library: radioDJLibrary, linker: linker))
    }

    /// A link in the DJ's words: pages open on the tab showing, with the sheet tucked away so you see them (the DJ stays
    /// on the air); songs on this iPhone play in their album.
    func openRadioDJ(_ reference: RadioDJReference, player: PhonePlayer) {
        guard let library else { return }
        func albumOfTrack(_ id: Int64) -> AlbumSummary? {
            library.track(id: id).flatMap { library.album(forKey: SearchIndex.albumKey(album: $0.album, artist: $0.effectiveAlbumArtist)) }
        }
        func show(_ route: some Hashable) {
            radioDJ.isShowing = false
            radioDJ.navigate(route)
        }
        switch reference {
        case .artist(let name): show(ArtistNameRoute(name: name))
        case .album(let key): if let found = library.album(forKey: key) { show(found) }
        case .item(let id): show(CollectionItemRoute(id: id))
        case .song(let id): if let found = albumOfTrack(id) { show(found) }
        case .play(let id):
            guard let found = albumOfTrack(id) else { return }
            let songs = self.playable(library.tracks(album: found))
            guard let index = songs.firstIndex(where: { $0.id == id }) else { return }
            radioDJ.previews.stop()
            player.play(queue: songs, startAt: index, source: found.album)
        case .preview(let title, let artist):
            playRadioDJPreview(title: title, artist: artist, player: player)
        }
    }

    /// A song not in the collection: its Apple Music preview, found by searching Apple's catalog (once per song), or
    /// paused and resumed when it's the one playing. The library's player pauses while it plays.
    func playRadioDJPreview(title: String, artist: String?, player: PhonePlayer) {
        let dj = radioDJ
        let key = "\(title)|\(artist ?? "")"
        func play(_ track: ApplePreviewTrack) {
            player.pause()
            dj.previews.play(track)
        }
        if let current = dj.previews.current, case let cached?? = dj.previewCache[key], cached.id == current.id {
            if dj.previews.isPlaying { dj.previews.pause() } else { play(cached) }
            return
        }
        if let cached = dj.previewCache[key] {
            if let track = cached { play(track) } else { dj.previewNote = "Apple Music has no preview of “\(title)”." }
            return
        }
        dj.previewNote = "Finding a preview of “\(title)”…"
        let client = dj.previewClient
        Task {
            let found = try? await client.searchSongs(term: [title, artist].compactMap { $0 }.joined(separator: " "))
            let track = found.flatMap { ApplePreviewMatcher.bestSong($0, title: title, artist: artist) }
            if found != nil { dj.previewCache[key] = .some(track) }
            if let track {
                dj.previewNote = nil
                play(track)
            } else {
                let note = found == nil ? "Couldn't reach Apple Music for a preview." : "Apple Music has no preview of “\(title)”."
                dj.previewNote = note
                try? await Task.sleep(for: .seconds(5))
                if dj.previewNote == note { dj.previewNote = nil }
            }
        }
    }
}

/// The DJ's booth: who's on, what they're saying (with the pages they checked) and a line to talk back.
struct RadioDJSheet: View {
    let session: RadioDJSession
    let dj: PhoneRadioDJ
    let open: (RadioDJReference) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        ForEach(session.lines) { line in
                            RadioDJLineView(line: line, segments: line.role == .dj ? session.segments(line) : [],
                                            speaking: session.activity == .speaking && line.id == session.lines.last?.id)
                                .id(line.id)
                        }
                        if let status = statusText {
                            HStack(spacing: 10) {
                                EqualizerBars().frame(width: 28, height: 16)
                                Text(status).font(.callout).italic().foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        if let error = session.error {
                            VStack(alignment: .leading, spacing: 8) {
                                Label(error, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
                                Button("Try Again") { session.retry() }.buttonStyle(.bordered).controlSize(.small)
                            }
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 16)
                }
                .defaultScrollAnchor(.bottom)
                .scrollDismissesKeyboard(.interactively)
                .environment(\.openURL, OpenURLAction { url in
                    if let reference = RadioDJReference(url: url) { open(reference); return .handled }
                    return url.isWebLink ? .systemAction : .discarded
                })
                // Follow the conversation: your question, the status line, the reply as it streams in, an error.
                .onChange(of: session.scrollKey) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .safeAreaInset(edge: .bottom) { composer }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 2) {
                        HStack(spacing: 8) {
                            OnAirSign(live: session.isBusy)
                            Text(session.name).font(.headline).lineLimit(1)
                        }
                        Text(RadioDJ.attributed(session.subject.headline)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button { dj.isShowing = false } label: { Image(systemName: "chevron.down") }
                        .accessibilityLabel("Keep listening in the background")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .close) { dj.endSession() }
                        .accessibilityLabel("Off the air")
                }
            }
        }
    }

    private var statusText: String? {
        switch session.activity {
        case .idle, .speaking: nil
        case .warmingUp: "Warming up the turntables…"
        case .searching(let q): q.isEmpty ? "Digging through the crates…" : "Digging through the crates: “\(q)”"
        case .reading(let host): host.isEmpty ? "Reading up…" : "Reading up on \(host)…"
        case .browsing(let q): q.isEmpty ? "Flipping through your shelves…" : "Flipping through your shelves: \(q)"
        }
    }

    @ViewBuilder
    private var previewRow: some View {
        if let note = dj.previewNote ?? dj.previews.lastError {
            Label(note, systemImage: "headphones").font(.caption).foregroundStyle(.secondary)
        } else if let track = dj.previews.current, dj.previews.isPlaying {
            HStack(spacing: 8) {
                Image(systemName: "headphones").foregroundStyle(Color.accentColor)
                Text("Preview: “\(track.title)” — \(track.artist)").font(.caption).lineLimit(1)
                Spacer(minLength: 0)
                Button("Stop") { dj.previews.stop() }.buttonStyle(.bordered).controlSize(.mini)
            }
        }
    }

    private var composer: some View {
        VStack(spacing: 4) {
            previewRow
            if let page = dj.hereTopic, session.isElsewhere(page), !session.isBusy {
                Button {
                    session.send("Tell me about this one.", page: dj.here)
                } label: {
                    Label { Text(RadioDJ.attributed("Tell me about \(page.headline)")).lineLimit(1) } icon: { Image(systemName: RadioDJIcon.name) }
                        .font(.subheadline)
                }
                .buttonStyle(.glass)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ask \(session.name) anything…", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($focused)
                    .submitLabel(.send)
                    .onSubmit(send)
                    .padding(.horizontal, 16).padding(.vertical, 11)
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
                Button(action: send) {
                    Image(systemName: "arrow.up").font(.body.weight(.semibold)).frame(width: 30, height: 30)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .disabled(!canSend)
                .accessibilityLabel("Send")
            }
            Text("This segment: about \(DollarFormat.string(session.cost))")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.bottom, 8).padding(.top, 6)
    }

    private var canSend: Bool { !session.isBusy && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func send() {
        guard canSend else { return }
        session.send(draft, page: dj.here)
        draft = ""
    }
}

private struct RadioDJLineView: View {
    let line: RadioDJSession.Line
    let segments: [RadioDJSegment]
    let speaking: Bool

    var body: some View {
        switch line.role {
        case .listener:
            HStack {
                Spacer(minLength: 48)
                Text(line.text)
                    .textSelection(.enabled)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 18).fill(Color.accentColor))
            }
        case .dj:
            HStack(alignment: .top, spacing: 10) {
                DJAvatar(speaking: speaking)
                VStack(alignment: .leading, spacing: 10) {
                    RadioDJText.text(segments)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if !line.sources.isEmpty {
                        FlowLayout(spacing: 6) {
                            ForEach(line.sources) { source in
                                Link(destination: source.url) {
                                    Label(source.host, systemImage: "link").font(.caption).lineLimit(1)
                                        .padding(.horizontal, 9).padding(.vertical, 4)
                                        .background(Capsule().fill(Color(.tertiarySystemFill)))
                                }
                                .accessibilityLabel("Source: \(source.title)")
                            }
                        }
                    }
                }
            }
        }
    }
}

/// The red sign over the studio door, glowing while the DJ is talking or looking something up.
struct OnAirSign: View {
    let live: Bool

    var body: some View {
        Text("ON AIR")
            .font(.system(size: 9, weight: .heavy, design: .rounded))
            .tracking(1.4)
            .foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.red.gradient))
            .shadow(color: .red.opacity(live ? 0.8 : 0.25), radius: live ? 6 : 2)
            .animation(live ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default, value: live)
    }
}

private struct DJAvatar: View {
    let speaking: Bool

    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [.orange, .pink], startPoint: .topLeading, endPoint: .bottomTrailing))
            if speaking {
                EqualizerBars(color: .white).frame(width: 14, height: 12)
            } else {
                Image(systemName: "music.mic").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
            }
        }
        .frame(width: 30, height: 30)
    }
}

/// Four bars bouncing like a VU meter.
struct EqualizerBars: View {
    var color: Color = .orange

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                HStack(alignment: .bottom, spacing: geo.size.width * 0.12) {
                    ForEach(0..<4) { i in
                        let level = 0.3 + 0.7 * abs(sin(t * (3.1 + Double(i) * 0.9) + Double(i) * 1.7))
                        RoundedRectangle(cornerRadius: 1.5).fill(color)
                            .frame(height: geo.size.height * level)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
    }
}

/// The DJ's words in one `Text` (so they select and wrap as one): links to the collection, and songs to play with a
/// play icon before them. Links to what you own are in the accent color, the rest (previews, web pages) in `outside`.
enum RadioDJText {
    static let outside = Color.purple

    static func text(_ segments: [RadioDJSegment]) -> Text {
        segments.reduce(Text(verbatim: "")) { text, segment in
            switch segment {
            case .text(let words):
                return Text("\(text)\(words)")
            case .play(let title):
                let icon = Text(Image(systemName: "play.circle.fill")).foregroundStyle(Color.accentColor)
                return Text("\(text)\(icon)\u{202F}\(title)")
            case .preview(var title):
                // Not yours: a 30-second sample, in headphones rather than the play button, in the not-yours color.
                title.foregroundColor = outside
                let icon = Text(Image(systemName: "headphones.circle")).foregroundStyle(outside)
                return Text("\(text)\(icon)\u{202F}\(title)")
            case .external(var title):
                // Not yours: opens a page on the web.
                title.foregroundColor = outside
                let icon = Text(Image(systemName: "arrow.up.right.square")).font(.caption).foregroundStyle(outside)
                return Text("\(text)\(title)\u{202F}\(icon)")
            }
        }
    }
}

/// Plays Apple Music previews of songs the DJ mentions that aren't in the collection: one clip at a time, apart from
/// the library's player (never in its queue, history or Last.fm).
@Observable
final class PhonePreviewPlayer {
    private(set) var current: ApplePreviewTrack?
    private(set) var isPlaying = false
    /// Why the last clip didn't play.
    private(set) var lastError: String?

    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?

    /// Plays `track`'s clip. The playback session is set up first: until one of your own songs has played, the app's
    /// session is the default one, which the silent switch mutes.
    func play(_ track: ApplePreviewTrack) {
        guard let url = track.previewURL, ApplePreviewParser.isAppleURL(url) else { return }
        lastError = nil
        if current?.id != track.id {
            let item = AVPlayerItem(url: url)
            if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
            endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.isPlaying = false; self?.current = nil }
            }
            statusObservation = item.observe(\.status) { [weak self] item, _ in
                guard item.status == .failed else { return }
                let message = item.error?.localizedDescription ?? "unknown error"
                Task { @MainActor in
                    guard let self, self.current?.previewURL == url else { return }
                    self.lastError = "Couldn't play the preview: \(message)"
                    self.stop()
                }
            }
            player.replaceCurrentItem(with: item)
            current = track
        }
        isPlaying = true
        let player = player
        Task.detached(priority: .userInitiated) {
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .default)
            try? session.setActive(true)
            await MainActor.run {
                guard self.isPlaying, self.current?.id == track.id else { return }
                player.play()
            }
        }
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        statusObservation = nil
        current = nil
        isPlaying = false
    }
}

// MARK: Settings

/// Shown only while the DJ is on (the Mac handed over a key).
struct RadioDJSettingsSection: View {
    let dj: PhoneRadioDJ

    var body: some View {
        Section {
            LabeledContent("DJ", value: dj.name)
            if let listener = dj.listenerName { LabeledContent("Calls you", value: listener) }
            LabeledContent("This month", value: DollarFormat.string(dj.usage.month().dollars))
            LabeledContent("All time", value: DollarFormat.string(dj.usage.allTime.dollars))
            LabeledContent("Segments", value: "\(dj.usage.allTime.segments)")
        } header: {
            Text("Radio DJ")
        } footer: {
            Text("Tap On Air on an album or artist page. The Claude API key, the DJ's name and yours come from your Mac when you sync; change them there. Spending on this iPhone (calendar months, UTC, as Anthropic bills) is estimated at Claude API list prices and shows on your Mac after the next sync.")
        }
    }
}

// MARK: What's on the page

extension PhoneModel {
    /// What the DJ's collection search reads, as it is now (nil before the library loads).
    var radioDJLibrary: RadioDJLibrary? {
        library.map { RadioDJLibrary(index: $0.index, collectionIndex: collectionIndex, collection: collection,
                                     playTotals: playTotals, likedDates: likedDates, plays: plays,
                                     albumInfos: $0.albumInfos, currencyCode: currencyCode) }
    }

    /// Where you are, for the DJ: the page showing, else the tab.
    var radioDJLocation: RadioDJSubject {
        if let page = radioDJ.page { return page.subject() }
        return switch UserDefaults.standard.string(forKey: "selectedTab") {
        case "library": .page("the Digital Collection tab")
        case "insights": .page("Insights", details: ["Their collection statistics; collection_stats has the numbers."])
        case "sync": .page("the Sync tab")
        case "search": .page("Search")
        default: .page("the Physical Collection tab")
        }
    }

    private func plays(_ tracks: [Track]) -> Int { tracks.reduce(0) { $0 + (playTotals[$1.id]?.plays ?? 0) } }
    private func liked(_ tracks: [Track]) -> Int { tracks.filter { likedDates[$0.id] != nil }.count }

    func radioDJSubject(album: AlbumSummary, tracks: [Track], info: AlbumInfo?) -> RadioDJSubject {
        .album(album, tracks: tracks, info: info, items: collection.copies(albumKey: SearchIndex.albumKey(album: album.album, artist: album.artist)),
               plays: plays(tracks), liked: liked(tracks))
    }

    func radioDJSubject(item: CollectionItem) -> RadioDJSubject {
        let tracks = collection.libraryTracks(item)
        return .item(item, tracks: tracks, info: library?.albumInfos[item.albumKey], plays: plays(tracks), liked: liked(tracks))
    }

    func radioDJSubject(artist name: String, tracks: [Track], albums: [AlbumSummary], info: ArtistInfo?) -> RadioDJSubject {
        let top = tracks.map { ($0, playTotals[$0.id]?.plays ?? 0) }.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }
            .prefix(5).map { "“\($0.0.title)” (\($0.1) plays)" }
        return .artist(name, info: info, albums: albums, tracks: tracks, items: collection.items(artist: name),
                       plays: plays(tracks), topSongs: Array(top))
    }
}
