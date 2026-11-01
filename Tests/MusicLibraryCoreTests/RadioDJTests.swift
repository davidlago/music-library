import Foundation
import Network
import Testing
@testable import MusicLibraryCore

/// Plays back scripted SSE responses (or errors) and records the requests.
final class ScriptedClaudeTransport: ClaudeTransport, @unchecked Sendable {
    enum Reply { case lines([String]), failure(ClaudeError), status(Int, String) }

    private let lock = NSLock()
    private var replies: [Reply]
    private(set) var requests: [URLRequest] = []

    init(_ replies: [Reply]) { self.replies = replies }

    var bodies: [JSONValue] {
        lock.withLock { requests.compactMap { $0.httpBody.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) } } }
    }

    func lines(for request: URLRequest) async throws -> AsyncThrowingStream<String, Error> {
        let reply: Reply = lock.withLock {
            requests.append(request)
            return replies.isEmpty ? .failure(.api("no more replies")) : replies.removeFirst()
        }
        switch reply {
        case .failure(let error): throw error
        case .status(let status, let body): throw HTTPStatusError(status: status, body: Data(body.utf8))
        case .lines(let lines):
            return AsyncThrowingStream { c in
                for line in lines { c.yield(line) }
                c.finish()
            }
        }
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { requests.append(request) }
        return (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

/// SSE lines for a simple text reply.
func sse(_ events: [String]) -> [String] { events.flatMap { ["data: \($0)", ""] } }

func textReply(_ text: String, stop: String = "end_turn", model: String = "claude-opus-5-5", input: Int = 100, output: Int = 20) -> [String] {
    let escaped = String(data: try! JSONEncoder().encode(text), encoding: .utf8)!
    return sse([
        #"{"type":"message_start","message":{"id":"msg_1","model":"\#(model)","usage":{"input_tokens":\#(input),"output_tokens":1}}}"#,
        #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
        #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig-1"}}"#,
        #"{"type":"content_block_stop","index":0}"#,
        #"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#,
        #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":\#(escaped)}}"#,
        #"{"type":"content_block_stop","index":1}"#,
        #"{"type":"message_delta","delta":{"stop_reason":"\#(stop)"},"usage":{"output_tokens":\#(output)}}"#,
        #"{"type":"message_stop"}"#,
    ])
}

@Suite struct ClaudeStreamTests {
    @Test func accumulatesBlocksToSendBackUnchanged() throws {
        var reply = ClaudeStreamAccumulator()
        var events: [ClaudeStreamEvent] = []
        let lines = sse([
            #"{"type":"message_start","message":{"model":"claude-opus-5-5","usage":{"input_tokens":1200,"cache_read_input_tokens":800,"output_tokens":1}}}"#,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":""}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"EqQBCkYIBxgCKkA"}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"content_block_start","index":1,"content_block":{"type":"server_tool_use","id":"srvtoolu_1","name":"web_search","input":{}}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"query\": \"Kind of"}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":" Blue sessions\"}"}}"#,
            #"{"type":"content_block_stop","index":1}"#,
            #"{"type":"content_block_start","index":2,"content_block":{"type":"web_search_tool_result","tool_use_id":"srvtoolu_1","content":[{"type":"web_search_result","url":"https://example.com/kob","title":"KoB","encrypted_content":"abc","page_age":null}]}}"#,
            #"{"type":"content_block_stop","index":2}"#,
            #"{"type":"content_block_start","index":3,"content_block":{"type":"text","text":""}}"#,
            #"{"type":"content_block_delta","index":3,"delta":{"type":"text_delta","text":"Recorded in two "}}"#,
            #"{"type":"content_block_delta","index":3,"delta":{"type":"citations_delta","citation":{"type":"web_search_result_location","url":"https://example.com/kob","title":"KoB","encrypted_index":"x","cited_text":"..."}}}"#,
            #"{"type":"content_block_delta","index":3,"delta":{"type":"text_delta","text":"sessions in 1959."}}"#,
            #"{"type":"content_block_stop","index":3}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":321,"server_tool_use":{"web_search_requests":1}}}"#,
        ])
        for line in lines where line.hasPrefix("data: ") { events += reply.handle(data: String(line.dropFirst(6))) }

        #expect(events == [.toolStarted(name: "web_search"), .toolInput(name: "web_search", input: .object(["query": .string("Kind of Blue sessions")])),
                           .text("Recorded in two "), .text("sessions in 1959.")])
        #expect(reply.text == "Recorded in two sessions in 1959.")
        #expect(reply.stopReason == "end_turn")
        #expect(reply.model == "claude-opus-5-5")
        let content = reply.content
        #expect(content.count == 4)
        #expect(content[0]["signature"]?.string == "EqQBCkYIBxgCKkA")
        #expect(content[0]["thinking"]?.string == "")
        #expect(content[1]["input"]?["query"]?.string == "Kind of Blue sessions")
        #expect(content[2]["content"]?.array?.first?["encrypted_content"]?.string == "abc")
        #expect(content[3]["citations"]?.array?.count == 1)
        #expect(reply.usage["input_tokens"]?.int == 1200)
        #expect(reply.usage["output_tokens"]?.int == 321)
        #expect(reply.usage["server_tool_use"]?["web_search_requests"]?.int == 1)
    }

    @Test func streamErrorsSurface() {
        var reply = ClaudeStreamAccumulator()
        _ = reply.handle(data: #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#)
        #expect(reply.error == .overloaded)
    }

    @Test func jsonKeepsWholeNumbersWhole() throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"a":3,"b":1.5,"c":[true,null,"x"]}"#.utf8))
        let encoded = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        #expect(encoded.contains(#""a":3"#))
        #expect(encoded.contains(#""b":1.5"#))
        #expect(try JSONDecoder().decode(JSONValue.self, from: Data(encoded.utf8)) == value)
    }

    @Test func requestShape() throws {
        let request = ClaudeRequest(model: RadioDJ.model, maxTokens: RadioDJ.maxTokens, system: ["persona", "context"],
                                    messages: [.user("hi")], tools: RadioDJ.tools)
        let body = try JSONDecoder().decode(JSONValue.self, from: try request.body())
        #expect(body["model"]?.string == "claude-opus-5-5")
        #expect(body["stream"] == .bool(true))
        #expect(body["fallbacks"]?.string == "default")
        #expect(body["cache_control"]?["type"]?.string == "ephemeral")
        #expect(body["system"]?.array?.count == 2)
        #expect(body["thinking"] == nil)
        #expect(body["temperature"] == nil)
        #expect(body["tools"]?.array?.compactMap { $0["name"]?.string } == ["web_search", "web_fetch"])
        let http = ClaudeAPI.request(ClaudeAPI.messagesURL, apiKey: "sk-test", body: Data(), beta: [ClaudeAPI.fallbackBeta])
        #expect(http.value(forHTTPHeaderField: "x-api-key") == "sk-test")
        #expect(http.value(forHTTPHeaderField: "anthropic-version") == "2026-10-21")
        #expect(http.value(forHTTPHeaderField: "anthropic-beta") == "server-side-fallback-2026-07-01")
        #expect(http.httpMethod == "POST")
    }

    @Test func httpErrorsReadAsMessages() {
        let body = Data(#"{"type":"error","error":{"type":"invalid_request_error","message":"bad thing"}}"#.utf8)
        #expect(ClaudeAPI.describe(status: 400, body: body) == .api("bad thing"))
        #expect(ClaudeAPI.describe(status: 401, body: body) == .unauthorized)
        #expect(ClaudeAPI.describe(status: 529, body: Data()) == .overloaded)
    }
}

