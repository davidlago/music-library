import Foundation
import Testing
@testable import MusicLibraryCore

@Suite struct RadioDJShopRequestTests {
    @Test func readsAndChecksTheToolInput() throws {
        let input: JSONValue = .object(["album": .string(" Rumours "), "artist": .string("Fleetwood Mac"), "format": .string("Vinyl")])
        let request = try RadioDJShopRequest.parse(input).get()
        #expect(request == RadioDJShopRequest(album: "Rumours", artist: "Fleetwood Mac", format: .vinyl))
        #expect(request.query == CDSearchQuery(album: "Rumours", artist: "Fleetwood Mac", format: .vinyl))

        func error(_ input: JSONValue) -> String? {
            if case .failure(let e) = RadioDJShopRequest.parse(input) { return e.message }
            return nil
        }
        #expect(error(.string("Rumours")) != nil)
        #expect(error(.object(["album": .string("Rumours"), "artist": .string("Fleetwood Mac"), "format": .string("cassette")])) == "format must be cd or vinyl")
        #expect(error(.object(["album": .number(1), "artist": .string("x"), "format": .string("cd")])) != nil)
        #expect(error(.object(["album": .string(""), "artist": .string(" "), "format": .string("cd")])) != nil)
        #expect(error(.object(["album": .string("A"), "artist": .string("B"), "format": .string("cd"), "code": .number(5)])) == "code must be a string")

        let tool = RadioDJShopRequest.tool
        #expect(tool["name"]?.string == "open_shop")
        #expect(tool["input_schema"]?["properties"]?["format"]?["enum"] == .array([.string("cd"), .string("vinyl")]))
    }

    @Test func summarizesWhatTheShopFound() {
        let request = RadioDJShopRequest(album: "Rumours", artist: "Fleetwood Mac", format: .vinyl)
        let editions = [CDEdition(id: "a", title: "Rumours", artist: "Fleetwood Mac", date: "1977-02-04", format: "12\" Vinyl"),
                        CDEdition(id: "b", title: "Rumours", artist: "Fleetwood Mac", date: "2011", format: "12\" Vinyl")]
        let album = CDAlbum(id: "rg", title: "Rumours", artist: "Fleetwood Mac", releaseType: "Album", editions: editions)
        let text = RadioDJShopRequest.summary([album], request: request)
        #expect(text.hasPrefix("The Shop is open, searching for vinyl records of *Rumours* by Fleetwood Mac. MusicBrainz found 1 album:"))
        #expect(text.contains("- *Rumours* — Fleetwood Mac (Album, 1977, 2 Vinyl editions), editions from 1977 to 2011"))
        #expect(RadioDJShopRequest.summary([], request: request).contains("no Vinyl editions"))
        #expect(RadioDJShopRequest.summary([], request: request, error: "offline").contains("search failed (offline)"))
    }
}

@MainActor @Suite struct RadioDJShopToolTests {
    @Test func opensTheShopThenAnswers() async throws {
        let toolCall = sse([
            #"{"type":"message_start","message":{"model":"claude-opus-5-5","usage":{"input_tokens":50,"output_tokens":1}}}"#,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_9","name":"open_shop","input":{}}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"album\":\"Blue\",\"artist\":\"Joni Mitchell\",\"format\":\"vinyl\"}"}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":30}}"#,
        ])
        let transport = ScriptedClaudeTransport([.lines(toolCall), .lines(textReply("Pick the 1971 Reprise pressing."))])
        var asked: [RadioDJShopRequest] = []
        let session = RadioDJSession(name: "Max", subject: RadioDJSubject(kind: .album, title: "Blue", artist: "Joni Mitchell"),
                                     client: ClaudeClient(apiKey: "k", transport: transport),
                                     shop: { request in asked.append(request); return "The Shop is open: 14 Vinyl editions." }) { _ in }
        session.send("Help me find this on vinyl")
        for _ in 0..<300 where session.isBusy || session.lines.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        for _ in 0..<300 where session.isBusy { try await Task.sleep(for: .milliseconds(10)) }

        #expect(session.error == nil)
        #expect(asked == [RadioDJShopRequest(album: "Blue", artist: "Joni Mitchell", format: .vinyl)])
        let bodies = transport.bodies
        #expect(bodies.count == 2)
        #expect(bodies[0]["tools"]?.array?.compactMap { $0["name"]?.string } == ["web_search", "web_fetch", "open_shop"])
        #expect(bodies[0]["system"]?.array?.first?["text"]?.string?.contains("open_shop") == true)
        let result = try #require(bodies[1]["messages"]?.array?.last?["content"]?.array?.first)
        #expect(result["tool_use_id"]?.string == "toolu_9" && result["is_error"] == .bool(false))
        #expect(result["content"]?.string == "The Shop is open: 14 Vinyl editions.")
    }

