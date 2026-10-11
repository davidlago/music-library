import Foundation
import Testing
@testable import MusicLibraryCore

/// Records requests and replies with canned responses, in order.
final class StubTransport: @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [(String, Int)]
    private(set) var requests: [URLRequest] = []

    init(_ responses: [(String, Int)]) { self.responses = responses }

    var transport: LastFMClient.Transport {
        { request in
            self.lock.withLock {
                self.requests.append(request)
                let (body, status) = self.responses.isEmpty ? ("{}", 200) : self.responses.removeFirst()
                return (Data(body.utf8), status)
            }
        }
    }

    /// Form parameters of request `i`, from the body (POST) or the query (GET).
    func params(_ i: Int) -> [String: String] {
        let r = requests[i]
        let raw = r.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? r.url?.query ?? ""
        var out: [String: String] = [:]
        for pair in raw.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
            if kv.count == 2 { out[kv[0]] = kv[1] }
        }
        return out
    }
}

@Suite struct LastFMClientTests {
    @Test func signatureMatchesReferenceMD5() {
        // Expected values computed independently with `md5 -s`.
        #expect(LastFMClient.signature(["method": "auth.getSession", "token": "TOK456", "api_key": "KEY123", "format": "json"],
                                       secret: "SECRET789") == "9fe87f5c2f4e404c29a8241b312e989e")
        let p = ["api_key": "KEY", "method": "track.scrobble", "sk": "SK", "artist[0]": "Björk & Comét",
                 "track[0]": "Jóga?", "timestamp[0]": "1700000000", "callback": "x"]
        #expect(LastFMClient.signature(p, secret: "SECRET") == "486675992de74653b9b8a8b49eaebb84")
    }

    @Test func formEncodingEscapesReservedCharacters() {
        #expect(LastFMClient.formEncode(["track[0]": "A & B = C+D", "x": "ü"]) == "track%5B0%5D=A%20%26%20B%20%3D%20C%2BD&x=%C3%BC")
    }

    @Test func desktopAuthFlow() async throws {
        let stub = StubTransport([
            (#"{"token":"tok"}"#, 200),
            (#"{"error":14,"message":"Unauthorized Token - This token has not been authorized"}"#, 403),
            (#"{"session":{"name":"dave","key":"sk-1","subscriber":0}}"#, 200),
        ])
        let client = LastFMClient(apiKey: " key ", secret: "sec", transport: stub.transport)
        let token = try await client.getToken()
        #expect(token == "tok")
        #expect(await client.authorizationURL(token: token).absoluteString == "https://www.last.fm/api/auth/?api_key=key&token=tok")
        do {
            _ = try await client.getSession(token: token)
            Issue.record("expected unauthorized token")
        } catch let e as LastFMError {
            #expect(e.isUnauthorizedToken)
            #expect(!e.isRetryable)
        }
        let session = try await client.getSession(token: token)
        #expect(session == LastFMSession(key: "sk-1", username: "dave"))

        #expect(stub.requests[0].httpMethod == "GET")
        let p = stub.params(2)
        #expect(p["method"] == "auth.getSession" && p["token"] == "tok" && p["api_key"] == "key" && p["format"] == "json")
        var unsigned = p
        unsigned["api_sig"] = nil
        #expect(p["api_sig"] == LastFMClient.signature(unsigned, secret: "sec"))
    }

    @Test func scrobbleBatchParameters() async throws {
        let stub = StubTransport([(#"{"scrobbles":{"@attr":{"accepted":2,"ignored":0},"scrobble":[{},{}]}}"#, 200)])
        let client = LastFMClient(apiKey: "key", secret: "sec", transport: stub.transport)
        let batch = [
            Scrobble(artist: "Radiohead", track: "Airbag", album: "OK Computer", timestamp: 100, duration: 284, trackNumber: 1, mbid: "m1"),
            Scrobble(artist: "Miles Davis", track: "So What", timestamp: 200),
        ]
        let r = try await client.scrobble(batch, sessionKey: "sk")
        #expect(r.accepted == 2 && r.ignored == 0)
        let p = stub.params(0)
        #expect(stub.requests[0].httpMethod == "POST")
        #expect(p["method"] == "track.scrobble" && p["sk"] == "sk")
        #expect(p["artist[0]"] == "Radiohead" && p["track[0]"] == "Airbag" && p["album[0]"] == "OK Computer")
        #expect(p["timestamp[0]"] == "100" && p["duration[0]"] == "284" && p["trackNumber[0]"] == "1" && p["mbid[0]"] == "m1")
        #expect(p["artist[1]"] == "Miles Davis" && p["timestamp[1]"] == "200" && p["album[1]"] == nil)
    }

    @Test func nowPlayingHasNoTimestamp() async throws {
        let stub = StubTransport([(#"{"nowplaying":{}}"#, 200)])
        let client = LastFMClient(apiKey: "key", secret: "sec", transport: stub.transport)
        try await client.updateNowPlaying(Scrobble(artist: "A", track: "T", timestamp: 5), sessionKey: "sk")
        let p = stub.params(0)
        #expect(p["method"] == "track.updateNowPlaying" && p["artist"] == "A" && p["track"] == "T" && p["timestamp"] == nil)
    }

    @Test func errorsAreClassified() async {
        for (body, status, check) in [
            (#"{"error":9,"message":"Invalid session key"}"#, 403, { (e: LastFMError) in e.requiresReauthorization }),
            (#"{"error":11,"message":"Service Offline"}"#, 200, { $0.isRetryable }),
            (#"{"error":29,"message":"Rate limit exceeded"}"#, 200, { $0.isRetryable }),
            (#"{"error":10,"message":"Invalid API key"}"#, 403, { $0.isConfigurationError }),
            ("<html>bad gateway</html>", 502, { $0 == .http(502) && $0.isRetryable }),
        ] as [(String, Int, (LastFMError) -> Bool)] {
            let client = LastFMClient(apiKey: "k", secret: "s", transport: StubTransport([(body, status)]).transport)
            do {
                _ = try await client.getToken()
                Issue.record("expected an error for \(body)")
            } catch let e as LastFMError {
                #expect(check(e), "\(e)")
            } catch {
                Issue.record("unexpected \(error)")
            }
        }
        let unconfigured = LastFMClient(apiKey: "", secret: "")
        await #expect(throws: LastFMError.notConfigured) { _ = try await unconfigured.getToken() }
    }

    @Test func parsesSingleAndIgnoredScrobbles() throws {
        let single: [String: Any] = ["scrobbles": ["@attr": ["accepted": "0", "ignored": "1"],
                                                   "scrobble": ["ignoredMessage": ["code": "3", "#text": "Timestamp too old"]]]]
        let r = try LastFMClient.parseScrobbleResponse(single)
        #expect(r == ScrobbleResponse(accepted: 0, ignored: 1, ignoredMessages: ["Timestamp too old"]))
        #expect(throws: LastFMError.self) { try LastFMClient.parseScrobbleResponse([:]) }
    }

    @Test func scrobbleFromTrack() {
        let t = SearchFixtures.library[0]
        let s = Scrobble(track: t, startedAt: Date(timeIntervalSince1970: 1_700_000_000.7))
        #expect(s.artist == "Radiohead" && s.track == "Airbag" && s.album == "OK Computer" && s.albumArtist == "")
        #expect(s.timestamp == 1_700_000_000 && s.duration == 284 && s.trackNumber == 1 && s.mbid == "rec-1")
        let comp = Scrobble(track: SearchFixtures.library[7], startedAt: Date())
        #expect(comp.albumArtist == "Various Artists")
        #expect(!Scrobble(artist: " ", track: "x", timestamp: 0).isSubmittable)
    }
}

@Suite struct ListenTrackerTests {
    func play(_ tracker: inout ListenTracker, from: Double, to: Double, step: Double = 0.25, playing: Bool = true) -> Int {
        var fired = 0
        var t = from
        while t <= to + 0.0001 {
            if tracker.advance(to: t, playing: playing) { fired += 1 }
            t += step
        }
        return fired
    }

    @Test func halfwayForShortTracks() {
        var t = ListenTracker(duration: 200)
        #expect(t.threshold == 100)
        #expect(play(&t, from: 0, to: 99) == 0)
        #expect(play(&t, from: 99.25, to: 200) == 1)  // fires once, not again
    }

    @Test func fourMinutesForLongTracks() {
        var t = ListenTracker(duration: 1200)
        #expect(t.threshold == 240)
        #expect(play(&t, from: 0, to: 241) == 1)
    }

    @Test func tooShortNeverScrobbles() {
        var t = ListenTracker(duration: 30)
        #expect(t.threshold == nil)
        #expect(play(&t, from: 0, to: 30) == 0)
    }

    @Test func seeksAndPausesDontCount() {
        var t = ListenTracker(duration: 300)
        _ = play(&t, from: 0, to: 10)
        _ = t.advance(to: 200, playing: true)                       // seek forward
        #expect(t.listened < 11)
        _ = play(&t, from: 200, to: 260, playing: false)            // paused ticks
        #expect(t.listened < 11)
        #expect(play(&t, from: 200, to: 300) == 0)                  // ~110 s listened in total
        var u = ListenTracker(duration: 300)
        _ = play(&u, from: 0, to: 100)
        _ = u.advance(to: 20, playing: true)                        // seek back and re-listen: still counts
        #expect(play(&u, from: 20, to: 75) == 1)
    }
}

@Suite struct ScrobbleQueueTests {
    @Test func persistsDedupesAndExpires() throws {
        let url = try TestSupport.tempDir().appendingPathComponent("q/queue.json")
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let q = ScrobbleQueue(url: url)
        let fresh = Scrobble(artist: "A", track: "T", timestamp: Int(now.timeIntervalSince1970) - 60)
        let old = Scrobble(artist: "A", track: "Old", timestamp: Int(now.timeIntervalSince1970) - 15 * 86_400)
        q.append(fresh); q.append(fresh); q.append(old)
        #expect(q.count == 2)

        let reloaded = ScrobbleQueue(url: url)
        #expect(reloaded.pending == [fresh, old])
        #expect(reloaded.dropExpired(now: now) == 1)
        reloaded.remove([fresh.id])
        #expect(ScrobbleQueue(url: url).count == 0)
    }
}

@Suite struct ThemeTests {
    var palettes: [(String, ThemePalette)] {
        Theme.all.flatMap { t in [t.light, t.dark].compactMap { $0 }.map { (t.name, $0) } }
    }

    @Test func idsAreUniqueAndLookupFallsBack() {
        #expect(Set(Theme.all.map(\.id)).count == Theme.all.count)
        #expect(Theme.named("catppuccin-mocha").name == "Catppuccin Mocha")
        #expect(Theme.named("nope").isSystem)
        #expect(Theme.named(nil).isSystem)
        #expect(Theme.all.filter { $0.family == "Catppuccin" }.count == 5)
    }

    @Test func variantsMatchTheirAppearance() {
        for t in Theme.all {
            if let l = t.light { #expect(!l.isDark, "\(t.name)") }
            if let d = t.dark { #expect(d.isDark, "\(t.name)") }
        }
        let auto = Theme.named("catppuccin")
        #expect(auto.followsSystemAppearance && auto.forcedDark == nil)
        #expect(auto.palette(dark: true)?.base == RGB(0x1e1e2e))
        #expect(auto.palette(dark: false)?.base == RGB(0xeff1f5))
        #expect(Theme.named("nord").forcedDark == true)
        #expect(Theme.named("nord").palette(dark: false)?.isDark == true)
    }

    /// Every theme, including ones added later, must stay legible.
    @Test func everyPaletteIsLegible() {
        for (name, p) in palettes {
            for (bg, label) in [(p.base, "base"), (p.card, "card"), (p.mantle, "mantle")] {
                // WCAG AA for text; secondary text a hair below so the official palettes stay faithful.
                #expect(p.text.contrast(with: bg) >= 4.5, "\(name): text on \(label) \(p.text.contrast(with: bg))")
                #expect(p.subtext.contrast(with: bg) >= 4.3, "\(name): subtext on \(label) \(p.subtext.contrast(with: bg))")
            }
            #expect(p.series.contrast(with: p.card) >= 3, "\(name): chart series on card \(p.series.contrast(with: p.card))")
            #expect(p.accent.contrast(with: p.base) >= 3, "\(name): accent on base \(p.accent.contrast(with: p.base))")
            #expect(p.badgeText.contrast(with: p.badgeFill) >= 4.3, "\(name): badge \(p.badgeText.contrast(with: p.badgeFill))")
        }
    }

    @Test func ordinalRampIsMonotoneAndVisible() {
        for (name, p) in palettes {
            let ramp = p.ordinalRamp
            #expect(ramp.count == 4)
            #expect(ramp.first?.hex == p.series.hex)
            let contrasts = ramp.map { $0.contrast(with: p.card) }
            #expect(zip(contrasts, contrasts.dropFirst()).allSatisfy { $0 > $1 }, "\(name): \(contrasts)")
            #expect(contrasts.last! >= 2, "\(name): faintest step \(contrasts.last!)")
        }
    }

    @Test func colorMath() {
        #expect(RGB(0x1e66f5).hexString == "#1e66f5")
        #expect(RGB.black.mix(.white, 0.5).hex == 0x808080)
        #expect(abs(RGB.black.contrast(with: .white) - 21) < 0.001)
    }
}