@Suite struct RadioDJBillingTests {
    @Test func pricesAResponse() {
        let usage: [String: JSONValue] = ["input_tokens": .number(10_000), "output_tokens": .number(1_000),
                                          "cache_read_input_tokens": .number(100_000), "cache_creation_input_tokens": .number(4_000),
                                          "server_tool_use": .object(["web_search_requests": .number(2)])]
        let tally = RadioDJTally.billing(usage: usage, requestedModel: "claude-opus-5-5", servedModel: "claude-opus-5-5")
        // 10k × $4 + 1k × $20 + 100k × $0.20 + 4k × $5 per million, plus 2 searches at a cent.
        #expect(abs(tally.dollars - (0.04 + 0.02 + 0.02 + 0.02 + 0.02)) < 1e-9)
        #expect(tally.webSearches == 2)
        #expect(tally.requests == 1)
    }

    @Test func fallbackAttemptsBillAtTheirOwnRates() {
        let usage: [String: JSONValue] = [
            "input_tokens": .number(1_000_000), "output_tokens": .number(0),
            "iterations": .array([
                .object(["type": .string("message"), "input_tokens": .number(1_000_000), "output_tokens": .number(0)]),
                .object(["type": .string("fallback_message"), "input_tokens": .number(1_000_000), "output_tokens": .number(0)]),
            ]),
        ]
        let tally = RadioDJTally.billing(usage: usage, requestedModel: "claude-opus-5-5", servedModel: "claude-opus-4-8")
        #expect(abs(tally.dollars - 9) < 1e-9) // $4 on Opus 5.5, then $5 on Opus 4.8
        #expect(tally.inputTokens == 2_000_000)
    }

    @Test func usageAddsUpPerMonth() throws {
        var usage = RadioDJUsage()
        var a = RadioDJTally(); a.dollars = 1.25; a.segments = 1
        var b = RadioDJTally(); b.dollars = 0.5
        let october = Date(timeIntervalSince1970: 1_792_000_000) // 2026-10
        let november = october.addingTimeInterval(40 * 86_400)
        usage.add(a, at: october)
        usage.add(b, at: october)
        usage.add(b, at: november)
        #expect(usage.month(october).dollars == 1.75)
        #expect(usage.month(november).dollars == 0.5)
        #expect(usage.allTime.dollars == 2.25)
        // Calendar months in UTC: the last minute of October and the first of November are apart.
        let endOfOctober = Date(timeIntervalSince1970: 1_793_491_140) // 2026-10-31 23:59 UTC
        #expect(RadioDJUsage.monthKey(endOfOctober) == "2026-10")
        #expect(RadioDJUsage.monthKey(endOfOctober.addingTimeInterval(120)) == "2026-11")
        #expect(usage.allTime.segments == 1)
        let url = try TestSupport.tempDir().appendingPathComponent("usage.json")
        usage.save(to: url)
        #expect(RadioDJUsage.load(from: url) == usage)
        #expect(DollarFormat.string(0.004) == "< $0.01")
        #expect(DollarFormat.string(12.3) == "$12.30")
    }

    @Test func names() {
        #expect(RadioDJ.displayName(nil) == RadioDJ.defaultName)
        #expect(RadioDJ.displayName("  ") == RadioDJ.defaultName)
        #expect(RadioDJ.displayName(" Wolfman ") == "Wolfman")
        #expect(RadioDJ.persona(name: "Wolfman").contains("You are Wolfman"))
    }
}

@Suite struct RadioDJSubjectTests {
    @Test func albumContextCarriesWhatTheAppKnows() {
        var meta = TrackMetadata()
        meta.title = "So What"; meta.artist = "Miles Davis"; meta.album = "Kind of Blue"; meta.trackNo = 1; meta.genre = "Jazz"
        meta.extended.label = "Columbia"
        meta.extended.credits = [Credit(role: "instrument", name: "John Coltrane", attributes: ["tenor saxophone"], scope: .recording)]
        let track = Track(id: 1, path: "Music/a.flac", metadata: meta, duration: 562, format: "flac", sha256: "x", addedAt: Date(timeIntervalSince1970: 0))
        var info = AlbumInfo(title: "Kind of Blue")
        info.firstReleaseDate = "1959-08-17"
        info.description = "The best-selling jazz record."
        let album = AlbumSummary(album: "Kind of Blue", artist: "Miles Davis", year: 1959, trackCount: 1, firstTrackPath: track.path)
        let subject = RadioDJSubject.album(album, tracks: [track], info: info, plays: 42, liked: 1)
        let context = subject.context
        #expect(subject.headline == "*Kind of Blue* by Miles Davis")
        #expect(context.contains("First released: 1959-08-17"))
        #expect(context.contains("Label: Columbia"))
        #expect(context.contains("John Coltrane"))
        #expect(context.contains("1. So What [9:22]"))
        #expect(context.contains("Played 42 times"))
        #expect(context.contains("The best-selling jazz record."))
        #expect(RadioDJ.opener(subject).contains("album page for *Kind of Blue* by Miles Davis"))
    }

    @Test func artistContext() {
        var info = ArtistInfo(name: "Nina Simone")
        info.bio = "Singer, pianist, activist."
        let subject = RadioDJSubject.artist("Nina Simone", info: info, albums: [], tracks: [], plays: 3, topSongs: ["“Sinnerman” (3 plays)"])
        #expect(subject.kind == .artist)
        #expect(subject.context.contains("Singer, pianist, activist."))
        #expect(subject.context.contains("Sinnerman"))
    }
}

@MainActor @Suite struct RadioDJSessionTests {
    let subject = RadioDJSubject(kind: .album, title: "Blue", artist: "Joni Mitchell")

