import AppKit
import Foundation
import MusicLibraryCore

/// Scrobbles what the player plays to Last.fm: connects the account through Last.fm's browser
/// authorization, sends "now playing" updates, and queues scrobbles so none are lost while offline.
@MainActor @Observable
final class Scrobbler {
    private enum Keys {
        static let apiKey = "lastfmAPIKey"
        static let secret = "lastfmSharedSecret"
        static let sessionKey = "lastfmSessionKey"
        static let username = "lastfmUsername"
        static let enabled = "lastfmScrobble"
        static let nowPlaying = "lastfmNowPlaying"
    }

    enum Status: Equatable {
        case notConfigured
        case disconnected
        case authorizing
        case connected(String)
        case needsReauthorization(String)
    }

    var apiKey: String { didSet { keychain.set(apiKey, for: Keys.apiKey); credentialsChanged() } }
    var sharedSecret: String { didSet { keychain.set(sharedSecret, for: Keys.secret); credentialsChanged() } }
    var scrobblingEnabled: Bool { didSet { UserDefaults.standard.set(scrobblingEnabled, forKey: Keys.enabled) } }
    var sendsNowPlaying: Bool { didSet { UserDefaults.standard.set(sendsNowPlaying, forKey: Keys.nowPlaying) } }

    private(set) var session: LastFMSession?
    private(set) var isAuthorizing = false
    private(set) var sessionInvalid = false
    private(set) var lastError: String?
    private(set) var pendingCount = 0
    private(set) var isSending = false
    /// Most recent first; only scrobbles sent during this run.
    private(set) var recent: [Scrobble] = []
    /// The track currently playing has been scrobbled.
    private(set) var currentPlayScrobbled = false

    @ObservationIgnored private let keychain = KeychainStore.app
    @ObservationIgnored private let queue: ScrobbleQueue
    @ObservationIgnored private var client: LastFMClient
    @ObservationIgnored private var tracker: ListenTracker?
    @ObservationIgnored private var currentPlay: (trackID: Int64, startedAt: Date)?
    @ObservationIgnored private var authTask: Task<Void, Never>?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var retryDelay: TimeInterval = 30
    @ObservationIgnored private(set) var pendingAuthURL: URL?

    var hasCredentials: Bool {
        !apiKey.trimmingCharacters(in: .whitespaces).isEmpty && !sharedSecret.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var status: Status {
        if !hasCredentials { return .notConfigured }
        if isAuthorizing { return .authorizing }
        guard let session else { return .disconnected }
        return sessionInvalid ? .needsReauthorization(session.username) : .connected(session.username)
    }

    var isActive: Bool {
        if case .connected = status { return scrobblingEnabled }
        return false
    }

    init(queueURL: URL = Scrobbler.defaultQueueURL) {
        let d = UserDefaults.standard
        let keychain = KeychainStore.app
        let storedKey = keychain.migratedString(for: Keys.apiKey, from: d, key: Keys.apiKey) ?? ""
        let storedSecret = keychain.migratedString(for: Keys.secret, from: d, key: Keys.secret) ?? ""
        apiKey = storedKey
        sharedSecret = storedSecret
        scrobblingEnabled = d.object(forKey: Keys.enabled) == nil ? true : d.bool(forKey: Keys.enabled)
        sendsNowPlaying = d.object(forKey: Keys.nowPlaying) == nil ? true : d.bool(forKey: Keys.nowPlaying)
        if let key = keychain.migratedString(for: Keys.sessionKey, from: d, key: Keys.sessionKey),
           let user = d.string(forKey: Keys.username) {
            session = LastFMSession(key: key, username: user)
        }
        queue = ScrobbleQueue(url: queueURL)
        client = LastFMClient(apiKey: storedKey, secret: storedSecret)
        queue.dropExpired()
        pendingCount = queue.count
        flush()
    }

    static var defaultQueueURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("MusicLibrary/lastfm-queue.json")
    }

    private func credentialsChanged() {
        client = LastFMClient(apiKey: apiKey, secret: sharedSecret)
        cancelAuthorization()
    }

    // MARK: Account

    /// Gets a token, opens Last.fm in the browser for the user to allow access, and waits for approval.
    func connect() {
        cancelAuthorization()
        lastError = nil
        isAuthorizing = true
        let client = client
        authTask = Task { [weak self] in
            do {
                let token = try await client.getToken()
                let url = await client.authorizationURL(token: token)
                guard let self, !Task.isCancelled else { return }
                self.pendingAuthURL = url
                NSWorkspace.shared.open(url)
                // Tokens are valid for 60 minutes; stop asking well before that.
                for _ in 0..<200 {
                    try await Task.sleep(for: .seconds(3))
                    do {
                        let session = try await client.getSession(token: token)
                        self.didConnect(session)
                        return
                    } catch let e as LastFMError where e.isUnauthorizedToken {
                        continue
                    }
                }
                self.lastError = "Timed out waiting for Last.fm authorization. Try connecting again."
                self.isAuthorizing = false
            } catch is CancellationError {
            } catch {
                self?.lastError = error.localizedDescription
                self?.isAuthorizing = false
            }
        }
    }

