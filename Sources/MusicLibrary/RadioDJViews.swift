import AppKit
import MusicLibraryCore
import SwiftUI
import UniformTypeIdentifiers

/// The Radio DJ's settings and spend on the Mac: the Claude API and OpenRouter keys (keychain; handed to the phone at
/// each sync), the model (`RadioDJModel`, user defaults), the DJ's name, and what it has cost here, per month
/// (Application Support `MusicLibrary/radio-dj-usage.json`). Without a key for the chosen model's provider the feature
/// is off and nothing of it shows outside Settings. Also the conversation on the air, which
/// stays open in a pane beside the window's pages while you browse, and the album or artist page showing now.
@MainActor @Observable
final class RadioDJStore {
    enum KeyStatus: Equatable {
        case unchecked, checking, valid
        case invalid(String)
    }

    var apiKey: String {
        didSet {
            KeychainStore.app.set(trimmedKey, for: RadioDJ.keyAccount)
            keyStatus = .unchecked
            if !isEnabled { endSession() }
        }
    }
    var openRouterKey: String {
        didSet {
            KeychainStore.app.set(trimmedOpenRouterKey, for: RadioDJ.openRouterKeyAccount)
            openRouterKeyStatus = .unchecked
            if !isEnabled { endSession() }
        }
    }
    /// What the DJ talks with; a change takes effect the next time it comes on the air.
    var model: RadioDJModel {
        didSet {
            model.save()
            if !isEnabled { endSession() }
        }
    }
    /// OpenRouter's models (nil: not loaded yet), and why they couldn't be.
    private(set) var openRouterModels: [RadioDJModel]?
    private(set) var openRouterModelsError: String?
    private(set) var loadingOpenRouterModels = false
    var name: String {
        didSet { UserDefaults.standard.set(name, forKey: RadioDJ.nameKey) }
    }
    /// The listener's own name, for the DJ to use (empty: none).
    var listenerName: String {
        didSet { UserDefaults.standard.set(listenerName, forKey: RadioDJ.listenerNameKey) }
    }
    private(set) var usage: RadioDJUsage
    private(set) var keyStatus: KeyStatus = .unchecked
    private(set) var openRouterKeyStatus: KeyStatus = .unchecked
    /// The conversation on the air (nil: off).
    private(set) var session: RadioDJSession?
    /// About a preview the DJ's words point to: being looked up, or not found.
    var previewNote: String?
    /// The album or artist page showing (nil on other pages): `id` tells pages apart, `subject` is read fresh.
    private(set) var page: (id: UUID, topic: RadioDJSubject, subject: () -> RadioDJSubject)?

    @ObservationIgnored private let usageURL: URL
    @ObservationIgnored let previewClient = ApplePreviewClient(country: Locale.current.region?.identifier ?? "US")
    /// Previews found (nil: Apple has none), by "title|artist".
    @ObservationIgnored var previewCache: [String: ApplePreviewTrack?] = [:]

    init(usageURL: URL = RadioDJStore.defaultUsageURL) {
        self.usageURL = usageURL
        apiKey = KeychainStore.app.string(for: RadioDJ.keyAccount) ?? ""
        openRouterKey = KeychainStore.app.string(for: RadioDJ.openRouterKeyAccount) ?? ""
        model = RadioDJModel.load()
        name = UserDefaults.standard.string(forKey: RadioDJ.nameKey) ?? ""
        listenerName = UserDefaults.standard.string(forKey: RadioDJ.listenerNameKey) ?? ""
        usage = RadioDJUsage.load(from: usageURL)
    }