    func waitIdle(_ session: RadioDJSession) async {
        for _ in 0..<200 where session.isBusy || session.lines.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        for _ in 0..<200 where session.isBusy { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func greetsWithSuggestionsThenTalksAndResumesPausedTurns() async throws {
        let transport = ScriptedClaudeTransport([
            .lines(textReply("The story of Blue.")),
            .lines(textReply("this is Max.", stop: "pause_turn")),
            .lines(textReply(" On with the show.")),
        ])
        var tallies: [RadioDJTally] = []
        let session = RadioDJSession(name: "Max", subject: subject, client: ClaudeClient(apiKey: "k", transport: transport)) { tallies.append($0) }
        session.start()
        // Going on the air costs nothing: the app greets and suggests questions.
        #expect(transport.bodies.isEmpty && tallies.isEmpty && !session.isBusy)
        #expect(session.lines.count == 1 && session.lines.first?.role == .dj)
        #expect(session.lines.first?.text.contains("Max here, on the air with [Blue](album) by [Joni Mitchell](artist) on the turntable.") == true)
        #expect(session.suggestions.first == "Tell me about Blue")

        session.send(session.suggestions[0])
        await waitIdle(session)
        #expect(session.suggestions.isEmpty)
        #expect(Array(session.lines.map(\.text).dropFirst()) == ["Tell me about Blue", "The story of Blue."])

        session.send("Who played on it?")
        await waitIdle(session)
        #expect(session.lines.map(\.role) == [.dj, .listener, .dj, .listener, .dj])
        #expect(session.lines.last?.text == "this is Max. On with the show.")
        #expect(session.error == nil)

        let bodies = transport.bodies
        #expect(bodies.count == 3)
        // The first question carries where the DJ came on; the reply (thinking block with its signature) goes back unchanged.
        let second = try #require(bodies[1]["messages"]?.array)
        #expect(second.count == 3)
        let first = try #require(second[0]["content"]?.array?.first?["text"]?.string)
        #expect(first.hasPrefix("(The listener just switched you on from the album page for *Blue* by Joni Mitchell.") && first.hasSuffix("\n\nTell me about Blue"))
        #expect(second[1]["content"]?.array?.first?["signature"]?.string == "sig-1")
        #expect(second[2]["content"]?.array?.first?["text"]?.string == "Who played on it?")
        // The paused turn is resumed by sending its partial reply back, with no new user message.
        let third = try #require(bodies[2]["messages"]?.array)
        #expect(third.count == 4)
        #expect(third[3]["role"]?.string == "assistant")
        #expect(bodies[2]["system"]?.array?.first?["text"]?.string?.contains("You are Max") == true)

        #expect(tallies.first?.segments == 1 && tallies.filter { $0.segments == 1 }.count == 1)
        #expect(tallies.filter { $0.requests == 1 }.count == 3)
        #expect(session.cost > 0)
    }

    @Test func failedQuestionsRollBackAndRetry() async throws {
        let transport = ScriptedClaudeTransport([
            .failure(.overloaded),
            .lines(textReply("Here's the story.")),
            .lines(textReply("", stop: "refusal")),
        ])
        let session = RadioDJSession(name: "Max", subject: subject, client: ClaudeClient(apiKey: "k", transport: transport)) { _ in }
        session.start()
        session.send("Tell me more")
        await waitIdle(session)
        #expect(session.error == ClaudeError.overloaded.localizedDescription)
        #expect(session.lines.map(\.role) == [.dj, .listener])

        session.retry()
        await waitIdle(session)
        #expect(session.error == nil)
        #expect(Array(session.lines.map(\.text).dropFirst()) == ["Tell me more", "Here's the story."])
        // The retry sent the question once, still with the opener.
        let retried = try #require(transport.bodies[1]["messages"]?.array)
        #expect(retried.count == 1 && retried[0]["content"]?.array?.first?["text"]?.string?.hasPrefix("(The listener just switched you on") == true)

        session.send("Something it won't answer")
        await waitIdle(session)
        #expect(session.error == ClaudeError.refused.localizedDescription)
        // The refused question isn't in the conversation any more.
        session.retry()
        await waitIdle(session)
        let last = try #require(transport.bodies.last?["messages"]?.array)
        #expect(last.count == 3)
    }
}

@Suite(.serialized) struct RadioDJSyncTests {
    actor Box {
        var settings: SyncRadioDJ?
        func set(_ s: SyncRadioDJ) { settings = s }
    }

    @Test func theMacHandsOverTheDJAndHearsWhatItCost() async throws {
        let f = try SyncFixture()
        let key = SyncPairing.newKey()
        let phoneRoot = try TestSupport.tempDir().appendingPathComponent("Music Library")
        let scratch = try TestSupport.tempDir()
        var spent = RadioDJUsage()
        var tally = RadioDJTally(); tally.dollars = 0.37; tally.segments = 2
        spent.add(tally)
        let received = Box()

        let sessions = AsyncStream<NWConnection>.makeStream()
        let advertiser = try await TestSupport.listeningAdvertiser(key: key) { sessions.continuation.yield($0) }
        let identity = SyncIdentity(deviceID: "phone-id", deviceName: "iPhone", appVersion: "test")
        let usage = spent
        let session = Task { () async throws -> SyncSummary in
            defer { advertiser.stop() }
            for await connection in sessions.stream {
                return try await SyncPhoneSession.run(SyncConnection(connection), identity: identity, root: phoneRoot, freeSpace: nil,
                                                      pairing: false, radioDJUsage: usage, storeGrant: { _ in },
                                                      storeRadioDJ: { await received.set($0) }).summary
            }
            throw SyncError.connection("no session")
        }
        let mac = SyncIdentity(deviceID: "mac-id", deviceName: "Mac", appVersion: "test")
        let model = RadioDJModel(provider: .openRouter, id: "openai/gpt-5.2", name: "OpenAI: GPT-5.2", inputPrice: 1.75, outputPrice: 14)
        let settings = SyncRadioDJ(apiKey: "sk-ant-test", name: "Wolfman", listenerName: "Dave", openRouterKey: "sk-or-test", model: model)
        let (phone, _) = try await SyncMacSession.sync(
            SyncConnection(endpoint: .hostPort(host: "127.0.0.1", port: advertiser.port!), key: key), identity: mac,
            selection: { _ in SyncTracks(tracks: f.tracks) }, libraryRoot: f.root, database: f.db, scratch: scratch, radioDJ: settings)
        _ = try await session.value
        #expect(await received.settings == settings)
        #expect(phone.radioDJ == true)
        #expect(phone.radioDJUsage?.allTime.dollars == 0.37)
    }

    @Test func olderHellosDoNotTakeTheDJ() throws {
        // A hello from a phone before the Radio DJ: no `radioDJ`, so the Mac never sends a message it can't decode.
        let old = #"{"protocolVersion":3,"deviceID":"p","deviceName":"iPhone","appVersion":"1.23","schemaVersion":14}"#
        let hello = try JSONDecoder().decode(SyncHello.self, from: Data(old.utf8))
        #expect(hello.radioDJ == nil)
        #expect(hello.radioDJUsage == nil)
        let message = try SyncFrame.message(.radioDJ(SyncRadioDJ(apiKey: nil, name: "Max")))
        #expect(try message.message() == .radioDJ(SyncRadioDJ(apiKey: nil, name: "Max")))
    }
}

@Suite struct RadioDJCollectionSearchTests {
    static func track(_ id: Int64, _ title: String, _ artist: String, _ album: String, year: Int, no: Int) -> Track {
        var m = TrackMetadata()
        m.title = title; m.artist = artist; m.albumArtist = artist; m.album = album; m.year = year; m.trackNo = no; m.genre = "Jazz"
        return Track(id: id, path: "Music/\(artist)/\(album)/\(no).flac", metadata: m, duration: 300, format: "flac", sha256: "\(id)",
                     addedAt: Date(timeIntervalSince1970: Double(id) * 1000))
    }

    let library: RadioDJLibrary = {
        let tracks = [
            track(1, "Peel Me a Grape", "Diana Krall", "Love Scenes", year: 1997, no: 1),
            track(2, "All Or Nothing at All", "Diana Krall", "Love Scenes", year: 1997, no: 2),
            track(3, "The Look of Love", "Diana Krall", "The Look of Love", year: 2001, no: 1),
            track(4, "So What", "Miles Davis", "Kind of Blue", year: 1959, no: 1),
        ]
        var cd = CollectionItem(id: "cd7", medium: .cd, album: "Love Scenes", artist: "Diana Krall", now: Date(timeIntervalSince1970: 0))
        cd.stickerNumber = 7
        var vinyl = CollectionItem(id: "v2", medium: .vinyl, album: "Blue Train", artist: "John Coltrane", now: Date(timeIntervalSince1970: 0))
        vinyl.stickerNumber = 2
        let collection = MusicCollection(items: [cd, vinyl], songPurchases: [:], tracks: tracks)
        let index = SearchIndex(tracks: tracks)
        let plays: [Int64: PlayTotal] = [1: PlayTotal(plays: 3), 2: PlayTotal(plays: 11, lastPlayed: Date(timeIntervalSince1970: 1_790_000_000)),
                                         3: PlayTotal(plays: 7), 4: PlayTotal(plays: 50)]
        return RadioDJLibrary(index: index, collectionIndex: CollectionIndex(collection: collection, tracks: tracks, albumInfos: [:], index: index),
                              collection: collection, playTotals: plays, likedDates: [3: Date()])
    }()

    @Test func songsByAnArtistMostPlayedFirst() {
        let (text, isError) = library.run(.object(["query": .string("artist:\"diana krall\""), "sort": .string("plays")]))
        #expect(!isError)
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.first?.hasPrefix("3 songs match") == true)
        #expect(lines.dropFirst().map { $0.components(separatedBy: "”").first ?? "" } == ["“All Or Nothing at All", "“The Look of Love", "“Peel Me a Grape"])
        #expect(lines[1].contains("11 plays, last 2026-09-21"))
        #expect(lines[2].contains("liked"))
        #expect(!text.contains("So What"))
        let day = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(RadioDJLibrary.playText(0, last: day) == "0 full plays (last listened to partly on 2026-09-21)")
        #expect(RadioDJLibrary.playText(1, last: nil) == "1 play")
    }

    @Test func albumsArtistsAndLimits() {
        let albums = library.search("diana", kind: .albums, sort: .plays, limit: 1)
        #expect(albums.hasPrefix("2 albums match “diana”, 15 min of music in all (showing 1, sorted by plays):"))
        #expect(albums.contains("*Love Scenes* — Diana Krall (1997) · 2 songs, 10 min · 14 plays"))
        #expect(albums.contains("owned: CD #7"))
        let artists = library.search("", kind: .artists, sort: .plays, limit: 10)
        #expect(artists.hasPrefix("2 artists in the whole collection"))
        #expect(artists.split(separator: "\n")[1].hasPrefix("Miles Davis · 1 album · 1 song, 5 min · 50 plays"))
        #expect(artists.contains("Diana Krall · 2 albums · 3 songs, 15 min · 21 plays"))
    }

    @Test func copiesIncludeRecordsNeverRipped() {
        let all = library.search("own:physical", kind: .copies, sort: .title, limit: 10)
        #expect(all.contains("Vinyl #2: *Blue Train* — John Coltrane · not digitized"))
        #expect(all.contains("CD #7: *Love Scenes* — Diana Krall · in the digital library · 10 min · 14 plays"))
        let label = library.search("#7", kind: .copies, sort: .plays, limit: 10)
        #expect(label.contains("CD #7") && !label.contains("Blue Train"))
    }

    @Test func misspellingsAndBadInput() {
        // A misspelled word is corrected when it finds nothing as typed.
        let fixed = library.search("grapee", kind: .songs, sort: .plays, limit: 5)
        #expect(fixed.hasPrefix("Nothing matched “grapee”; showing “grape”.\n1 song matches “grape”"))
        #expect(fixed.contains("“Peel Me a Grape” — Diana Krall"))
        #expect(library.search("zzzz", kind: .songs, sort: .plays, limit: 5) == "No songs in the collection match “zzzz”.")
        #expect(library.run(.object(["kind": .string("songs")])).isError)
        #expect(library.run(.object(["query": .string("x"), "sort": .string("loudest")])).isError)
        let tool = RadioDJLibrary.tool
        #expect(tool["name"]?.string == "search_collection")
        #expect(tool["input_schema"]?["required"]?.array == [.string("query")])
        #expect(tool["description"]?.string?.contains("credit:") == true)
    }
}

@MainActor @Suite struct RadioDJToolLoopTests {
    @Test func searchesTheCollectionThenAnswers() async throws {
        let toolCall = sse([
            #"{"type":"message_start","message":{"model":"claude-opus-5-5","usage":{"input_tokens":50,"output_tokens":1}}}"#,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Let me check your shelves."}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"search_collection","input":{}}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"query\":\"artist:\\\"diana krall\\\"\",\"sort\":\"plays\"}"}}"#,
            #"{"type":"content_block_stop","index":1}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":30}}"#,
        ])
        let transport = ScriptedClaudeTransport([.lines(toolCall), .lines(textReply("Your favorite is “All Or Nothing at All”."))])
        let session = RadioDJSession(name: "Max", subject: RadioDJSubject(kind: .artist, title: "Diana Krall"),
                                     client: ClaudeClient(apiKey: "k", transport: transport),
                                     library: RadioDJCollectionSearchTests().library) { _ in }
        session.send("What else do I have by her?")
        for _ in 0..<300 where session.isBusy || session.lines.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        for _ in 0..<300 where session.isBusy { try await Task.sleep(for: .milliseconds(10)) }

        #expect(session.error == nil)
        #expect(session.lines.last?.text == "Let me check your shelves.\n\nYour favorite is “All Or Nothing at All”.")
        let bodies = transport.bodies
        #expect(bodies.count == 2)
        #expect(bodies[0]["tools"]?.array?.compactMap { $0["name"]?.string } == ["web_search", "web_fetch", "search_collection", "collection_stats"])
        #expect(bodies[0]["system"]?.array?.first?["text"]?.string?.contains("search_collection") == true)
        let messages = try #require(bodies[1]["messages"]?.array)
        #expect(messages.map { $0["role"]?.string } == ["user", "assistant", "user"])
        let result = try #require(messages[2]["content"]?.array?.first)
        #expect(result["type"]?.string == "tool_result")
        #expect(result["tool_use_id"]?.string == "toolu_1")
        #expect(result["is_error"] == .bool(false))
        #expect(result["content"]?.string?.hasPrefix("3 songs match") == true)
    }