    func reopenAuthorizationPage() {
        if let pendingAuthURL { NSWorkspace.shared.open(pendingAuthURL) }
    }

    func cancelAuthorization() {
        authTask?.cancel()
        authTask = nil
        isAuthorizing = false
        pendingAuthURL = nil
    }

    private func didConnect(_ s: LastFMSession) {
        session = s
        sessionInvalid = false
        isAuthorizing = false
        pendingAuthURL = nil
        lastError = nil
        keychain.set(s.key, for: Keys.sessionKey)
        UserDefaults.standard.set(s.username, forKey: Keys.username)
        retryDelay = 30
        flush()
    }

    func disconnect() {
        cancelAuthorization()
        session = nil
        sessionInvalid = false
        keychain.remove(Keys.sessionKey)
        UserDefaults.standard.removeObject(forKey: Keys.username)
    }

    // MARK: Player events

    func trackStarted(_ track: Track) {
        tracker = ListenTracker(duration: track.duration)
        currentPlay = (track.id, Date())
        currentPlayScrobbled = false
        guard isActive, sendsNowPlaying, let key = session?.key else { return }
        let nowPlaying = Scrobble(track: track, startedAt: Date())
        guard nowPlaying.isSubmittable else { return }
        let client = client
        Task { [weak self] in
            do {
                try await client.updateNowPlaying(nowPlaying, sessionKey: key)
            } catch let e as LastFMError {
                self?.handleAccountError(e)
            } catch {}
        }
    }

    func progress(_ track: Track, position: Double, playing: Bool) {
        guard let play = currentPlay, play.trackID == track.id, tracker != nil else { return }
        guard tracker!.advance(to: position, playing: playing) else { return }
        currentPlayScrobbled = true
        // Plays are kept while the account waits for a reconnect.
        guard scrobblingEnabled, session != nil else { return }
        let scrobble = Scrobble(track: track, startedAt: play.startedAt)
        guard scrobble.isSubmittable else { return }
        queue.append(scrobble)
        pendingCount = queue.count
        flush()
    }

    // MARK: Sending

    /// Sends queued scrobbles in batches; temporary failures are retried with backoff.
    func flush() {
        guard !isSending, !sessionInvalid, hasCredentials, let key = session?.key else { return }
        queue.dropExpired()
        let batch = Array(queue.pending.prefix(LastFMClient.maxBatch))
        pendingCount = queue.count
        guard !batch.isEmpty else { return }
        isSending = true
        retryTask?.cancel()
        let client = client
        Task { [weak self] in
            do {
                let response = try await client.scrobble(batch, sessionKey: key)
                guard let self else { return }
                self.queue.remove(Set(batch.map(\.id)))
                self.recent.insert(contentsOf: batch.reversed(), at: 0)
                if self.recent.count > 20 { self.recent.removeLast(self.recent.count - 20) }
                self.lastError = response.ignoredMessages.first.map { "Last.fm ignored a scrobble: \($0)" }
                self.retryDelay = 30
                self.isSending = false
                self.pendingCount = self.queue.count
                if self.pendingCount > 0 { self.flush() }
            } catch {
                guard let self else { return }
                self.isSending = false
                let e = error as? LastFMError ?? .http(0)
                if e.isRetryable {
                    self.lastError = "Couldn't reach Last.fm (\(error.localizedDescription)); will retry."
                    self.scheduleRetry()
                } else if e.requiresReauthorization || e.isConfigurationError {
                    self.handleAccountError(e)
                } else {
                    // A request Last.fm will never accept; drop it rather than block the queue.
                    self.queue.remove(Set(batch.map(\.id)))
                    self.pendingCount = self.queue.count
                    self.lastError = error.localizedDescription
                }
            }
        }
    }

    private func scheduleRetry() {
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 15 * 60)
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    private func handleAccountError(_ e: LastFMError) {
        if e.requiresReauthorization {
            sessionInvalid = true
            lastError = "Last.fm no longer accepts this session. Connect again to resume scrobbling; plays are kept until then."
        } else if e.isConfigurationError {
            lastError = "Last.fm rejected the API key or secret: \(e.localizedDescription)"
        }
    }
}