    static var defaultUsageURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("MusicLibrary/radio-dj-usage.json")
    }

    private var trimmedKey: String { apiKey.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedOpenRouterKey: String { openRouterKey.trimmingCharacters(in: .whitespacesAndNewlines) }
    func hasKey(_ provider: RadioDJProvider) -> Bool {
        switch provider {
        case .anthropic: !trimmedKey.isEmpty
        case .openRouter: !trimmedOpenRouterKey.isEmpty
        }
    }
    /// On when the chosen model's provider has a key.
    var isEnabled: Bool { hasKey(model.provider) }

    private var client: any RadioDJClient {
        switch model.provider {
        case .anthropic: ClaudeClient(apiKey: trimmedKey)
        case .openRouter: OpenRouterClient(apiKey: trimmedOpenRouterKey, model: model)
        }
    }
    var displayName: String { RadioDJ.displayName(name) }

    /// For the phone: the keys (nil when removed, which turns the DJ off there too), the model and the name.
    var syncSettings: SyncRadioDJ {
        SyncRadioDJ(apiKey: trimmedKey.isEmpty ? nil : trimmedKey, name: displayName, listenerName: trimmedListenerName,
                    openRouterKey: trimmedOpenRouterKey.isEmpty ? nil : trimmedOpenRouterKey, model: model)
    }

    private var trimmedListenerName: String? {
        let name = listenerName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// `library`: the collection the DJ can search while talking; `linker`: links its words to what you own; `shop`:
    /// opens the Shop on an album (`open_shop`).
    func makeSession(_ subject: RadioDJSubject, library: RadioDJLibrary?, linker: RadioDJLinker?,
                     shop: (@MainActor (RadioDJShopRequest) async -> String)?) -> RadioDJSession {
        RadioDJSession(name: displayName, subject: subject, client: client, model: model, library: library,
                       linker: linker, listenerName: trimmedListenerName, wikipedia: WikipediaArticleFinder(),
                       shop: shop) { [weak self] tally in
            self?.record(tally)
        }
    }

    func begin(_ session: RadioDJSession) {
        self.session?.stop()
        self.session = session
        session.start()
    }

    func endSession() {
        session?.stop()
        session = nil
    }

    /// An album or artist page appeared.
    func showing(page id: UUID, subject: @escaping () -> RadioDJSubject) {
        page = (id, subject(), subject)
    }

    /// A page went away (another may already have taken its place).
    func left(page id: UUID) {
        if page?.id == id { page = nil }
    }

    /// Where you are in the app, read now: the album or artist page showing, else the page the sidebar shows
    /// (`AppModel.radioDJLocation`).
    @ObservationIgnored var location: () -> RadioDJSubject? = { nil }
    var here: RadioDJSubject? { location() }
    /// Which page you're on, cheaply (the album or artist page as it was when it appeared), for showing.
    var hereTopic: RadioDJSubject? { page?.topic ?? location() }

    private func record(_ tally: RadioDJTally) {
        usage.add(tally)
        usage.save(to: usageURL)
    }

    func checkKey(_ provider: RadioDJProvider) {
        guard hasKey(provider) else { return }
        let client: any RadioDJClient = provider == .anthropic ? ClaudeClient(apiKey: trimmedKey)
            : OpenRouterClient(apiKey: trimmedOpenRouterKey, model: model)
        setStatus(.checking, for: provider)
        Task {
            do {
                try await client.checkKey()
                setStatus(.valid, for: provider)
            } catch {
                setStatus(.invalid(error.localizedDescription), for: provider)
            }
        }
    }

    func keyStatus(_ provider: RadioDJProvider) -> KeyStatus {
        provider == .anthropic ? keyStatus : openRouterKeyStatus
    }

    private func setStatus(_ status: KeyStatus, for provider: RadioDJProvider) {
        if provider == .anthropic { keyStatus = status } else { openRouterKeyStatus = status }
    }

    /// Loads OpenRouter's models (again with `force`); the list is public, the key is sent when there is one.
    func loadOpenRouterModels(force: Bool = false) {
        guard !loadingOpenRouterModels, force || openRouterModels == nil else { return }
        loadingOpenRouterModels = true
        openRouterModelsError = nil
        let client = OpenRouterClient(apiKey: trimmedOpenRouterKey, model: model)
        Task {
            do {
                openRouterModels = try await client.models()
                // The chosen one with today's prices.
                if model.provider == .openRouter, let current = openRouterModels?.first(where: { $0.id == model.id }), current != model {
                    model = current
                }
            } catch {
                openRouterModelsError = error.localizedDescription
            }
            loadingOpenRouterModels = false
        }
    }
}

/// The DJ's symbol: a chat bubble with sparkles (an AI to talk with), or sparkles alone on systems without it.
enum RadioDJIcon {
    static let name = symbol("text.bubble.badge.sparkles")
    static func name(filled: Bool) -> String { filled ? symbol("text.bubble.badge.sparkles.fill") : name }

    private static func symbol(_ preferred: String) -> String {
        NSImage(systemSymbolName: preferred, accessibilityDescription: nil) != nil ? preferred : "sparkles"
    }
}

// MARK: Pages

extension View {
    /// Tells the Radio DJ about an album, artist or item page while it shows: what the DJ opens with when it's put on
    /// the air here, and what it hears about when you move here with it on. `subject` is read when needed.
    func radioDJ(_ subject: @escaping () -> RadioDJSubject) -> some View {
        modifier(RadioDJPageModifier(subject: subject))
    }
}

/// Tells the DJ an album, artist or item page is showing (the page's own details beat what the sidebar says).
private struct RadioDJPageModifier: ViewModifier {
    @Environment(AppModel.self) private var model
    let subject: () -> RadioDJSubject
    @State private var pageID = UUID()

    func body(content: Content) -> some View {
        content
            .onAppear { model.radioDJ.showing(page: pageID, subject: subject) }
            .onDisappear { model.radioDJ.left(page: pageID) }
    }
}

/// The DJ's button in the window's toolbar, on every page: puts the DJ on the air about where you are, or takes it
/// off.
struct RadioDJToolbarButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let dj = model.radioDJ
        Button {
            if dj.session == nil { model.startRadioDJ(model.radioDJLocation) } else { dj.endSession() }
        } label: {
            Label(dj.session == nil ? "On Air" : "Off Air", systemImage: RadioDJIcon.name(filled: dj.session != nil))
        }
        .help(dj.session == nil ? "Ask \(dj.displayName) about what you're looking at" : "Send \(dj.displayName) off the air")
    }
}

extension AppModel {
    /// Puts the DJ on the air about `subject`, with the collection to search and link to.
    func startRadioDJ(_ subject: RadioDJSubject) {
        let linker = RadioDJLinker(tracks: tracks, collection: collection, subject: subject)
        radioDJ.begin(radioDJ.makeSession(subject, library: radioDJLibrary, linker: linker) { [weak self] request in
            guard let self else { return "The app closed." }
            return await self.openShop(for: request)
        })
    }

    /// The DJ's `open_shop`: shows the Shop (the DJ stays on the air beside it) searching for the album.
    func openShop(for request: RadioDJShopRequest) async -> String {
        nowPlayingExpanded = false
        sidebar = .cdShop
        return await cdShop.find(request)
    }