    @Test func noLibraryMeansNoTool() async throws {
        let transport = ScriptedClaudeTransport([.lines(textReply("Hi."))])
        let session = RadioDJSession(name: "Max", subject: RadioDJSubject(kind: .artist, title: "X"),
                                     client: ClaudeClient(apiKey: "k", transport: transport)) { _ in }
        session.start()
        session.send("Hi")
        for _ in 0..<300 where session.isBusy || session.lines.count < 3 { try await Task.sleep(for: .milliseconds(10)) }
        for _ in 0..<300 where session.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        #expect(transport.bodies.first?["tools"]?.array?.count == 2)
        #expect(transport.bodies.first?["system"]?.array?.first?["text"]?.string?.contains("search_collection") == false)
    }
}

@Suite struct RadioDJLinkTests {
    let tracks: [Track] = [
        RadioDJCollectionSearchTests.track(1, "Peel Me a Grape", "Diana Krall", "Love Scenes", year: 1997, no: 1),
        RadioDJCollectionSearchTests.track(2, "Let’s Fall in Love", "Diana Krall", "When I Look in Your Eyes", year: 1999, no: 2),
        RadioDJCollectionSearchTests.track(3, "So What (Remastered)", "Miles Davis", "Kind of Blue", year: 1959, no: 1),
        RadioDJCollectionSearchTests.track(4, "So What", "Pink", "Funhouse", year: 2008, no: 1),
        RadioDJCollectionSearchTests.track(5, "Hip to Be Square", "Huey Lewis & the News", "Fore!", year: 1986, no: 1),
    ]
    var collection: MusicCollection {
        var vinyl = CollectionItem(id: "v2", medium: .vinyl, album: "Blue Train", artist: "John Coltrane", now: Date(timeIntervalSince1970: 0))
        vinyl.stickerNumber = 2
        return MusicCollection(items: [vinyl], songPurchases: [:], tracks: tracks)
    }
    func linker(_ subject: RadioDJSubject? = nil, canPlay: @escaping @Sendable (Track) -> Bool = { _ in true }) -> RadioDJLinker {
        RadioDJLinker(tracks: tracks, collection: collection, subject: subject, canPlay: canPlay)
    }

