import Foundation

/// OpenRouter's chat completions API (https://openrouter.ai/docs), for the Radio DJ on any model OpenRouter serves.
/// The session keeps its conversation as Claude API content blocks whichever API it talks to, so this client turns
/// them into chat messages going out and the streamed reply back into blocks: text (with the pages it cites as
/// `citations`), `tool_use` calls, and the model's reasoning (`openrouter_reasoning`, sent back unchanged, as
/// OpenRouter asks, so a model keeps its train of thought across tool calls).
public enum OpenRouterAPI {
    public static let chatURL = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    public static let modelsURL = URL(string: "https://openrouter.ai/api/v1/models")!
    public static let keyURL = URL(string: "https://openrouter.ai/api/v1/key")!
    /// The block type holding a reply's `reasoning_details`.
    static let reasoningBlock = "openrouter_reasoning"

    public static func request(_ url: URL, apiKey: String?, body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpBody = body
        request.timeoutInterval = 600
        if let apiKey, !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        // OpenRouter's app attribution (optional).
        request.setValue("https://davidlago.github.io/music-library/", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("Music Library", forHTTPHeaderField: "X-Title")
        return request
    }

    /// The API's error body (`{"error":{"code":…,"message":…}}`) as something to show.
    static func describe(status: Int, body: Data) -> ClaudeError {
        let message = (try? JSONDecoder().decode(JSONValue.self, from: body))?["error"]?["message"]?.string
        switch status {
        case 401, 403: return .api("The OpenRouter API key was refused. Check it in Settings.")
        case 402: return .api(message ?? "Your OpenRouter account is out of credit.")
        case 429: return .api("Too many requests to OpenRouter right now. Try again in a minute.")
        case 500...599: return .api("OpenRouter is busy right now. Try again in a moment.")
        default: return .api(message ?? "OpenRouter answered with HTTP \(status).")
        }
    }

    // MARK: Request

    /// The chat completions body for a request made for the Claude API: the system prompt as one system message (its
    /// parts marked for caching, which providers that cache take), the conversation as chat messages, web search as
    /// OpenRouter's own search tool (web fetch has none, so it's left out) and the app's tools as functions.
    public static func body(_ request: ClaudeRequest) throws -> Data {
        var system: [JSONValue] = request.system.map { .object(["type": .string("text"), "text": .string($0)]) }
        if let last = system.indices.last, case .object(var part) = system[last] {
            part["cache_control"] = .object(["type": .string("ephemeral")])
            system[last] = .object(part)
        }
        var messages: [JSONValue] = system.isEmpty ? [] : [.object(["role": .string("system"), "content": .array(system)])]
        for message in request.messages { messages += chatMessages(message) }
        var body: [String: JSONValue] = [
            "model": .string(request.model),
            "max_tokens": .number(Double(request.maxTokens)),
            "stream": .bool(true),
            "messages": .array(messages),
        ]
        let tools = request.tools.compactMap(chatTool)
        if !tools.isEmpty { body["tools"] = .array(tools) }
        return try JSONEncoder().encode(JSONValue.object(body))
    }

    static func chatTool(_ tool: JSONValue) -> JSONValue? {
        let type = tool["type"]?.string ?? ""
        if type.hasPrefix("web_search") {
            var parameters: [String: JSONValue] = ["max_results": .number(5)]
            if let uses = tool["max_uses"] { parameters["max_uses"] = uses }
            return .object(["type": .string("openrouter:web_search"), "parameters": .object(parameters)])
        }
        guard let name = tool["name"]?.string, let schema = tool["input_schema"] else { return nil }
        var function: [String: JSONValue] = ["name": .string(name), "parameters": schema]
        if let description = tool["description"] { function["description"] = description }
        return .object(["type": .string("function"), "function": .object(function)])
    }

    /// One Claude API turn as chat messages: a user turn's tool results become `tool` messages (first, as they must
    /// follow the assistant's calls), its text and photos a user message; an assistant turn's text, calls and reasoning
    /// one assistant message.
    static func chatMessages(_ message: ClaudeMessage) -> [JSONValue] {
        if message.role == "assistant" {
            let text = message.content.filter { $0["type"]?.string == "text" }.compactMap { $0["text"]?.string }.joined()
            var out: [String: JSONValue] = ["role": .string("assistant"), "content": text.isEmpty ? .null : .string(text)]
            let calls: [JSONValue] = message.content.filter { $0["type"]?.string == "tool_use" }.map { call in
                let input = (try? JSONEncoder().encode(call["input"] ?? .object([:]))).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                return .object(["id": call["id"] ?? .string(""), "type": .string("function"),
                                "function": .object(["name": call["name"] ?? .string(""), "arguments": .string(input)])])
            }
            if !calls.isEmpty { out["tool_calls"] = .array(calls) }
            let reasoning = message.content.filter { $0["type"]?.string == reasoningBlock }.flatMap { $0["details"]?.array ?? [] }
            if !reasoning.isEmpty { out["reasoning_details"] = .array(reasoning) }
            return [.object(out)]
        }
        var messages: [JSONValue] = []
        var parts: [JSONValue] = []
        for block in message.content {
            switch block["type"]?.string {
            case "tool_result":
                let content: String = block["content"]?.string
                    ?? (block["content"]?.array ?? []).compactMap { $0["text"]?.string }.joined(separator: "\n")
                let text = block["is_error"] == .bool(true) ? "Error: " + content : content
                messages.append(.object(["role": .string("tool"), "tool_call_id": block["tool_use_id"] ?? .string(""),
                                         "content": .string(text)]))
            case "text":
                parts.append(.object(["type": .string("text"), "text": block["text"] ?? .string("")]))
            case "image":
                guard let source = block["source"], let data = source["data"]?.string else { continue }
                let type = source["media_type"]?.string ?? "image/jpeg"
                parts.append(.object(["type": .string("image_url"),
                                      "image_url": .object(["url": .string("data:\(type);base64,\(data)")])]))
            default:
                break
            }
        }
        if !parts.isEmpty { messages.append(.object(["role": .string("user"), "content": .array(parts)])) }
        return messages
    }
}

// MARK: Streaming

/// Builds the reply from the stream's chunks: text, tool calls by index, reasoning, cited pages, the finish reason
/// and usage.
public struct OpenRouterStreamAccumulator: Sendable {
    public private(set) var model: String?
    public private(set) var finishReason: String?
    public private(set) var usage: [String: JSONValue] = [:]
    public private(set) var error: ClaudeError?
    public private(set) var text = ""
    private var calls: [Int: (id: String, name: String, arguments: String)] = [:]
    private var reasoning: [[String: JSONValue]] = []
    private var citations: [JSONValue] = []
    private var citedURLs = Set<String>()

