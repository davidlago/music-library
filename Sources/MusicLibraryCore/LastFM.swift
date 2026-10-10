import CryptoKit
import Foundation

public struct LastFMSession: Codable, Hashable, Sendable {
    public var key: String
    public var username: String
    public init(key: String, username: String) { self.key = key; self.username = username }
}

/// One listen, as sent to Last.fm.
public struct Scrobble: Codable, Hashable, Sendable, Identifiable {
    public var id: String { "\(timestamp)|\(artist)|\(track)" }
    public var artist: String
    public var track: String
    public var album: String
    public var albumArtist: String
    /// When the track started playing (UTC seconds).
    public var timestamp: Int
    public var duration: Int?
    public var trackNumber: Int?
    public var mbid: String?

    public init(artist: String, track: String, album: String = "", albumArtist: String = "", timestamp: Int,
                duration: Int? = nil, trackNumber: Int? = nil, mbid: String? = nil) {
        self.artist = artist; self.track = track; self.album = album; self.albumArtist = albumArtist
        self.timestamp = timestamp; self.duration = duration; self.trackNumber = trackNumber; self.mbid = mbid
    }

    public init(track t: Track, startedAt: Date) {
        self.init(artist: t.artist, track: t.title, album: t.album,
                  albumArtist: t.albumArtist == t.artist ? "" : t.albumArtist,
                  timestamp: Int(startedAt.timeIntervalSince1970),
                  duration: t.duration > 0 ? Int(t.duration.rounded()) : nil, trackNumber: t.trackNo,
                  mbid: t.metadata.mbRecordingId)
    }

    /// Last.fm needs at least an artist and a title.
    public var isSubmittable: Bool {
        !artist.trimmingCharacters(in: .whitespaces).isEmpty && !track.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// API parameters; `index` gives the `name[i]` form used for batch scrobbles.
    func parameters(index: Int? = nil, includeTimestamp: Bool = true) -> [String: String] {
        func key(_ k: String) -> String { index.map { "\(k)[\($0)]" } ?? k }
        var p = [key("artist"): artist, key("track"): track]
        if includeTimestamp { p[key("timestamp")] = String(timestamp) }
        if !album.isEmpty { p[key("album")] = album }
        if !albumArtist.isEmpty { p[key("albumArtist")] = albumArtist }
        if let duration { p[key("duration")] = String(duration) }
        if let trackNumber { p[key("trackNumber")] = String(trackNumber) }
        if let mbid, !mbid.isEmpty { p[key("mbid")] = mbid }
        return p
    }
}

public enum LastFMError: Error, LocalizedError, Equatable {
    case api(code: Int, message: String)
    case http(Int)
    case badResponse(String)
    case notConfigured

    public var errorDescription: String? {
        switch self {
        case .api(let code, let message): return "Last.fm error \(code): \(message)"
        case .http(let code): return "Last.fm returned HTTP \(code)"
        case .badResponse(let m): return "Unexpected Last.fm response: \(m)"
        case .notConfigured: return "Last.fm API key and secret are not set"
        }
    }

    /// Temporary problems: keep the scrobbles and try again later.
    public var isRetryable: Bool {
        switch self {
        case .api(let code, _): return [8, 11, 16, 29].contains(code)
        case .http(let code): return code == 0 || code == 429 || code >= 500
        case .badResponse: return true
        case .notConfigured: return false
        }
    }

    /// The session is gone (revoked or invalid): the user has to connect again.
    public var requiresReauthorization: Bool {
        if case .api(let code, _) = self { return [4, 9].contains(code) }
        return false
    }

    /// The API key or secret is wrong.
    public var isConfigurationError: Bool {
        if case .api(let code, _) = self { return [10, 13, 26].contains(code) }
        return self == .notConfigured
    }

    /// `auth.getSession` before the user approved the token in the browser.
    public var isUnauthorizedToken: Bool {
        if case .api(14, _) = self { return true }
        return false
    }
}

public struct ScrobbleResponse: Equatable, Sendable {
    public var accepted: Int
    public var ignored: Int
    public var ignoredMessages: [String]
}

/// Client for the Last.fm 2.0 API, covering desktop authentication, now playing and scrobbling.
public actor LastFMClient {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, Int)