    /// A link in the DJ's words: pages open as usual (the DJ stays on the air beside them); songs play in their album.
    func openRadioDJ(_ reference: RadioDJReference) {
        func albumOfTrack(_ id: Int64) -> (AlbumSummary, [Track])? {
            guard let track = trackByID[id] else { return nil }
            let key = SearchIndex.albumKey(album: track.album, artist: track.effectiveAlbumArtist)
            return album(forKey: key).map { ($0, tracks(ofAlbumKey: key)) }
        }
        func show(_ album: AlbumSummary) {
            nowPlayingExpanded = false
            navigationPath.append(album)
        }
        switch reference {
        case .artist(let name): showArtist(named: name)
        case .album(let key): if let found = album(forKey: key) { show(found) }
        case .item(let id): showItem(id: id)
        case .song(let id): if let (found, _) = albumOfTrack(id) { show(found) }
        case .play(let id):
            guard let (found, tracks) = albumOfTrack(id), let index = tracks.firstIndex(where: { $0.id == id }) else { return }
            player.play(queue: tracks, startAt: index, source: found.album)
        case .preview(let title, let artist):
            playRadioDJPreview(title: title, artist: artist)
        }
    }

    /// A song not in the collection: its Apple Music preview, found by searching Apple's catalog (once per song), or
    /// paused and resumed when it's the one playing.
    func playRadioDJPreview(title: String, artist: String?) {
        let dj = radioDJ
        let key = "\(title)|\(artist ?? "")"
        if let current = previews.current, case let cached?? = dj.previewCache[key], cached.id == current.id {
            previews.togglePlayPause()
            return
        }
        if let cached = dj.previewCache[key] {
            if let track = cached { previews.play([track]) } else { dj.previewNote = "Apple Music has no preview of “\(title)”." }
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
                previews.play([track])
            } else {
                let note = found == nil ? "Couldn't reach Apple Music for a preview." : "Apple Music has no preview of “\(title)”."
                dj.previewNote = note
                try? await Task.sleep(for: .seconds(5))
                if dj.previewNote == note { dj.previewNote = nil }
            }
        }
    }
}

/// The DJ's booth, a pane beside the window's pages that stays while you browse: who's on, what they're saying (with
/// the pages they checked), and a line to talk back, with photos to show (chosen, pasted or dropped on the pane: a
/// record in a shop, a shelf). On another album or artist page than the one being talked about, it offers to talk
/// about that one, and messages tell the DJ where you are.
struct RadioDJPanel: View {
    static let width: CGFloat = 370
    private static let bottom = "bottom"

