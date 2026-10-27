import Foundation
import Testing
@testable import MusicLibraryCore

/// SSE lines for chat completion chunks.
func chunks(_ events: [String], done: Bool = true) -> [String] {
    [": OPENROUTER PROCESSING", ""] + events.flatMap { ["data: \($0)", ""] } + (done ? ["data: [DONE]", ""] : [])
}

func chatTextReply(_ text: String, cost: Double = 0.0012) -> [String] {
    let escaped = String(data: try! JSONEncoder().encode(text), encoding: .utf8)!
    return chunks([
        #"{"id":"gen-1","model":"openai/gpt-5.2","choices":[{"index":0,"delta":{"role":"assistant","content":\#(escaped)}}]}"#,
        #"{"id":"gen-1","model":"openai/gpt-5.2","choices":[{"index":0,"delta":{"content":""},"finish_reason":"stop"}]}"#,
        #"{"id":"gen-1","model":"openai/gpt-5.2","choices":[{"index":0,"delta":{"content":""},"finish_reason":"stop"}],"usage":{"prompt_tokens":120,"completion_tokens":30,"total_tokens":150,"cost":\#(cost)}}"#,
    ])
}

let gpt = RadioDJModel(provider: .openRouter, id: "openai/gpt-5.2", name: "OpenAI: GPT-5.2", inputPrice: 1.75, outputPrice: 14,
                       cacheReadPrice: 0.175, acceptsImages: true, contextLength: 400_000)