    @Test func resolvesWhatYouOwnLoosely() {
        let l = linker(RadioDJSubject(kind: .album, title: "Love Scenes", artist: "Diana Krall"))
        #expect(l.resolve(kind: "artist", name: "diana krall", hint: nil) == .artist("Diana Krall"))
        #expect(l.resolve(kind: "artist", name: "Huey Lewis and the News", hint: nil) == .artist("Huey Lewis & the News"))
        #expect(l.resolve(kind: "artist", name: "Bill Evans", hint: nil) == nil)
        #expect(l.resolve(kind: "album", name: "When I Look In Your Eyes", hint: nil) == .album(key: "diana krall\u{1}when i look in your eyes"))
        #expect(l.resolve(kind: "album", name: "Blue Train", hint: "John Coltrane") == .item(id: "v2"))
        // Straight vs curly apostrophes, and the page's songs.
        #expect(l.resolve(kind: "song", name: "Let's Fall in Love", hint: nil) == .play(trackID: 2))
        #expect(l.resolve(kind: "play", name: "Peel Me a Grape", hint: nil) == .play(trackID: 1))
    }

    @Test func ambiguityAndHints() {
        let l = linker()
        // Two artists have "So What": no link without a hint, the right one with it ("(Remastered)" ignored).
        #expect(l.resolve(kind: "song", name: "So What", hint: nil) == nil)
        #expect(l.resolve(kind: "song", name: "So What", hint: "Miles Davis") == .play(trackID: 3))
        #expect(l.resolve(kind: "song", name: "So What", hint: "Funhouse") == .play(trackID: 4))
        // A hint that matches nothing here means someone else's song.
        #expect(l.resolve(kind: "song", name: "Peel Me a Grape", hint: "Blossom Dearie") == nil)
        // On a Miles Davis page, the page decides.
        let page = linker(RadioDJSubject(kind: .artist, title: "Miles Davis"))
        #expect(page.resolve(kind: "play", name: "So What", hint: nil) == .play(trackID: 3))
        // Songs get the play button however they're tagged; one that can't play here (not on the phone) links to its
        // album instead.
        let phone = linker(RadioDJSubject(kind: .artist, title: "Miles Davis"), canPlay: { _ in false })
        #expect(phone.resolve(kind: "play", name: "So What", hint: nil) == .song(trackID: 3))
    }