    let session: RadioDJSession
    let dj: RadioDJStore
    let previews: PreviewPlayer
    let open: (RadioDJReference) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool
    /// Photos to send with the next message.
    @State private var photos: [RadioDJPhoto] = []
    @State private var photoNote: String?
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(session.lines) { line in
                            RadioDJLineView(line: line, segments: line.role == .dj ? session.segments(line) : [],
                                            speaking: session.activity == .speaking && line.id == session.lines.last?.id)
                                .id(line.id)
                        }
                        suggestionChips
                        if let status = statusText { RadioDJStatusRow(text: status).id("status") }
                        if let error = session.error { errorRow(error) }
                        Color.clear.frame(height: 1).id(Self.bottom)
                    }
                    .padding(16)
                }
                .defaultScrollAnchor(.bottom)
                .environment(\.openURL, OpenURLAction { url in
                    if let reference = RadioDJReference(url: url) { open(reference); return .handled }
                    return url.isWebLink ? .systemAction : .discarded
                })
                // Follow the conversation: your question, the status line, the reply as it streams in, an error.
                .onChange(of: session.scrollKey) { proxy.scrollTo(Self.bottom, anchor: .bottom) }
            }
            Divider()
            composer
        }
        .background(AppColor.background)
        .overlay(alignment: .leading) { Rectangle().fill(AppColor.separator).frame(width: 1) }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 8).strokeBorder(AppColor.accent, lineWidth: 3).padding(4).allowsHitTesting(false)
            }
        }
        .onDrop(of: [.image, .fileURL, .url], isTargeted: $dropTargeted) { providers in
            addDropped(providers)
            return true
        }
        .onPasteCommand(of: [.image, .fileURL]) { _ in pastePhoto() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            OnAirSign(live: session.isBusy)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.name).font(.headline).lineLimit(1)
                Text(RadioDJ.attributed(session.subject.headline)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Button { dj.endSession() } label: {
                Image(systemName: "xmark.circle.fill").font(.title3).symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Off the air")
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(AppColor.card.opacity(0.6))
    }

    /// The questions to start with, under the greeting (gone once one is asked, or when you've moved elsewhere,
    /// where "Tell me about…" takes over).
    @ViewBuilder
    private var suggestionChips: some View {
        if !session.suggestions.isEmpty, !session.isBusy, photos.isEmpty, !session.isElsewhere(dj.hereTopic) {
            FlowLayout(spacing: 6) {
                ForEach(session.suggestions, id: \.self) { question in
                    Button { session.send(question, page: dj.here) } label: {
                        Text(question)
                            .font(.callout)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().fill(AppColor.fill))
                            .overlay(Capsule().strokeBorder(AppColor.accent.opacity(question == session.suggestions.first ? 0.6 : 0), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help("Ask \(session.name) this")
                }
            }
        }
    }

    private var statusText: String? {
        switch session.activity {
        case .idle, .speaking: return nil
        case .warmingUp: return "Warming up the turntables…"
        case .searching(let q): return q.isEmpty ? "Digging through the crates…" : "Digging through the crates: “\(q)”"
        case .reading(let host): return host.isEmpty ? "Reading up…" : "Reading up on \(host)…"
        case .browsing(let q): return q.isEmpty ? "Flipping through your shelves…" : "Flipping through your shelves: \(q)"
        case .shopping(let album): return album.isEmpty ? "Heading to the record store…" : "Heading to the record store for \(album)…"
        }
    }

    private func errorRow(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(error, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
            Button("Try Again") { session.retry() }.controlSize(.small)
        }
    }

    @ViewBuilder
    private var previewRow: some View {
        if let note = dj.previewNote {
            Label(note, systemImage: "headphones").font(.caption).foregroundStyle(.secondary)
        } else if let track = previews.current, previews.isPlaying {
            HStack(spacing: 8) {
                Image(systemName: "headphones").foregroundStyle(AppColor.accent)
                Text("Preview: “\(track.title)” — \(track.artist)").font(.caption).lineLimit(1)
                Spacer(minLength: 0)
                Button("Stop") { previews.stop() }.controlSize(.small)
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            previewRow
            if let page = dj.hereTopic, session.isElsewhere(page), !session.isBusy {
                Button {
                    session.send("Tell me about this one.", page: dj.here)
                } label: {
                    Label { Text(RadioDJ.attributed("Tell me about \(page.headline)")).lineLimit(1) } icon: { Image(systemName: RadioDJIcon.name) }
                        .font(.callout)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(AppColor.fill))
                }
                .buttonStyle(.plain)
                .help("Ask \(session.name) about the page you're on")
            }
            attachedPhotos
            HStack(alignment: .bottom, spacing: 8) {
                Menu {
                    Button("Choose Photos…", action: choosePhotos)
                    Button("Paste Image", action: pastePhoto)
                } label: {
                    Image(systemName: "photo.badge.plus").font(.system(size: 19))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(canAddPhoto ? AnyShapeStyle(AppColor.accent) : AnyShapeStyle(.tertiary))
                .disabled(!canAddPhoto)
                .padding(.bottom, 6)
                .help(session.seesPhotos ? "Show \(session.name) a photo: a record or CD, its back or label, a shelf (or drop one on the panel)"
                      : "\(session.model.name) can't see photos. Pick another model in Settings ▸ Radio DJ.")
                TextField(photos.isEmpty ? "Ask \(session.name) anything…" : "Ask about \(photos.count == 1 ? "this photo" : "these photos")…",
                          text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .focused($focused)
                    .onSubmit { send() }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 16).fill(AppColor.fill))
                Button { send() } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 26))
                }
                .buttonStyle(.plain)
                .foregroundStyle(canSend ? AnyShapeStyle(AppColor.accent) : AnyShapeStyle(.tertiary))
                .disabled(!canSend)
                .help("Send")
            }
            Text("This segment: about \(DollarFormat.string(session.cost))")
                .font(.caption2).foregroundStyle(.secondary)
                .padding(.leading, 4)
        }
        .padding(12)
        .onAppear { focused = true }
    }

    private var canSend: Bool {
        !session.isBusy && (!photos.isEmpty || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    /// What's typed, or `question` (a chip about the photos).
    private func send(_ question: String? = nil) {
        guard !session.isBusy, question != nil || canSend else { return }
        session.send(question ?? draft, photos: photos, page: dj.here)
        draft = ""
        photos = []
        photoNote = nil
    }

    /// The photos going with the next message (each can be taken back), and questions to ask about them.
    @ViewBuilder
    private var attachedPhotos: some View {
        if let photoNote {
            Label(photoNote, systemImage: "photo").font(.caption).foregroundStyle(.secondary)
        }
        if !photos.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(photos) { photo in
                        RadioDJPhotoThumb(photo: photo, size: 64)
                            .overlay(alignment: .topTrailing) {
                                Button { photos.removeAll { $0.id == photo.id } } label: {
                                    Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, .black.opacity(0.6))
                                }
                                .buttonStyle(.plain)
                                .padding(3)
                                .help("Don't send this photo")
                            }
                    }
                }
            }
            if !session.isBusy {
                FlowLayout(spacing: 6) {
                    ForEach(session.photoQuestions(count: photos.count), id: \.self) { question in
                        Button { send(question) } label: {
                            Text(question).font(.callout)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(Capsule().fill(AppColor.fill))
                        }
                        .buttonStyle(.plain)
                        .help("Ask \(session.name) this about the photo")
                    }
                }
            }
        }
    }

    private func choosePhotos() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.message = "Choose photos to show \(session.name)"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { Task { await addPhoto(from: url) } }
    }

    private func pastePhoto() {
        switch ImageInput.pasted() {
        case .file(let url): Task { await addPhoto(from: url) }
        case .image(let data): Task { await addPhoto(data) }
        case nil: photoNote = "There's no image on the clipboard."
        }
    }

    /// Image data first (a picture dragged from Photos or a web page), else a file or a web image's address.
    private func addDropped(_ providers: [NSItemProvider]) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data else { return }
                    Task { @MainActor in await addPhoto(data) }
                }
            } else if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in await addPhoto(from: url) }
                }
            }
        }
    }

    private func addPhoto(from url: URL) async {
        switch await ImageInput.load(url) {
        case .success(let image): await addPhoto(image.data)
        case .failure(let failure): photoNote = failure.message
        }
    }

    private var canAddPhoto: Bool { session.seesPhotos && photos.count < RadioDJPhoto.maxPerMessage }

    /// Scaled and re-encoded off the main thread.
    private func addPhoto(_ data: Data) async {
        guard session.seesPhotos else {
            photoNote = "\(session.model.name) can't see photos. Pick another model in Settings ▸ Radio DJ."
            return
        }
        guard photos.count < RadioDJPhoto.maxPerMessage else {
            photoNote = "\(RadioDJPhoto.maxPerMessage) photos at a time."
            return
        }
        let photo = await Task.detached(priority: .userInitiated) { RadioDJPhoto(imageData: data) }.value
        guard let photo else { photoNote = "That isn't a photo \(session.name) can look at."; return }
        guard photos.count < RadioDJPhoto.maxPerMessage else { return }
        photoNote = nil
        photos.append(photo)
        focused = true
    }
}