    public static let endpoint = URL(string: "https://ws.audioscrobbler.com/2.0/")!
    public static let maxBatch = 50

    private let apiKey: String
    private let secret: String
    private let transport: Transport

    public init(apiKey: String, secret: String, transport: Transport? = nil) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.secret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        self.transport = transport ?? { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    public var isConfigured: Bool { !apiKey.isEmpty && !secret.isEmpty }

    /// md5 of the parameters sorted by name and concatenated as name+value, followed by the secret.
    /// `format` and `callback` are not signed.
    public static func signature(_ params: [String: String], secret: String) -> String {
        let payload = params.filter { $0.key != "format" && $0.key != "callback" }
            .sorted { $0.key < $1.key }
            .map { $0.key + $0.value }
            .joined() + secret
        return Insecure.MD5.hash(data: Data(payload.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func formEncode(_ params: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return params.sorted { $0.key < $1.key }.map { k, v in
            "\(k.addingPercentEncoding(withAllowedCharacters: allowed) ?? k)=\(v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v)"
        }.joined(separator: "&")
    }

    public static func authorizationURL(apiKey: String, token: String) -> URL {
        var c = URLComponents(string: "https://www.last.fm/api/auth/")!
        c.queryItems = [URLQueryItem(name: "api_key", value: apiKey), URLQueryItem(name: "token", value: token)]
        return c.url!
    }

    public func authorizationURL(token: String) -> URL { Self.authorizationURL(apiKey: apiKey, token: token) }

    private func call(_ method: String, _ params: [String: String], post: Bool) async throws -> [String: Any] {
        let data = try await send(method, params, post: post)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LastFMError.badResponse(String(decoding: data.prefix(200), as: UTF8.self))
        }
        return json
    }

    /// A signed GET returning the raw JSON, for parsers that live elsewhere.
    func rawCall(_ method: String, _ params: [String: String]) async throws -> Data {
        try await send(method, params, post: false)
    }

    private func send(_ method: String, _ params: [String: String], post: Bool) async throws -> Data {
        guard isConfigured else { throw LastFMError.notConfigured }
        var p = params
        p["method"] = method
        p["api_key"] = apiKey
        p["api_sig"] = Self.signature(p, secret: secret)
        p["format"] = "json"
        let body = Self.formEncode(p)
        var request: URLRequest
        if post {
            request = URLRequest(url: Self.endpoint)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(body.utf8)
        } else {
            request = URLRequest(url: URL(string: Self.endpoint.absoluteString + "?" + body)!)
        }
        request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, status) = try await transport(request)
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        // Errors come back as JSON, sometimes with a 4xx status.
        if let json, let code = json["error"] as? Int {
            throw LastFMError.api(code: code, message: json["message"] as? String ?? "")
        }
        guard status == 200 else { throw LastFMError.http(status) }
        return data
    }

    /// Step 1 of desktop auth: a token the user then approves at `authorizationURL(token:)`.
    public func getToken() async throws -> String {
        let json = try await call("auth.getToken", [:], post: false)
        guard let token = json["token"] as? String, !token.isEmpty else { throw LastFMError.badResponse("no token") }
        return token
    }

    /// Step 2: exchange an approved token for a session. Throws `isUnauthorizedToken` until the user approves.
    public func getSession(token: String) async throws -> LastFMSession {
        let json = try await call("auth.getSession", ["token": token], post: false)
        guard let s = json["session"] as? [String: Any], let key = s["key"] as? String, let name = s["name"] as? String else {
            throw LastFMError.badResponse("no session")
        }
        return LastFMSession(key: key, username: name)
    }

    public func updateNowPlaying(_ scrobble: Scrobble, sessionKey: String) async throws {
        var p = scrobble.parameters(includeTimestamp: false)
        p["sk"] = sessionKey
        _ = try await call("track.updateNowPlaying", p, post: true)
    }

    public func scrobble(_ batch: [Scrobble], sessionKey: String) async throws -> ScrobbleResponse {
        precondition(batch.count <= Self.maxBatch, "Last.fm accepts at most \(Self.maxBatch) scrobbles per request")
        var p: [String: String] = ["sk": sessionKey]
        for (i, s) in batch.enumerated() { p.merge(s.parameters(index: i)) { $1 } }
        let json = try await call("track.scrobble", p, post: true)
        return try Self.parseScrobbleResponse(json)
    }

    static func parseScrobbleResponse(_ json: [String: Any]) throws -> ScrobbleResponse {
        guard let root = json["scrobbles"] as? [String: Any] else { throw LastFMError.badResponse("no scrobbles") }
        let attr = root["@attr"] as? [String: Any] ?? [:]
        func int(_ v: Any?) -> Int { (v as? Int) ?? Int(v as? String ?? "") ?? 0 }
        // A single scrobble comes back as an object rather than a one-element array.
        let items = (root["scrobble"] as? [[String: Any]]) ?? ((root["scrobble"] as? [String: Any]).map { [$0] } ?? [])
        let messages = items.compactMap { item -> String? in
            guard let m = item["ignoredMessage"] as? [String: Any], int(m["code"]) != 0 else { return nil }
            return (m["#text"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Ignored (code \(int(m["code"])))"
        }
        return ScrobbleResponse(accepted: int(attr["accepted"]), ignored: int(attr["ignored"]), ignoredMessages: messages)
    }
}

// MARK: Scrobble rules

/// Tracks how much of one play was actually listened to, per Last.fm's rule: tracks over 30 seconds are
/// scrobbled once they've played for half their length or 4 minutes, whichever comes first. Skipping
/// around with seeks doesn't count as listening.
public struct ListenTracker: Sendable {
    public static let minimumDuration: Double = 30
    public static let maximumThreshold: Double = 240
    /// Gaps between position updates larger than this are treated as seeks.
    static let maxStep: Double = 2.5

    public let threshold: Double?
    public private(set) var listened: Double = 0
    public private(set) var hasScrobbled = false
    private var lastPosition: Double?

    public init(duration: Double) {
        threshold = duration > Self.minimumDuration ? min(duration / 2, Self.maximumThreshold) : nil
    }

    /// Feed the playback position on every tick. Returns true exactly once: when the play qualifies.
    public mutating func advance(to position: Double, playing: Bool) -> Bool {
        defer { lastPosition = position }
        guard playing, let last = lastPosition else { return false }
        let step = position - last
        if step > 0, step <= Self.maxStep { listened += step }
        guard !hasScrobbled, let threshold, listened >= threshold else { return false }
        hasScrobbled = true
        return true
    }
}

/// Scrobbles waiting to be sent, persisted as JSON so nothing is lost offline or across launches.
public final class ScrobbleQueue: @unchecked Sendable {
    /// Last.fm rejects scrobbles older than two weeks.
    public static let maxAge: TimeInterval = 14 * 86_400
    public static let capacity = 10_000

    private let url: URL
    private let lock = NSLock()
    private var items: [Scrobble]

    public init(url: URL) {
        self.url = url
        items = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([Scrobble].self, from: $0) } ?? []
    }

    public var pending: [Scrobble] { lock.withLock { items } }
    public var count: Int { lock.withLock { items.count } }

    public func append(_ s: Scrobble) {
        lock.withLock {
            guard !items.contains(where: { $0.id == s.id }) else { return }
            items.append(s)
            if items.count > Self.capacity { items.removeFirst(items.count - Self.capacity) }
            save()
        }
    }

    public func remove(_ ids: Set<String>) {
        lock.withLock {
            items.removeAll { ids.contains($0.id) }
            save()
        }
    }

    /// Drops scrobbles Last.fm would refuse for being too old; returns how many were dropped.
    @discardableResult
    public func dropExpired(now: Date = Date()) -> Int {
        lock.withLock {
            let cutoff = Int(now.timeIntervalSince1970 - Self.maxAge)
            let before = items.count
            items.removeAll { $0.timestamp < cutoff }
            if items.count != before { save() }
            return before - items.count
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(items).write(to: url, options: .atomic)
        } catch {
            // Keep the in-memory queue; the next change tries again.
        }
    }
}