    @Test func rendersLinksPlayButtonsAndPlainText() throws {
        let l = linker(RadioDJSubject(kind: .album, title: "Love Scenes", artist: "Diana Krall"))
        let raw = #"Spin [Peel Me a Grape](play) from [Love Scenes](album), then try [Waltz for Debby](album "Bill Evans") by [Bill Evans](artist) or [Diana Krall](artist)."#
        let pages = [WikipediaArticleFinder.key(kind: "album", name: "Waltz for Debby", artist: "Bill Evans"): URL(string: "https://en.wikipedia.org/wiki/Waltz_for_Debby_(album)")!,
                     WikipediaArticleFinder.key(kind: "artist", name: "Bill Evans", artist: nil): URL(string: "https://en.wikipedia.org/wiki/Bill_Evans")!]
        let segments = l.render(raw, webPages: pages)
        func text(_ s: RadioDJSegment) -> String {
            switch s { case .text(let t), .play(let t), .preview(let t), .external(let t): String(t.characters) }
        }
        #expect(segments.map(text) == ["Spin ", "Peel Me a Grape", " from Love Scenes, then try ", "Waltz for Debby", " by ", "Bill Evans", " or Diana Krall."])
        guard case .play(let play) = segments[1], case .text(let middle) = segments[2], case .external(let waltz) = segments[3],
              case .external(let evans) = segments[5], case .text(let last) = segments[6] else {
            Issue.record("unexpected segments \(segments)"); return
        }
        #expect(play.link == RadioDJReference.play(trackID: 1).url)
        let owned = (middle.runs.compactMap(\.link) + last.runs.compactMap(\.link)).compactMap { RadioDJReference(url: $0) }
        #expect(owned == [.album(key: "diana krall\u{1}love scenes"), .artist("Diana Krall")])
        // Not owned: the checked Wikipedia article, the album in italics.
        #expect(waltz.runs.first?.link?.absoluteString == "https://en.wikipedia.org/wiki/Waltz_for_Debby_(album)")
        #expect(waltz.runs.first?.inlinePresentationIntent == .emphasized)
        #expect(evans.runs.first?.link?.absoluteString == "https://en.wikipedia.org/wiki/Bill_Evans")
        // Unchecked (or not found): plain text, the album in italics.
        let unchecked = l.render(raw)
        #expect(!unchecked.contains { if case .external = $0 { true } else { false } })
        #expect(l.webCandidates(raw).map(\.name) == ["Waltz for Debby", "Bill Evans"])
        #expect(l.webCandidates(raw).first?.artist == "Bill Evans")
    }

    @Test func songsYouDontOwnGetAPreview() {
        let l = linker(RadioDJSubject(kind: .album, title: "Love Scenes", artist: "Diana Krall"))
        // The hint's artist, else the page's.
        let hinted = l.render(#"Try [Blue in Green](song "Miles Davis")."#)
        guard case .preview(let blue) = hinted[1] else { Issue.record("no preview: \(hinted)"); return }
        #expect(blue.link.flatMap(RadioDJReference.init(url:)) == .preview(title: "Blue in Green", artist: "Miles Davis"))
        let onPage = l.render("Her take on [Garden in the Rain](song).")
        guard case .preview(let garden) = onPage[1] else { Issue.record("no preview: \(onPage)"); return }
        #expect(garden.link.flatMap(RadioDJReference.init(url:)) == .preview(title: "Garden in the Rain", artist: "Diana Krall"))
        // No artist to search with: plain text.
        let unknown = linker().render("Then [Some Song](song).")
        #expect(unknown.count == 1)
    }

    @Test func appleSongSearchPicksTheRightSong() async throws {
        let json = #"{"resultCount":3,"results":[{"wrapperType":"track","kind":"song","collectionId":1,"trackId":11,"artistName":"Miles Davis","collectionName":"Kind of Blue (Legacy Edition)","trackName":"Blue in Green (Studio Sequence 1)","previewUrl":"https://audio-ssl.itunes.apple.com/a.m4a","trackNumber":3},{"wrapperType":"track","kind":"song","collectionId":2,"trackId":12,"artistName":"Miles Davis","collectionName":"Kind of Blue","trackName":"Blue in Green","previewUrl":"https://audio-ssl.itunes.apple.com/b.m4a","trackNumber":3},{"wrapperType":"track","kind":"song","collectionId":3,"trackId":13,"artistName":"Bill Evans Trio","collectionName":"Portrait in Jazz","trackName":"Blue in Green","previewUrl":"https://audio-ssl.itunes.apple.com/c.m4a","trackNumber":9}]}"#
        let client = ApplePreviewClient(minInterval: 0, get: { url in
            #expect(url.absoluteString.contains("entity=song"))
            return Data(json.utf8)
        })
        let songs = try await client.searchSongs(term: "Blue in Green Miles Davis")
        #expect(songs.count == 3)
        #expect(ApplePreviewMatcher.bestSong(songs, title: "Blue in Green", artist: "Miles Davis")?.id == 12)
        #expect(ApplePreviewMatcher.bestSong(songs, title: "Blue in Green", artist: "Bill Evans")?.id == 13)
        #expect(ApplePreviewMatcher.bestSong(songs, title: "So What", artist: "Miles Davis") == nil)
        #expect(RadioDJReference(url: RadioDJReference.preview(title: "Blue in Green", artist: nil).url) == .preview(title: "Blue in Green", artist: nil))
    }

    @Test func streamingHidesAHalfWrittenReference() {
        let l = linker()
        let shown = l.render("Next up, [Peel Me a Gr", streaming: true)
        #expect(shown.map { if case .text(let t) = $0 { String(t.characters) } else { "" } } == ["Next up, "])
        let almost = RadioDJLinker.plain("Try [Peel Me a Grape](pl", streaming: true)
        #expect(almost.count == 1)
        // Once written, a reference with nothing to link to is plain text.
        let done = RadioDJLinker.plain("Try [Peel Me a Grape](play).")
        #expect(done.map { if case .text(let t) = $0 { String(t.characters) } else { "?" } } == ["Try “Peel Me a Grape”."])
    }

    @Test func referenceURLsRoundTrip() {
        for reference: RadioDJReference in [.artist("AC/DC & Friends?"), .album(key: "a\u{1}b c"), .item(id: "own-1"), .song(trackID: 9), .play(trackID: 12)] {
            #expect(RadioDJReference(url: reference.url) == reference)
        }
        #expect(RadioDJReference(url: URL(string: "https://example.com")!) == nil)
    }

    @Test func personaUsesTheListenersName() {
        #expect(RadioDJ.persona(name: "Max", listener: "Dave").contains("The listener's name is Dave."))
        #expect(!RadioDJ.persona(name: "Max", listener: "  ").contains("listener's name"))
        #expect(RadioDJ.persona(name: "Max").contains("[So What](song)"))
    }
}

@MainActor @Suite struct RadioDJPageMoveTests {
    @Test func movingToAnotherPageTellsTheDJOnce() async throws {
        let transport = ScriptedClaudeTransport([.lines(textReply("Ah, Coltrane.")), .lines(textReply("More."))])
        let blue = RadioDJSubject(kind: .album, title: "Kind of Blue", artist: "Miles Davis")
        let train = RadioDJSubject(kind: .album, title: "Blue Train", artist: "John Coltrane", details: ["Label: Blue Note"])
        let session = RadioDJSession(name: "Max", subject: blue, client: ClaudeClient(apiKey: "k", transport: transport)) { _ in }
        func idle() async throws {
            for _ in 0..<300 where session.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        }
        session.start()
        try await Task.sleep(for: .milliseconds(20)); try await idle()
        #expect(!session.isElsewhere(blue))
        // A page read again (a play more) is the same topic.
        var bluePlayed = blue
        bluePlayed.listener = ["Played 1 time in total"]
        #expect(!session.isElsewhere(bluePlayed))
        #expect(session.isElsewhere(train))

        session.send("Tell me about this one.", page: train)
        try await Task.sleep(for: .milliseconds(20)); try await idle()
        #expect(session.subject.topic == train.topic)
        #expect(Array(session.lines.map(\.text).dropFirst()) == ["Tell me about this one.", "Ah, Coltrane."])
        let moved = try #require(transport.bodies[0]["messages"]?.array?.last?["content"]?.array?.first?["text"]?.string)
        #expect(moved.hasPrefix("(The listener just switched you on from the album page for *Kind of Blue*"))
        #expect(moved.contains("\n\n(The listener has moved to the album page for *Blue Train* by John Coltrane.)"))
        #expect(moved.contains("Label: Blue Note"))
        #expect(moved.hasSuffix("\n\nTell me about this one."))

        session.send("Who produced it?", page: train)
        try await Task.sleep(for: .milliseconds(20)); try await idle()
        let same = try #require(transport.bodies[1]["messages"]?.array?.last?["content"]?.array?.first?["text"]?.string)
        #expect(same == "Who produced it?")
        // The system prompt never changes mid-conversation (the API binds the model's thinking to it).
        let systems = transport.bodies.map { $0["system"] }
        #expect(systems.count == 2 && Set(systems.compactMap { $0 }).count == 1)
        #expect(transport.bodies[1]["system"]?.array?.last?["text"]?.string?.contains("Kind of Blue") == true)
    }
}

@Suite struct RadioDJStatsTests {
    let base = RadioDJCollectionSearchTests().library