    public init() {}

    /// The Claude API's stop reason for the finish reason ("tool_calls" → "tool_use", "length" → "max_tokens", …).
    public var stopReason: String? {
        if !calls.isEmpty { return "tool_use" }
        switch finishReason {
        case nil: return nil
        case "stop", "end_turn": return "end_turn"
        case "length": return "max_tokens"
        case "content_filter": return "refusal"
        case "tool_calls": return "end_turn"
        case let other?: return other
        }
    }

    /// The reply as Claude API content blocks: the reasoning, the text (citing its pages), then the tool calls.
    public var content: [JSONValue] {
        var blocks: [JSONValue] = []
        if !reasoning.isEmpty {
            blocks.append(.object(["type": .string(OpenRouterAPI.reasoningBlock), "details": .array(reasoning.map(JSONValue.object))]))
        }
        if !text.isEmpty {
            var block: [String: JSONValue] = ["type": .string("text"), "text": .string(text)]
            if !citations.isEmpty { block["citations"] = .array(citations) }
            blocks.append(.object(block))
        }
        for index in calls.keys.sorted() {
            guard let call = calls[index] else { continue }
            blocks.append(.object(["type": .string("tool_use"), "id": .string(call.id), "name": .string(call.name),
                                   "input": Self.input(call.arguments)]))
        }
        return blocks
    }

    /// A call's arguments as JSON (an empty object when they're missing or cut off: the tool then says what's wrong).
    static func input(_ arguments: String) -> JSONValue {
        guard !arguments.isEmpty, let value = try? JSONDecoder().decode(JSONValue.self, from: Data(arguments.utf8)),
              value.object != nil else { return .object([:]) }
        return value
    }

    /// Handles one SSE `data:` payload.
    public mutating func handle(data: String) -> [ClaudeStreamEvent] {
        guard data != "[DONE]", let chunk = try? JSONDecoder().decode(JSONValue.self, from: Data(data.utf8)) else { return [] }
        if let m = chunk["model"]?.string { model = m }
        if let u = chunk["usage"]?.object { usage = u }
        if let e = chunk["error"], e != .null {
            error = .api(e["message"]?.string ?? "The reply was cut off.")
            return []
        }
        guard let choice = chunk["choices"]?.array?.first else { return [] }
        var events: [ClaudeStreamEvent] = []
        let delta = choice["delta"] ?? choice["message"] ?? .object([:])
        if let piece = delta["content"]?.string, !piece.isEmpty {
            text += piece
            events.append(.text(piece))
        }
        for detail in delta["reasoning_details"]?.array ?? [] {
            if let detail = detail.object { addReasoning(detail) }
        }
        for call in delta["tool_calls"]?.array ?? [] {
            let index = call["index"]?.int ?? calls.count
            var entry = calls[index] ?? ("", "", "")
            if let id = call["id"]?.string, !id.isEmpty { entry.id = id }
            if let name = call["function"]?["name"]?.string, !name.isEmpty {
                if entry.name.isEmpty { events.append(.toolStarted(name: name)) }
                entry.name = name
            }
            entry.arguments += call["function"]?["arguments"]?.string ?? ""
            if entry.id.isEmpty { entry.id = "call_\(index)" }
            calls[index] = entry
        }
        for annotation in (delta["annotations"]?.array ?? []) where annotation["type"]?.string == "url_citation" {
            let cited = annotation["url_citation"] ?? annotation
            guard let url = cited["url"]?.string, citedURLs.insert(url).inserted else { continue }
            var citation: [String: JSONValue] = ["type": .string("web_search_result_location"), "url": .string(url)]
            if let title = cited["title"]?.string, !title.isEmpty { citation["title"] = .string(title) }
            citations.append(.object(citation))
        }
        if let reason = choice["finish_reason"]?.string {
            if reason == "error" {
                error = .api(chunk["error"]?["message"]?.string ?? "The reply was cut off.")
                return events
            }
            guard finishReason == nil else { return events }
            finishReason = reason
            for index in calls.keys.sorted() {
                guard let call = calls[index], !call.name.isEmpty else { continue }
                events.append(.toolInput(name: call.name, input: Self.input(call.arguments)))
            }
        }
        return events
    }