    @Test func withoutAShopThereIsNoTool() {
        #expect(!RadioDJ.persona(name: "Max").contains("open_shop"))
        #expect(RadioDJ.persona(name: "Max", canShop: true).contains("open_shop"))
    }
}

@Suite struct RadioDJTimeTests {
    @Test func theOpenerSaysTheListenersTime() throws {
        let zone = try #require(TimeZone(identifier: "America/New_York"))
        // Sunday 25 October 2026, 15:12 in New York.
        let afternoon = Date(timeIntervalSince1970: 1_792_955_520)
        #expect(RadioDJ.localTime(afternoon, timeZone: zone) == "Sunday afternoon, 3:12 PM")
        #expect(RadioDJ.localTime(afternoon.addingTimeInterval(-9 * 3600), timeZone: zone) == "Sunday morning, 6:12 AM")
        #expect(RadioDJ.localTime(afternoon.addingTimeInterval(4 * 3600), timeZone: zone) == "Sunday evening, 7:12 PM")
        #expect(RadioDJ.localTime(afternoon.addingTimeInterval(-13 * 3600), timeZone: zone) == "Sunday night, 2:12 AM")
        let subject = RadioDJSubject(kind: .album, title: "Blue", artist: "Joni Mitchell")
        #expect(RadioDJ.opener(subject, at: afternoon, timeZone: zone).contains("It's Sunday afternoon, 3:12 PM where they are."))
        #expect(RadioDJ.persona(name: "Max").contains("don't assume it's late at night"))
    }

    @Test func greetingsAndSuggestions() throws {
        let zone = try #require(TimeZone(identifier: "America/New_York"))
        let afternoon = Date(timeIntervalSince1970: 1_792_955_520)
        let blue = RadioDJSubject(kind: .album, title: "Blue", artist: "Joni Mitchell")
        #expect(RadioDJ.greeting(name: "Max", listener: "Dave", subject: blue, at: afternoon, timeZone: zone)
                == "Good afternoon, Dave! Max here, on the air with [Blue](album) by [Joni Mitchell](artist) on the turntable. Pick a question below, or ask me anything.")
        let night = RadioDJ.greeting(name: "Max", subject: .page("the Shelf"), at: afternoon.addingTimeInterval(-13 * 3600), timeZone: zone)
        #expect(night == "Hello, night owl! Max here, on the air. Pick a question below, or ask me anything.")
        // Brackets in a title can't break its reference.
        #expect(RadioDJ.greeting(name: "Max", subject: RadioDJSubject(kind: .artist, title: "[x]"), at: afternoon, timeZone: zone)
            .contains("all about [(x)](artist)"))

        #expect(RadioDJ.suggestions(for: blue) == ["Tell me about Blue", "Who played on it?", "What should I listen for?", "Where does it fit in their career?"])
        #expect(RadioDJ.suggestions(for: blue, canSearchCollection: true, canShop: true).last == "Help me find a copy to buy")
        #expect(RadioDJ.suggestions(for: RadioDJSubject(kind: .artist, title: "Miles Davis"), canSearchCollection: true).count == 4)
        #expect(RadioDJ.suggestions(for: .page("Insights")).first == "Tell me something about what's on screen")
    }
}