    var library: RadioDJLibrary {
        var l = base
        let now = Date(timeIntervalSince1970: 1_792_000_000)
        l.plays = [Play(trackId: 4, startedAt: now.addingTimeInterval(-86_400), listened: 300, counted: true),
                   Play(trackId: 2, startedAt: now.addingTimeInterval(-3_600), listened: 300, counted: true),
                   Play(trackId: 2, startedAt: now.addingTimeInterval(-600), listened: 20, counted: false)]
        l.currencyCode = "USD"
        return l
    }

    @Test func runningTimesInSearchResults() {
        // Four 5-minute songs; Diana Krall's three are 15 minutes.
        let songs = library.search("artist:\"diana krall\"", kind: .songs, sort: .plays, limit: 10)
        #expect(songs.hasPrefix("3 songs match “artist:\"diana krall\"”, 15 min of music in all"))
        #expect(songs.contains("· 5:00 ·"))
        let artists = library.search("", kind: .artists, sort: .plays, limit: 10)
        #expect(artists.contains("Diana Krall · 2 albums · 3 songs, 15 min · 21 plays"))
        #expect(artists.contains("20 min of music in all"))
        let copies = library.search("#7", kind: .copies, sort: .plays, limit: 10)
        #expect(copies.contains("in the digital library · 10 min"))
    }

    @Test func statsSections() {
        let now = Date(timeIntervalSince1970: 1_792_000_000)
        let lib = library.runStats(.object(["section": .string("library")]), now: now)
        #expect(!lib.isError)
        #expect(lib.text.hasPrefix("Digital collection: 4 songs, 3 albums"))
        #expect(lib.text.contains("20 min of music"))
        let listening = library.runStats(.object(["section": .string("listening"), "period": .string("7d")]), now: now)
        #expect(listening.text.hasPrefix("Listening, last 7 days: 2 plays (3 listens, 1 skipped)"))
        #expect(listening.text.contains("Top artists:"))
        let owned = library.runStats(.object(["section": .string("owned")]), now: now)
        #expect(owned.text.hasPrefix("Owned: 2 copies (1 CDs, 1 records, 0 downloads)"))
        #expect(library.runStats(.object(["section": .string("vibes")])).isError)
        #expect(library.runStats(.object(["section": .string("listening"), "period": .string("1d")])).isError)
        #expect(RadioDJLibrary.statsTool["name"]?.string == "collection_stats")
    }

    @Test func pagesThatArentAlbumsOrArtists() {
        let insights = RadioDJSubject.page("Insights (Listening, 30 Days)", details: ["Their collection statistics."])
        #expect(insights.headline == "Insights (Listening, 30 Days)")
        #expect(insights.context.hasPrefix("The listener is on Insights (Listening, 30 Days) in the app. What's on screen:"))
        #expect(RadioDJ.opener(insights).hasPrefix("(The listener just switched you on from Insights (Listening, 30 Days) in the app."))
        #expect(insights.moveNote.hasPrefix("(The listener has moved to Insights (Listening, 30 Days) in the app.)"))
        #expect(RadioDJSubject.page("Insights (Owned)").topic != insights.topic)
        #expect(RadioDJ.persona(name: "Max", canSearchCollection: true).contains("collection_stats"))
    }
}


@Suite struct WikipediaArticleTests {
    /// Answers shaped like the real API's (formatversion 2), captured for these titles on 2026-10-25.
    static let affection = #"{"batchcomplete":true,"query":{"redirects":[{"from":"Affection (album)","to":"Affection (disambiguation)"}],"pages":[{"pageid":1,"ns":0,"title":"Affection","description":"Feeling or type of love"},{"pageid":2,"ns":0,"title":"Affection (Lisa Stansfield album)","description":"1989 studio album by Lisa Stansfield"},{"pageid":3,"ns":0,"title":"Affection (disambiguation)","pageprops":{"disambiguation":""},"description":"Topics referred to by the same term"}]}}"#
    static let realLove = #"{"batchcomplete":true,"query":{"redirects":[{"from":"Real Love (album)","to":"Real Love"}],"pages":[{"pageid":4,"ns":0,"title":"Real Love","pageprops":{"disambiguation":""},"description":"Topics referred to by the same term"},{"ns":0,"title":"Real Love (Prince album)","missing":true}]}}"#
    static let realLoveLinks = #"{"query":{"pages":[{"pageid":5,"ns":0,"title":"Teen Dream","description":"2010 studio album by Beach House"},{"pageid":6,"ns":0,"title":"Real Love (Dolly Parton album)","description":"1985 studio album by Dolly Parton"},{"pageid":7,"ns":0,"title":"Real Love (Lisa Stansfield album)","description":"1991 studio album by Lisa Stansfield"},{"pageid":8,"ns":0,"title":"Real Love (Beatles song)","description":"Song by John Lennon"}]}}"#
    static let lynne = #"{"query":{"pages":[{"ns":0,"title":"Jeff Lynne (band)","missing":true},{"pageid":9,"ns":0,"title":"Jeff Lynne","description":"English musician (born 1947)"}]}}"#