/// A photo the listener showed (or is about to show) the DJ, cropped to a square.
struct RadioDJPhotoThumb: View {
    let photo: RadioDJPhoto
    let size: CGFloat

    var body: some View {
        Group {
            if let image = NSImage(data: photo.thumbnail) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.15), lineWidth: 1))
    }
}

private struct RadioDJLineView: View {
    let line: RadioDJSession.Line
    let segments: [RadioDJSegment]
    let speaking: Bool

    var body: some View {
        switch line.role {
        case .listener:
            VStack(alignment: .trailing, spacing: 6) {
                if !line.photos.isEmpty {
                    HStack(spacing: 6) {
                        Spacer(minLength: 40)
                        ForEach(line.photos) { RadioDJPhotoThumb(photo: $0, size: line.photos.count == 1 ? 160 : 72) }
                    }
                }
                HStack {
                    Spacer(minLength: 40)
                    Text(line.text)
                        .textSelection(.enabled)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 14).fill(AppColor.accent))
                }
            }
        case .dj:
            HStack(alignment: .top, spacing: 10) {
                DJAvatar(speaking: speaking)
                VStack(alignment: .leading, spacing: 10) {
                    // Not selectable: on the Mac, selectable text opens its links with the system, not `openURL`.
                    RadioDJText.text(segments, accent: AppColor.accent)
                        .font(.body)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .modifier(IconLinks())
                        .contextMenu {
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(RadioDJText.plain(segments), forType: .string)
                            }
                        }
                    if !line.sources.isEmpty {
                        FlowLayout(spacing: 6) {
                            ForEach(line.sources) { source in
                                Link(destination: source.url) {
                                    Label(source.host, systemImage: "link").font(.caption).lineLimit(1)
                                        .padding(.horizontal, 8).padding(.vertical, 3)
                                        .background(Capsule().fill(AppColor.fill))
                                }
                                .buttonStyle(.plain)
                                .help(source.title)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct RadioDJStatusRow: View {
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            EqualizerBars().frame(width: 28, height: 16)
            Text(text).font(.callout).italic().foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(.leading, 2)
    }
}

/// The red sign over the studio door, glowing while the DJ is talking or looking something up.
struct OnAirSign: View {
    let live: Bool

    var body: some View {
        Text("ON AIR")
            .font(.system(size: 10, weight: .heavy, design: .rounded))
            .tracking(1.5)
            .foregroundStyle(.white)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.red.gradient))
            .shadow(color: .red.opacity(live ? 0.8 : 0.25), radius: live ? 7 : 2)
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
    /// The light red at the top of the On Air sign's gradient.
    static let outside = Color(red: 1, green: 0.42, blue: 0.39)

    /// What the line says, without links (for Copy).
    static func plain(_ segments: [RadioDJSegment]) -> String {
        segments.map { segment in
            switch segment {
            case .text(let words), .play(let words), .preview(let words), .external(let words): String(words.characters)
            }
        }.joined()
    }

    static func text(_ segments: [RadioDJSegment], accent: Color) -> Text {
        segments.reduce(Text(verbatim: "")) { text, segment in
            switch segment {
            case .text(let words):
                return Text("\(text)\(words)")
            case .play(let title):
                let icon = linked(Text(Image(systemName: "play.circle.fill")).foregroundStyle(accent), to: title)
                return Text("\(text)\(icon)\u{202F}\(title)")
            case .preview(var title):
                // Not yours: a 30-second sample, in headphones rather than the play button, in the not-yours color.
                title.foregroundColor = outside
                let icon = linked(Text(Image(systemName: "headphones.circle")).foregroundStyle(outside), to: title)
                return Text("\(text)\(icon)\u{202F}\(title)")
            case .external(var title):
                // Not yours: opens a page on the web.
                title.foregroundColor = outside
                let icon = linked(Text(Image(systemName: "arrow.up.right.square")).font(.caption).foregroundStyle(outside), to: title)
                return Text("\(text)\(title)\u{202F}\(icon)")
            }
        }
    }

    /// An icon goes where its title's link does (`IconLinks`): a symbol in a `Text` can't carry a link itself.
    private static func linked(_ icon: Text, to title: AttributedString) -> Text {
        guard #available(macOS 15, *), let url = title.runs.first?.link else { return icon }
        return icon.customAttribute(IconLink(url: url))
    }
}

/// Where an icon's run in the DJ's text links to.
@available(macOS 15, *)
struct IconLink: TextAttribute {
    let url: URL
}

/// Makes the icons beside the DJ's links (play, preview, web page) clickable like the links: the text is drawn as
/// usual while noting where those icons are, and a click on one opens its link (with `openURL`, as the links do).
/// Before macOS 15 only the words are links.
struct IconLinks: ViewModifier {
    @Environment(\.openURL) private var openURL
    @State private var icons = IconLinkFrames()
    @State private var overIcon = false

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content
                .textRenderer(IconLinkRenderer(icons: icons))
                .simultaneousGesture(SpatialTapGesture().onEnded { tap in
                    if let url = icons.url(at: tap.location) { openURL(url) }
                })
                .onContinuousHover { phase in
                    // The pointing hand over an icon, as over a link; the cursor is left alone elsewhere (links set theirs).
                    var over = false
                    if case .active(let p) = phase { over = icons.url(at: p) != nil }
                    if over { NSCursor.pointingHand.set() } else if overIcon { NSCursor.arrow.set() }
                    overIcon = over
                }
        } else {
            content
        }
    }
}

/// The icons' frames as last drawn (a reference, so drawing doesn't update the view).
final class IconLinkFrames {
    var frames: [(rect: CGRect, url: URL)] = []