@Suite struct OpenRouterModelTests {
    // Shaped like OpenRouter's documented `GET /api/v1/models` (not a captured response).
    static let list = #"""
    {"data":[
      {"id":"openai/gpt-5.2","name":"OpenAI: GPT-5.2","context_length":400000,
       "architecture":{"input_modalities":["text","image","file"],"output_modalities":["text"]},
       "pricing":{"prompt":"0.00000175","completion":"0.000014","input_cache_read":"0.000000175","web_search":"0.01"},
       "supported_parameters":["max_tokens","tools","tool_choice","reasoning"]},
      {"id":"deepseek/deepseek-v4","name":"DeepSeek: V4","context_length":163840,
       "architecture":{"input_modalities":["text"],"output_modalities":["text"]},
       "pricing":{"prompt":"0.0000003","completion":"0.0000012"},
       "supported_parameters":["max_tokens","tools"]},
      {"id":"openai/gpt-5.2:batch","name":"OpenAI: GPT-5.2 (batch)","architecture":{"input_modalities":["text"],"output_modalities":["text"]},
       "pricing":{"prompt":"0.000000875","completion":"0.000007"},"supported_parameters":["tools"]},
      {"id":"some/no-tools","name":"No Tools","architecture":{"input_modalities":["text"],"output_modalities":["text"]},
       "pricing":{"prompt":"0.000001","completion":"0.000002"},"supported_parameters":["max_tokens"]},
      {"id":"some/image-maker","name":"Image Maker","architecture":{"input_modalities":["text"],"output_modalities":["image"]},
       "pricing":{"prompt":"0.000001","completion":"0.000002"},"supported_parameters":["tools"]},
      {"id":"openrouter/auto","name":"Auto Router","architecture":{"input_modalities":["text"],"output_modalities":["text"]},
       "pricing":{"prompt":"-1","completion":"-1"},"supported_parameters":["tools"]},
      {"id":"anthropic/claude-opus-5.5","name":"Anthropic: Claude Opus 5.5","context_length":1000000,
       "architecture":{"input_modalities":["text","image"],"output_modalities":["text"]},
       "pricing":{"prompt":"0.000004","completion":"0.00002","input_cache_read":"0.0000002"},
       "supported_parameters":["tools","reasoning"]}
    ]}
    """#

    @Test func keepsModelsThatCanUseToolsWithPricesPerMillion() throws {
        let models = try OpenRouterModelParser.parse(Data(Self.list.utf8))
        #expect(models.map(\.id) == ["anthropic/claude-opus-5.5", "deepseek/deepseek-v4", "openai/gpt-5.2"])
        let gpt = try #require(models.last)
        #expect(gpt.provider == .openRouter)
        #expect(gpt.inputPrice == 1.75)
        #expect(gpt.outputPrice == 14)
        #expect(gpt.cacheReadPrice == 0.175)
        #expect(gpt.webSearchPrice == 0.01)
        #expect(gpt.acceptsImages)
        #expect(gpt.contextLength == 400_000)
        #expect(models[1].acceptsImages == false)
        #expect(models[1].cacheReadPrice == nil)
        #expect(models[0].priceSummary == "$4 in · $20 out per million tokens")
        #expect(throws: ClaudeError.self) { try OpenRouterModelParser.parse(Data("<html>".utf8)) }
    }

    @Test func prices() {
        #expect(RadioDJModel.price(4) == "$4")
        #expect(RadioDJModel.price(1.75) == "$1.75")
        #expect(RadioDJModel.price(0.1) == "$0.10")
        #expect(RadioDJModel.price(0.075) == "$0.075")
        #expect(RadioDJModel.price(0) == "$0")
    }

    @Test func claudeModelsAndTheSavedChoice() throws {
        #expect(RadioDJModel.default.id == "claude-opus-5-5")
        #expect(RadioDJModel.default.inputPrice == 4)
        #expect(RadioDJModel.anthropic.allSatisfy { $0.provider == .anthropic && $0.acceptsImages })
        let defaults = try #require(UserDefaults(suiteName: "RadioDJModelTests-\(UUID().uuidString)"))
        #expect(RadioDJModel.load(from: defaults) == .default)
        gpt.save(to: defaults)
        #expect(RadioDJModel.load(from: defaults) == gpt)
        // A Claude model saved with old prices comes back with today's; junk is kept within reason.
        var stale = RadioDJModel.anthropic[2]; stale.inputPrice = 99
        #expect(stale.sanitized == RadioDJModel.anthropic[2])
        var junk = gpt; junk.inputPrice = -.infinity; junk.name = "  "; junk.contextLength = 0
        #expect(junk.sanitized.inputPrice == 0)
        #expect(junk.sanitized.name == gpt.id)
        #expect(junk.sanitized.contextLength == nil)
        var empty = gpt; empty.id = " "
        #expect(empty.sanitized == .default)
    }

    @Test func syncSettingsFromOlderAndNewerMacs() throws {
        // A Mac before 1.27: no OpenRouter key or model.
        let old = try JSONDecoder().decode(SyncRadioDJ.self, from: Data(#"{"apiKey":"sk-ant","name":"Max"}"#.utf8))
        #expect(old == SyncRadioDJ(apiKey: "sk-ant", name: "Max"))
        // A model from a provider added later doesn't fail the message.
        let newer = #"{"apiKey":null,"name":"Max","openRouterKey":"sk-or","model":{"provider":"elsewhere","id":"x","name":"X","inputPrice":1,"outputPrice":2,"acceptsImages":true}}"#
        let decoded = try JSONDecoder().decode(SyncRadioDJ.self, from: Data(newer.utf8))
        #expect(decoded.openRouterKey == "sk-or")
        #expect(decoded.model == nil)
        let full = SyncRadioDJ(apiKey: nil, name: "Max", openRouterKey: "sk-or", model: gpt)
        #expect(try JSONDecoder().decode(SyncRadioDJ.self, from: JSONEncoder().encode(full)) == full)
    }
}

@Suite struct OpenRouterRequestTests {
    @Test func translatesTheConversation() throws {
        let photo = JSONValue.object(["type": .string("image"), "source": .object(["type": .string("base64"),
                                      "media_type": .string("image/jpeg"), "data": .string("QUJD")])])
        let reasoning = JSONValue.object(["type": .string("openrouter_reasoning"), "details": .array([
            .object(["type": .string("reasoning.encrypted"), "data": .string("opaque"), "format": .string("openai-responses-v1"), "index": .number(0)]),
        ])])
        let messages = [
            ClaudeMessage(role: "user", content: [photo, .object(["type": .string("text"), "text": .string("What's this?")])]),
            ClaudeMessage(role: "assistant", content: [reasoning,
                .object(["type": .string("text"), "text": .string("Checking.")]),
                .object(["type": .string("tool_use"), "id": .string("call_9"), "name": .string("search_collection"),
                         "input": .object(["query": .string("coltrane")])])]),
            ClaudeMessage(role: "user", content: [
                .object(["type": .string("tool_result"), "tool_use_id": .string("call_9"), "content": .string("2 albums"), "is_error": .bool(false)]),
            ]),
        ]
        let request = ClaudeRequest(model: "openai/gpt-5.2", maxTokens: 16_000, system: ["persona", "context"], messages: messages,
                                    tools: RadioDJ.tools + [RadioDJLibrary.tool])
        let body = try JSONDecoder().decode(JSONValue.self, from: OpenRouterAPI.body(request))
        #expect(body["model"]?.string == "openai/gpt-5.2")
        #expect(body["stream"] == .bool(true))
        #expect(body["fallbacks"] == nil)
        let chat = try #require(body["messages"]?.array)
        #expect(chat.map { $0["role"]?.string } == ["system", "user", "assistant", "tool"])
        #expect(chat[0]["content"]?.array?.map { $0["text"]?.string } == ["persona", "context"])
        #expect(chat[0]["content"]?.array?.last?["cache_control"]?["type"]?.string == "ephemeral")
        #expect(chat[1]["content"]?.array?.first?["image_url"]?["url"]?.string == "data:image/jpeg;base64,QUJD")
        #expect(chat[1]["content"]?.array?.last?["text"]?.string == "What's this?")
        #expect(chat[2]["content"]?.string == "Checking.")
        let call = try #require(chat[2]["tool_calls"]?.array?.first)
        #expect(call["id"]?.string == "call_9")
        #expect(call["function"]?["name"]?.string == "search_collection")
        #expect(call["function"]?["arguments"]?.string == #"{"query":"coltrane"}"#)
        #expect(chat[2]["reasoning_details"]?.array?.first?["data"]?.string == "opaque")
        #expect(chat[3]["tool_call_id"]?.string == "call_9")
        #expect(chat[3]["content"]?.string == "2 albums")
        // Web search becomes OpenRouter's; it has no web fetch; the app's tools are functions.
        let tools = try #require(body["tools"]?.array)
        #expect(tools.map { $0["type"]?.string } == ["openrouter:web_search", "function"])
        #expect(tools[0]["parameters"]?["max_uses"]?.int == 5)
        #expect(tools[1]["function"]?["name"]?.string == "search_collection")
        #expect(tools[1]["function"]?["parameters"]?["type"]?.string == "object")

        let http = OpenRouterAPI.request(OpenRouterAPI.chatURL, apiKey: "sk-or-test", body: Data())
        #expect(http.value(forHTTPHeaderField: "Authorization") == "Bearer sk-or-test")
        #expect(http.value(forHTTPHeaderField: "x-api-key") == nil)
        #expect(http.httpMethod == "POST")
    }

    @Test func claudeOptionsDifferByModel() throws {
        let haiku = try #require(RadioDJModel.anthropic.first { $0.id == "claude-haiku-5-5" })
        #expect(RadioDJ.tools(for: haiku).compactMap { $0["type"]?.string } == ["web_search_20250305", "web_fetch_20250910"])
        #expect(RadioDJ.tools(for: .default) == RadioDJ.tools)
        #expect(RadioDJ.tools(for: gpt) == RadioDJ.tools)
        let request = ClaudeRequest(model: haiku.id, maxTokens: 10, system: [], messages: [.user("hi")], serverFallback: false)
        let body = try JSONDecoder().decode(JSONValue.self, from: request.body())
        #expect(body["fallbacks"] == nil)
    }
}

@Suite struct OpenRouterStreamTests {
    @Test func buildsTheReplyAsContentBlocks() {
        var reply = OpenRouterStreamAccumulator()
        var events: [ClaudeStreamEvent] = []
        let lines = [
            #"{"model":"openai/gpt-5.2","choices":[{"delta":{"role":"assistant","reasoning_details":[{"type":"reasoning.text","text":"Let me ","index":0,"format":"x"}]}}]}"#,
            #"{"choices":[{"delta":{"reasoning_details":[{"type":"reasoning.text","text":"think.","signature":"sig","index":0}]}}]}"#,
            #"{"choices":[{"delta":{"content":"Blue Train "}}]}"#,
            #"{"choices":[{"delta":{"content":"is from 1957.","annotations":[{"type":"url_citation","url_citation":{"url":"https://en.wikipedia.org/wiki/Blue_Train_(album)","title":"Blue Train"}},{"type":"url_citation","url_citation":{"url":"https://en.wikipedia.org/wiki/Blue_Train_(album)","title":"again"}}]}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"search_collection","arguments":"{\"que"}}]}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"ry\":\"coltrane\"}"}}]}}]}"#,
            #"{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#,
            #"{"choices":[{"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":1000,"completion_tokens":50,"prompt_tokens_details":{"cached_tokens":800},"cost":0.0042,"server_tool_use":{"web_search_requests":1}}}"#,
            "[DONE]",
        ]
        for line in lines { events += reply.handle(data: line) }
        #expect(events == [.text("Blue Train "), .text("is from 1957."), .toolStarted(name: "search_collection"),
                           .toolInput(name: "search_collection", input: .object(["query": .string("coltrane")]))])
        #expect(reply.stopReason == "tool_use")
        #expect(reply.model == "openai/gpt-5.2")
        let content = reply.content
        #expect(content.map { $0["type"]?.string } == ["openrouter_reasoning", "text", "tool_use"])
        let detail = content[0]["details"]?.array?.first
        #expect(detail?["text"]?.string == "Let me think.")
        #expect(detail?["signature"]?.string == "sig")
        #expect(detail?["format"]?.string == "x")
        #expect(content[1]["citations"]?.array?.count == 1)
        #expect(content[1]["citations"]?.array?.first?["title"]?.string == "Blue Train")
        #expect(content[2]["id"]?.string == "call_1")
        let tally = reply.tally(estimatingWith: gpt)
        #expect(tally.dollars == 0.0042)
        #expect(tally.inputTokens == 200)
        #expect(tally.cacheReadTokens == 800)
        #expect(tally.outputTokens == 50)
        #expect(tally.webSearches == 1)
        #expect(tally.requests == 1)
    }

    @Test func estimatesWhenTheCostIsMissingAndReadsStopReasons() {
        var reply = OpenRouterStreamAccumulator()
        _ = reply.handle(data: #"{"choices":[{"delta":{"content":"Hi"},"finish_reason":"length"}],"usage":{"prompt_tokens":1000000,"completion_tokens":1000000}}"#)
        #expect(reply.stopReason == "max_tokens")
        #expect(reply.tally(estimatingWith: gpt).dollars == 15.75)
        var refused = OpenRouterStreamAccumulator()
        _ = refused.handle(data: #"{"choices":[{"delta":{},"finish_reason":"content_filter"}]}"#)
        #expect(refused.stopReason == "refusal")
        var failed = OpenRouterStreamAccumulator()
        _ = failed.handle(data: #"{"error":{"code":502,"message":"Provider returned error"},"choices":[{"delta":{"content":""},"finish_reason":"error"}]}"#)
        #expect(failed.error == .api("Provider returned error"))
    }

    @Test func errorsSurfaceInOpenRoutersWords() async {
        let transport = ScriptedClaudeTransport([.status(401, #"{"error":{"code":401,"message":"No auth credentials found"}}"#),
                                                 .status(402, #"{"error":{"code":402,"message":"Insufficient credits"}}"#),
                                                 .failure(.connection("offline"))])
        let client = OpenRouterClient(apiKey: "k", model: gpt, transport: transport)
        let request = ClaudeRequest(model: gpt.id, maxTokens: 10, system: [], messages: [.user("hi")])
        for expected in ["The OpenRouter API key was refused. Check it in Settings.", "Insufficient credits", "Couldn't reach OpenRouter: offline"] {
            do {
                _ = try await client.reply(to: request) { _ in }
                Issue.record("no error")
            } catch {
                #expect(error.localizedDescription == expected)
            }
        }
    }
}

@MainActor @Suite struct OpenRouterSessionTests {
    @Test func searchesTheCollectionThenAnswersAndCountsWhatItCost() async throws {
        let toolCall = chunks([
            #"{"model":"openai/gpt-5.2","choices":[{"delta":{"content":"Let me check your shelves."}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"search_collection","arguments":"{\"query\":\"artist:\\\"diana krall\\\"\",\"sort\":\"plays\"}"}}]}}]}"#,
            #"{"choices":[{"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":500,"completion_tokens":40,"cost":0.002}}"#,
        ])
        let transport = ScriptedClaudeTransport([.lines(toolCall), .lines(chatTextReply("Your favorite is “All Or Nothing at All”."))])
        var tallies: [RadioDJTally] = []
        let session = RadioDJSession(name: "Max", subject: RadioDJSubject(kind: .artist, title: "Diana Krall"),
                                     client: OpenRouterClient(apiKey: "k", model: gpt, transport: transport), model: gpt,
                                     library: RadioDJCollectionSearchTests().library) { tallies.append($0) }
        session.send("What else do I have by her?")
        for _ in 0..<300 where session.isBusy || session.lines.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        for _ in 0..<300 where session.isBusy { try await Task.sleep(for: .milliseconds(10)) }

        #expect(session.error == nil)
        #expect(session.lines.last?.text == "Let me check your shelves.\n\nYour favorite is “All Or Nothing at All”.")
        #expect(transport.requests.first?.url == OpenRouterAPI.chatURL)
        let bodies = transport.bodies
        #expect(bodies.count == 2)
        #expect(bodies[0]["model"]?.string == "openai/gpt-5.2")
        #expect(bodies[0]["tools"]?.array?.map { $0["type"]?.string } == ["openrouter:web_search", "function", "function"])
        let messages = try #require(bodies[1]["messages"]?.array)
        #expect(messages.map { $0["role"]?.string } == ["system", "user", "assistant", "tool"])
        #expect(messages[3]["content"]?.string?.hasPrefix("3 songs match") == true)
        #expect(tallies.map(\.dollars).filter { $0 > 0 } == [0.002, 0.0012])
        #expect(abs(session.cost - 0.0032) < 1e-9)
    }

    @Test func modelsThatCantSeeLeavePhotosOut() async throws {
        var blind = gpt; blind.acceptsImages = false
        let transport = ScriptedClaudeTransport([.lines(chatTextReply("Hi."))])
        let session = RadioDJSession(name: "Max", subject: RadioDJSubject(kind: .artist, title: "X"),
                                     client: OpenRouterClient(apiKey: "k", model: blind, transport: transport), model: blind) { _ in }
        #expect(!session.seesPhotos)
        let photo = try #require(RadioDJPhoto(imageData: try RadioDJPhotoTests.cameraJPEG(width: 64, height: 64)))
        session.send("Hello", photos: [photo])
        for _ in 0..<300 where session.isBusy || session.lines.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        for _ in 0..<300 where session.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        let user = try #require(transport.bodies.first?["messages"]?.array?.last)
        #expect(user["content"]?.array?.map { $0["type"]?.string } == ["text"])
        #expect(session.lines.first { $0.role == .listener }?.photos.isEmpty == true)
    }
}