    @Test func picksTheArticleAboutTheAlbum() {
        let candidates = WikipediaArticleFinder.candidates(kind: "album", name: "Affection", artist: "Lisa Stansfield")
        #expect(candidates == ["Affection (Lisa Stansfield album)", "Affection (album)", "Affection", "Affection (Lisa Stansfield EP)"])
        #expect(WikipediaArticleFinder.pick(Data(Self.affection.utf8), candidates: candidates, kind: "album", artist: "Lisa Stansfield")
                == "Affection (Lisa Stansfield album)")
        // The feeling isn't the album, even without the artist.
        #expect(WikipediaArticleFinder.pick(Data(Self.affection.utf8), candidates: ["Affection"], kind: "album", artist: nil) == nil)
        let artists = WikipediaArticleFinder.candidates(kind: "artist", name: "Jeff Lynne", artist: nil)
        #expect(WikipediaArticleFinder.pick(Data(Self.lynne.utf8), candidates: artists, kind: "artist", artist: nil) == "Jeff Lynne")
        #expect(WikipediaArticleFinder.pageURL(title: "Affection (Lisa Stansfield album)").absoluteString
                == "https://en.wikipedia.org/wiki/Affection_(Lisa_Stansfield_album)")
    }

    @Test func goesThroughDisambiguationPages() async {
        #expect(WikipediaArticleFinder.disambiguations(Data(Self.realLove.utf8)) == ["Real Love"])
        #expect(WikipediaArticleFinder.pickAmong(Data(Self.realLoveLinks.utf8), name: "Real Love", kind: "album", artist: "Lisa Stansfield")
                == "Real Love (Lisa Stansfield album)")
        // An album named otherwise (Teen Dream) or a song isn't picked.
        #expect(WikipediaArticleFinder.pickAmong(Data(Self.realLoveLinks.utf8), name: "Real Love", kind: "album", artist: "Beach House") == nil)

        let requests = RequestLog()
        let finder = WikipediaArticleFinder(get: { url in
            await requests.add(url)
            let query = url.query ?? ""
            return Data((query.contains("generator=links") ? Self.realLoveLinks : Self.realLove).utf8)
        })
        let url = await finder.article(kind: "album", name: "Real Love", artist: "Lisa Stansfield")
        #expect(url?.absoluteString == "https://en.wikipedia.org/wiki/Real_Love_(Lisa_Stansfield_album)")
        #expect(await requests.urls.count == 2)
    }

    @Test func searchesWhenNothingElseFits() async {
        let search = #"{"query":{"pages":[{"pageid":2,"ns":0,"title":"Lisa Stansfield","index":2,"description":"British singer (born 1966)"},{"pageid":1,"ns":0,"title":"Affection (Lisa Stansfield album)","index":1,"description":"1989 studio album by Lisa Stansfield"}]}}"#
        let finder = WikipediaArticleFinder(get: { url in
            Data(((url.query ?? "").contains("generator=search") ? search : #"{"query":{"pages":[{"ns":0,"title":"Affection","description":"Feeling or type of love"}]}}"#).utf8)
        })
        let url = await finder.article(kind: "album", name: "Affection", artist: "Lisa Stansfield")
        #expect(url?.absoluteString == "https://en.wikipedia.org/wiki/Affection_(Lisa_Stansfield_album)")
        let none = WikipediaArticleFinder(get: { _ in Data(#"{"query":{"pages":[]}}"#.utf8) })
        #expect(await none.article(kind: "artist", name: "Nobody Atall", artist: nil) == nil)
    }

    @Test func doesntGuessWhichAlbumWithoutTheArtist() async {
        // "Affection (disambiguation)"'s links (trimmed), captured on 2026-10-25: three albums have the name.
        let links = #"{"query":{"pages":[{"pageid":1,"ns":0,"title":"Affection","description":"Feeling or type of love"},{"pageid":2,"ns":0,"title":"Affection (Jody Watley album)","description":"1995 studio album by Jody Watley"},{"pageid":3,"ns":0,"title":"Affection (Koda Kumi album)","description":"2002 studio album by Koda Kumi"},{"pageid":4,"ns":0,"title":"Affection (Lisa Stansfield album)","description":"1989 studio album by Lisa Stansfield"},{"pageid":5,"ns":0,"title":"Kids in the Street (The All-American Rejects album)","description":"2012 studio album by the All-American Rejects"}]}}"#
        #expect(WikipediaArticleFinder.pickAmong(Data(links.utf8), name: "Affection", kind: "album", artist: nil) == nil)
        #expect(WikipediaArticleFinder.pickAmong(Data(links.utf8), name: "Affection", kind: "album", artist: "Lisa Stansfield")
                == "Affection (Lisa Stansfield album)")
        // One album by that name is still linked.
        #expect(WikipediaArticleFinder.pickAmong(Data(Self.realLoveLinks.utf8), name: "Teen Dream", kind: "album", artist: nil) == "Teen Dream")

        let finder = WikipediaArticleFinder(get: { url in
            let query = url.query ?? ""
            return Data((query.contains("generator=links") || query.contains("generator=search") ? links : Self.affection).utf8)
        })
        #expect(await finder.article(kind: "album", name: "Affection", artist: nil) == nil)
        #expect(await finder.article(kind: "album", name: "Affection", artist: "Lisa Stansfield")?.absoluteString
                == "https://en.wikipedia.org/wiki/Affection_(Lisa_Stansfield_album)")
    }

    actor RequestLog {
        var urls: [URL] = []
        func add(_ url: URL) { urls.append(url) }
    }
}

@MainActor @Suite struct RadioDJWebLinkTests {
    @Test func linksAppearOnceTheArticleIsChecked() async throws {
        let transport = ScriptedClaudeTransport([.lines(textReply("Spin [Affection](album \"Lisa Stansfield\") next."))])
        let finder = WikipediaArticleFinder(get: { _ in Data(WikipediaArticleTests.affection.utf8) })
        let linker = RadioDJLinker(tracks: [], collection: .empty, subject: nil)
        let session = RadioDJSession(name: "Max", subject: RadioDJSubject(kind: .artist, title: "Lisa Stansfield"),
                                     client: ClaudeClient(apiKey: "k", transport: transport), linker: linker, wikipedia: finder) { _ in }
        session.start()
        session.send("What should I play next?")
        for _ in 0..<300 where session.webPages.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let line = try #require(session.lines.last)
        let external = session.segments(line).compactMap { if case .external(let t) = $0 { t } else { nil } }
        #expect(external.first?.runs.first?.link?.absoluteString == "https://en.wikipedia.org/wiki/Affection_(Lisa_Stansfield_album)")
    }
}