    func url(at point: CGPoint) -> URL? {
        frames.first { $0.rect.insetBy(dx: -2, dy: -2).contains(point) }?.url
    }
}

@available(macOS 15, *)
private struct IconLinkRenderer: TextRenderer {
    let icons: IconLinkFrames

    func draw(layout: Text.Layout, in ctx: inout GraphicsContext) {
        var frames: [(rect: CGRect, url: URL)] = []
        for line in layout {
            for run in line {
                if let link = run[IconLink.self] { frames.append((run.typographicBounds.rect, link.url)) }
                ctx.draw(run)
            }
        }
        icons.frames = frames
    }
}

// MARK: Settings

struct RadioDJSettings: View {
    @Environment(AppModel.self) private var model
    @State private var choosingModel = false

    var body: some View {
        @Bindable var dj = model.radioDJ
        Form {
            Section {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: RadioDJIcon.name).font(.system(size: 28)).foregroundStyle(.orange)
                    Text("Switch on a radio DJ on album and artist pages: they tell you the story behind the music, the people who made it and how it connects to everything else, and answer your questions, including about what's in your own collection and photos of records you show them. Powered by Claude, or any model on OpenRouter, looking things up on the web as they talk (only the rows a collection search finds are sent). Off until you add an API key; summon them on each page with On Air in the toolbar.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Section {
                keyField(dj, .anthropic, text: $dj.apiKey)
                Link("Get an API key at platform.claude.com", destination: URL(string: "https://platform.claude.com/settings/keys")!)
                    .font(.caption)
            } header: {
                Text("Claude API")
            }
            Section {
                keyField(dj, .openRouter, text: $dj.openRouterKey)
                Link("Get an API key at openrouter.ai", destination: URL(string: "https://openrouter.ai/settings/keys")!)
                    .font(.caption)
            } header: {
                Text("OpenRouter")
            } footer: {
                Text("Either key or both. Stored in your keychain and handed to your iPhone when you sync. Remove them to turn the DJ off on both.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            modelSection(dj)
            Section {
                TextField("DJ's name", text: $dj.name, prompt: Text(RadioDJ.defaultName))
                TextField("Your name", text: $dj.listenerName, prompt: Text("Optional"))
            } header: {
                Text("On the air")
            } footer: {
                Text("What the DJ calls themself, and what they call you (now and then, like a regular caller).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            spending(dj)
        }
        .formStyle(.grouped)
        .frame(height: 720)
        .sheet(isPresented: $choosingModel) { RadioDJModelPicker(dj: model.radioDJ) }
    }

    private func keyField(_ dj: RadioDJStore, _ provider: RadioDJProvider, text: Binding<String>) -> some View {
        Group {
            HStack {
                SecureField("API key", text: text)
                    .font(.system(.body, design: .monospaced))
                Button("Check") { dj.checkKey(provider) }
                    .disabled(!dj.hasKey(provider) || dj.keyStatus(provider) == .checking)
            }
            keyStatus(dj, provider)
        }
    }

    @ViewBuilder
    private func keyStatus(_ dj: RadioDJStore, _ provider: RadioDJProvider) -> some View {
        switch dj.keyStatus(provider) {
        case .unchecked:
            LabeledContent("Status") {
                Text(dj.hasKey(provider) ? "Ready (not checked yet)" : "No API key").foregroundStyle(.secondary)
            }
        case .checking:
            LabeledContent("Status") { HStack { ProgressView().controlSize(.small); Text("Checking…").foregroundStyle(.secondary) } }
        case .valid:
            LabeledContent("Status") { Label("The key works", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
        case .invalid(let message):
            LabeledContent("Status") { Label(message, systemImage: "exclamationmark.circle.fill").foregroundStyle(.orange) }
        }
    }

    private func modelSection(_ dj: RadioDJStore) -> some View {
        Section {
            LabeledContent("Model") {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(dj.model.name)
                    Text("\(dj.model.provider.name) · \(dj.model.id)").font(.caption).foregroundStyle(.secondary)
                }
            }
            LabeledContent("Price") { Text(dj.model.priceSummary).monospacedDigit().foregroundStyle(.secondary) }
            if !dj.model.acceptsImages {
                Label("This model can't see photos, so the DJ can't look at the records you show them.", systemImage: "eye.slash")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !dj.isEnabled {
                Label("Add \(dj.model.provider == .anthropic ? "a Claude API" : "an OpenRouter") key above, or choose a model from \(dj.model.provider == .anthropic ? "OpenRouter" : "Anthropic"), to switch the DJ on.",
                      systemImage: "exclamationmark.circle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                if dj.model != .default { Button("Use \(RadioDJModel.default.name)") { dj.model = .default } }
                Button("Choose Model…") { choosingModel = true }
            }
        } header: {
            Text("Model")
        } footer: {
            Text("Claude Opus 5.5 is the DJ the app was made with. Other models know music differently and may follow the app's links less closely. A new model takes over the next time the DJ comes on the air.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func spending(_ dj: RadioDJStore) -> some View {
        let phones = model.iPhone.phones.compactMap { phone in phone.radioDJUsage.map { (phone, $0) } }
        let month = phones.reduce(dj.usage.month()) { $0 + $1.1.month() }
        let all = phones.reduce(dj.usage.allTime) { $0 + $1.1.allTime }
        return Section {
            LabeledContent("This month") { Text(DollarFormat.string(month.dollars)).monospacedDigit().fontWeight(.semibold) }
            LabeledContent("All time") { Text(DollarFormat.string(all.dollars)).monospacedDigit() }
            if !phones.isEmpty {
                LabeledContent("This Mac") { amounts(dj.usage) }
                ForEach(phones, id: \.0.id) { phone, usage in
                    LabeledContent(phone.name) { amounts(usage) }
                }
            }
            LabeledContent("Segments") {
                Text("\(all.segments) on the air, \(all.webSearches) web search\(all.webSearches == 1 ? "" : "es")").foregroundStyle(.secondary)
            }
        } header: {
            Text("Spending")
        } footer: {
            Text("Calendar months (UTC). Claude API use is estimated at Anthropic's list prices (web searches $10 per 1,000); OpenRouter use is what OpenRouter says each reply cost. iPhone amounts are as of each phone's last sync. Your actual bills are at platform.claude.com and openrouter.ai.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func amounts(_ usage: RadioDJUsage) -> some View {
        Text("\(DollarFormat.string(usage.month().dollars)) this month · \(DollarFormat.string(usage.allTime.dollars)) in all")
            .monospacedDigit().foregroundStyle(.secondary)
    }
}

/// Picks the DJ's model: the Claude models it runs well on, or any of OpenRouter's that can use tools, with their prices.
struct RadioDJModelPicker: View {
    let dj: RadioDJStore
    @Environment(\.dismiss) private var dismiss
    @State private var provider: RadioDJProvider = .anthropic
    @State private var selection: RadioDJModel.ID?
    @State private var search = ""
    @State private var photosOnly = false
    @State private var sortOrder = [KeyPathComparator(\RadioDJModel.name, comparator: .localizedStandard)]

    private var models: [RadioDJModel] {
        let all = provider == .anthropic ? RadioDJModel.anthropic : (dj.openRouterModels ?? [])
        let words = search.split(separator: " ").map(String.init)
        let found = all.filter { model in
            (!photosOnly || model.acceptsImages)
                && words.allSatisfy { model.name.localizedStandardContains($0) || model.id.localizedStandardContains($0) }
        }
        // Anthropic's few in the app's order unless sorted otherwise.
        return provider == .anthropic && sortOrder.first?.keyPath == \RadioDJModel.name ? found : found.sorted(using: sortOrder)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose the DJ's Model").font(.headline)
            HStack {
                Picker("Provider", selection: $provider) {
                    ForEach(RadioDJProvider.allCases, id: \.self) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240)
                Spacer()
                Toggle("Sees photos", isOn: $photosOnly).toggleStyle(.checkbox)
                TextField("Search", text: $search).textFieldStyle(.roundedBorder).frame(width: 200)
            }
            if !dj.hasKey(provider) {
                Label("Add \(provider == .anthropic ? "a Claude API" : "an OpenRouter") key in Settings to use these.", systemImage: "key")
                    .font(.caption).foregroundStyle(.orange)
            }
            table
            HStack {
                if provider == .openRouter {
                    Button("Refresh") { dj.loadOpenRouterModels(force: true) }.disabled(dj.loadingOpenRouterModels)
                    Text("Prices per million tokens, from openrouter.ai.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Prices per million tokens; web searches $10 per 1,000.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Use Model") { choose() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen == nil)
            }
        }
        .padding(20)
        .frame(width: 760, height: 520)
        .onAppear {
            provider = dj.model.provider
            selection = dj.model.id
        }
        .onChange(of: provider) { if provider == .openRouter { dj.loadOpenRouterModels() } }
        .task { if dj.model.provider == .openRouter { dj.loadOpenRouterModels() } }
    }

    @ViewBuilder
    private var table: some View {
        if provider == .openRouter, dj.openRouterModels == nil {
            VStack(spacing: 10) {
                if let error = dj.openRouterModelsError {
                    Label(error, systemImage: "exclamationmark.circle.fill").foregroundStyle(.orange)
                    Button("Try Again") { dj.loadOpenRouterModels(force: true) }
                } else {
                    ProgressView()
                    Text("Loading OpenRouter's models…").foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Table(models, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Model", value: \.name, comparator: .localizedStandard) { model in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text(model.name)
                            if model.key == RadioDJModel.default.key { Text("Recommended").font(.caption2).foregroundStyle(.orange) }
                        }
                        Text(model.id).font(.caption).foregroundStyle(.secondary)
                    }
                }
                TableColumn("Input", value: \.inputPrice) { Text(RadioDJModel.price($0.inputPrice)).monospacedDigit() }
                    .width(70)
                TableColumn("Output", value: \.outputPrice) { Text(RadioDJModel.price($0.outputPrice)).monospacedDigit() }
                    .width(70)
                TableColumn("Context") { model in
                    Text(model.contextLength.map { $0 >= 1_000_000 ? "\($0 / 1_000_000)M" : "\($0 / 1_000)K" } ?? "—").monospacedDigit()
                }
                .width(60)
                TableColumn("Photos") { model in
                    Image(systemName: model.acceptsImages ? "checkmark" : "minus").foregroundStyle(model.acceptsImages ? .primary : .tertiary)
                }
                .width(50)
            }
            .contextMenu(forSelectionType: RadioDJModel.ID.self) { _ in } primaryAction: { ids in
                if let id = ids.first { selection = id; choose() }
            }
        }
    }

    private var chosen: RadioDJModel? {
        guard let selection else { return nil }
        return models.first { $0.id == selection }
    }

    private func choose() {
        guard let chosen else { return }
        dj.model = chosen
        dismiss()
    }
}

// MARK: What's on the page

extension AppModel {
    /// What the DJ's collection search reads, as it is now.
    var radioDJLibrary: RadioDJLibrary {
        RadioDJLibrary(index: index, collectionIndex: collectionIndex, collection: collection, playTotals: playTotals, likedDates: likedDates,
                       plays: (try? database?.plays()) ?? [], albumInfos: albumInfo.infos, currencyCode: currencyCode)
    }

    /// Where you are, for the DJ: the album, artist or item page showing, else what the sidebar shows (or the search).
    var radioDJLocation: RadioDJSubject {
        if let page = radioDJ.page { return page.subject() }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            return .page("search results for “\(query)”", details: ["The listener searched their collection for \(query); search_collection with the same query shows the results."])
        }
        switch sidebar {
        case .listenNow?:
            let album = listenNowAlbum
            let playing = player.currentTrack.map { "\($0.title) by \($0.artist)" }
            return .page("Listen Now, their home page", details: [
                playing.map { "Now playing: \($0)" } ?? "Nothing is playing.",
                album.map { "Leading the page: the album \($0.album) by \($0.artist)" } ?? "",
            ].filter { !$0.isEmpty })
        case .collection(let scope)?:
            let page = scope == .downloads ? "the Downloads list of their digital collection" : "the \(scope.title) page of their physical collection"
            return .page(page, details: ["\(collection.count(scope)) items here; \(collection.count(.cds)) CDs, \(collection.count(.vinyl)) records, \(collection.count(.downloads)) downloads in all"])
        case .songs?: return .page("the Songs list of their digital collection", details: ["\(tracks.count) songs"])
        case .albums?: return .page("the Albums grid of their digital collection", details: ["\(albums.count) albums"])
        case .artists?: return .page("the Artists list (both collections)", details: ["\(allArtists.count) artists"])
        case .insights?:
            let pane = UserDefaults.standard.string(forKey: "insightsPane") ?? "Owned"
            let period = UserDefaults.standard.string(forKey: "listeningPeriod") ?? ListeningStats.Period.month.rawValue
            let shown = pane == "Listening" ? "Listening, \(period)" : pane == "Library" ? "Digital Collection" : pane
            return .page("Insights (\(shown))", details: ["Their collection statistics; collection_stats has the numbers on screen."])
        case .musicDNA?:
            return .page("Music DNA" + (dnaCenter.map { ", centered on \($0)" } ?? ""),
                         details: ["A map of who played, wrote and produced with whom across their collection."])
        case .concerts?: return .page("the Concerts page", details: ["Upcoming concerts near them by artists in their collections."])
        case .likedSongs?: return .page("their Liked Songs", details: ["\(likedDates.count) liked songs"])
        case .playlist(let id)?:
            let playlist = playlists.first { $0.id == id }
            return .page("their playlist “\(playlist?.name ?? "Untitled")”", details: ["\(playlist?.trackCount ?? 0) songs"])
        case .smartPlaylist(let id)?:
            let playlist = smartPlaylists.first { $0.id == id }
            return .page("their smart playlist “\(playlist?.name ?? "Untitled")”", details: ["Songs matching \(playlist?.query ?? ""); search_collection with that query lists them."])
        case .importQueue?: return .page("the Import page")
        case .digitizeVinyl?: return .page("Digitize Vinyl, where they record their records")
        case .exportList?: return .page("the Export List")
        case .iPhone?: return .page("the iPhone sync page")
        case .iCloud?: return .page("the music they back up to iCloud")
        case .catalog?: return .page("their public library's CD catalog")
        case .catalogCheckouts?: return .page("their public library checkouts")
        case .catalogList?: return .page("their public library list")
        case .cdShop?: return cdShop.radioDJPage
        case .cd?: return .page("the page of the CD in the drive")
        case nil: return .page("Music Library")
        }
    }

    private func plays(_ tracks: [Track]) -> Int { tracks.reduce(0) { $0 + (playTotals[$1.id]?.plays ?? 0) } }
    private func liked(_ tracks: [Track]) -> Int { tracks.filter { likedDates[$0.id] != nil }.count }

    func radioDJSubject(album: AlbumSummary) -> RadioDJSubject {
        let tracks = tracks(of: album)
        return .album(album, tracks: tracks, info: albumInfo.info(for: album),
                      items: collection.copies(albumKey: AlbumInfoStore.key(album)), plays: plays(tracks), liked: liked(tracks))
    }

    func radioDJSubject(item: CollectionItem) -> RadioDJSubject {
        let tracks = tracks(ofAlbumKey: item.albumKey)
        return .item(item, tracks: tracks, info: albumInfo.infos[item.albumKey], plays: plays(tracks), liked: liked(tracks))
    }

    func radioDJSubject(artist name: String) -> RadioDJSubject {
        let tracks = tracks(ofArtist: name)
        let top = tracks.map { ($0, playTotals[$0.id]?.plays ?? 0) }.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }
            .prefix(5).map { "“\($0.0.title)” (\($0.1) plays)" }
        return .artist(name, info: artistInfo.info(for: name), albums: albums(forArtist: name), tracks: tracks,
                       items: collection.items(artist: name), plays: plays(tracks), topSongs: Array(top))
    }
}