    /// Reasoning streams in pieces; consecutive pieces of one detail (same index and type) are joined, the rest kept
    /// in order.
    private mutating func addReasoning(_ detail: [String: JSONValue]) {
        if var last = reasoning.last, last["type"] == detail["type"], last["index"] == detail["index"], detail["index"] != nil {
            for field in ["text", "summary", "data"] {
                if let piece = detail[field]?.string { last[field] = .string((last[field]?.string ?? "") + piece) }
            }
            for (key, value) in detail where !["text", "summary", "data"].contains(key) && value != .null { last[key] = value }
            reasoning[reasoning.count - 1] = last
        } else {
            reasoning.append(detail)
        }
    }

    /// What the reply cost: OpenRouter's own figure (`usage.cost`, dollars) when it gives one, else estimated at the
    /// model's list prices.
    public func tally(estimatingWith model: RadioDJModel) -> RadioDJTally {
        var tally = RadioDJTally()
        tally.requests = 1
        let prompt = usage["prompt_tokens"]?.int ?? 0
        let cached = usage["prompt_tokens_details"]?["cached_tokens"]?.int ?? 0
        let written = usage["prompt_tokens_details"]?["cache_write_tokens"]?.int ?? 0
        tally.inputTokens = max(0, prompt - cached - written)
        tally.cacheReadTokens = cached
        tally.cacheWriteTokens = written
        tally.outputTokens = usage["completion_tokens"]?.int ?? 0
        tally.webSearches = usage["server_tool_use"]?["web_search_requests"]?.int ?? 0
        if let cost = OpenRouterModelParser.number(usage["cost"]), cost.isFinite, cost >= 0 {
            tally.dollars = cost
        } else {
            tally.dollars = (Double(tally.inputTokens + written) * model.inputPrice + Double(tally.outputTokens) * model.outputPrice
                             + Double(cached) * (model.cacheReadPrice ?? model.inputPrice)) / 1_000_000
                + Double(tally.webSearches) * (model.webSearchPrice ?? 0)
        }
        return tally
    }
}

public struct OpenRouterClient: RadioDJClient {
    public let apiKey: String
    /// The model the DJ talks with, for estimating a reply's cost when OpenRouter doesn't say.
    public let model: RadioDJModel
    let transport: any ClaudeTransport

    public init(apiKey: String, model: RadioDJModel, transport: any ClaudeTransport = URLSessionClaudeTransport()) {
        self.apiKey = apiKey; self.model = model; self.transport = transport
    }

    public func reply(to request: ClaudeRequest, onEvent: @Sendable (ClaudeStreamEvent) async -> Void) async throws -> RadioDJReply {
        let urlRequest = OpenRouterAPI.request(OpenRouterAPI.chatURL, apiKey: apiKey, body: try OpenRouterAPI.body(request))
        var reply = OpenRouterStreamAccumulator()
        do {
            for try await line in try await transport.lines(for: urlRequest) {
                // Comments (": OPENROUTER PROCESSING") keep the connection open while the model thinks.
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                for event in reply.handle(data: payload) { await onEvent(event) }
                if let error = reply.error { throw error }
            }
        } catch let error as HTTPStatusError {
            throw OpenRouterAPI.describe(status: error.status, body: error.body)
        } catch ClaudeError.connection(let message) {
            throw ClaudeError.api("Couldn't reach OpenRouter: \(message)")
        }
        guard reply.stopReason != nil || !reply.content.isEmpty else { throw ClaudeError.api("The reply was cut off.") }
        return RadioDJReply(model: reply.model, stopReason: reply.stopReason ?? "end_turn", content: reply.content,
                            tally: reply.tally(estimatingWith: model))
    }

    /// Checks the key with a free request (the key's own details).
    public func checkKey() async throws {
        let (data, response) = try await transport.data(for: OpenRouterAPI.request(OpenRouterAPI.keyURL, apiKey: apiKey))
        guard response.statusCode == 200 else { throw OpenRouterAPI.describe(status: response.statusCode, body: data) }
    }

    /// Every model the DJ can use on OpenRouter, with prices.
    public func models() async throws -> [RadioDJModel] {
        let (data, response) = try await transport.data(for: OpenRouterAPI.request(OpenRouterAPI.modelsURL, apiKey: apiKey))
        guard response.statusCode == 200 else { throw OpenRouterAPI.describe(status: response.statusCode, body: data) }
        return try OpenRouterModelParser.parse(data)
    }
}
