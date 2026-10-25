import Foundation

/// A small client for the Claude Messages API (https://api.anthropic.com/v1/messages), used by the Radio DJ. There's
/// no official Swift SDK, so requests are plain HTTPS with server-sent events. Content blocks are kept as raw JSON
/// (`JSONValue`) and sent back unchanged on the next turn: thinking blocks, web search results and their
/// signatures must round-trip exactly.
public enum ClaudeAPI {
    public static let messagesURL = URL(string: "https://api.anthropic.com/v1/messages")!
    public static let modelsURL = URL(string: "https://api.anthropic.com/v1/models?limit=1")!
    public static let version = "2026-10-21"
    /// `fallbacks: "default"`: a request the model's safety classifiers decline is retried on the model Anthropic
    /// recommends for that kind of refusal instead of failing.
    public static let fallbackBeta = "server-side-fallback-2026-07-01"

    public static func request(_ url: URL, apiKey: String, body: Data? = nil, beta: [String] = []) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpBody = body
        request.timeoutInterval = 600
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(version, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if !beta.isEmpty { request.setValue(beta.joined(separator: ","), forHTTPHeaderField: "anthropic-beta") }
        return request
    }

    /// The API's error body (`{"type":"error","error":{"type":…,"message":…}}`) as something to show.
    static func describe(status: Int, body: Data) -> ClaudeError {
        let error = (try? JSONDecoder().decode(JSONValue.self, from: body))?["error"]
        let message = error?["message"]?.string
        switch status {
        case 401, 403: return .unauthorized
        case 429: return .rateLimited
        case 529, 500...599: return .overloaded
        case 402: return .api(message ?? "Your API account is out of credit.")
        default: return .api(message ?? "The Claude API answered with HTTP \(status).")
        }
    }
}

public enum ClaudeError: Error, LocalizedError, Equatable {
    case unauthorized
    case rateLimited
    case overloaded
    case refused
    case api(String)
    case connection(String)

    public var errorDescription: String? {
        switch self {
        case .unauthorized: return "The Claude API key was refused. Check it in Settings."
        case .rateLimited: return "Too many requests to the Claude API right now. Try again in a minute."
        case .overloaded: return "Claude is busy right now. Try again in a moment."
        case .refused: return "That one's off the air: Claude declined to answer it."
        case .api(let m): return m
        case .connection(let m): return "Couldn't reach the Claude API: \(m)"
        }
    }
}

// MARK: JSON

/// Any JSON value, for content blocks passed back to the API unchanged.
public enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n):
            // Whole numbers go out as integers (token counts, indexes), as they came in.
            if n.rounded() == n, abs(n) < 1e15 { try c.encode(Int64(n)) } else { try c.encode(n) }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var int: Int? { if case .number(let n) = self { return Int(exactly: n.rounded()) }; return nil }
    public var array: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    public var object: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
}

// MARK: Conversation

/// One turn as the API takes it back: the role and its content blocks.
public struct ClaudeMessage: Codable, Hashable, Sendable {
    public var role: String
    public var content: [JSONValue]

    public init(role: String, content: [JSONValue]) { self.role = role; self.content = content }

    public static func user(_ text: String) -> ClaudeMessage {
        ClaudeMessage(role: "user", content: [.object(["type": .string("text"), "text": .string(text)])])
    }
}

/// The request body for one streamed turn.
public struct ClaudeRequest: Sendable {
    public var model: String
    public var maxTokens: Int
    public var system: [String]
    public var messages: [ClaudeMessage]
    public var tools: [JSONValue]

    public init(model: String, maxTokens: Int, system: [String], messages: [ClaudeMessage], tools: [JSONValue] = []) {
        self.model = model; self.maxTokens = maxTokens; self.system = system; self.messages = messages; self.tools = tools
    }

    public func body() throws -> Data {
        var body: [String: JSONValue] = [
            "model": .string(model),
            "max_tokens": .number(Double(maxTokens)),
            "stream": .bool(true),
            "system": .array(system.map { .object(["type": .string("text"), "text": .string($0)]) }),
            "messages": .array(messages.map { .object(["role": .string($0.role), "content": .array($0.content)]) }),
            // Each turn resends the conversation; caching keeps the repeated part cheap.
            "cache_control": .object(["type": .string("ephemeral")]),
            "fallbacks": .string("default"),
        ]
        if !tools.isEmpty { body["tools"] = .array(tools) }
        return try JSONEncoder().encode(JSONValue.object(body))
    }
}

// MARK: Streaming

/// Something to show while a reply streams in.
public enum ClaudeStreamEvent: Equatable, Sendable {
    case text(String)
    /// A tool started: a server tool (web search, web fetch) or one the app runs (`tool_use`); its input arrives with
    /// `toolInput`.
    case toolStarted(name: String)
    case toolInput(name: String, input: JSONValue)
}

/// Builds the reply from the stream's events: content blocks by index, the stop reason and usage.
public struct ClaudeStreamAccumulator: Sendable {
    public private(set) var model: String?
    public private(set) var stopReason: String?
    public private(set) var usage: [String: JSONValue] = [:]
    public private(set) var error: ClaudeError?
    private var blocks: [Int: [String: JSONValue]] = [:]
    private var partialJSON: [Int: String] = [:]

    public init() {}

    /// The reply's content blocks, in order.
    public var content: [JSONValue] { blocks.keys.sorted().compactMap { blocks[$0].map(JSONValue.object) } }

    /// The text blocks joined: what the reply says.
    public var text: String {
        content.filter { $0["type"]?.string == "text" }.compactMap { $0["text"]?.string }.joined()
    }

    static func isToolCall(_ block: [String: JSONValue]) -> Bool {
        block["type"]?.string == "server_tool_use" || block["type"]?.string == "tool_use"
    }

    /// The tool calls the app has to run (`tool_use` blocks; server tools have run already).
    public var toolCalls: [JSONValue] { content.filter { $0["type"]?.string == "tool_use" } }

    /// Handles one SSE `data:` payload.
    public mutating func handle(data: String) -> [ClaudeStreamEvent] {
        guard let event = try? JSONDecoder().decode(JSONValue.self, from: Data(data.utf8)), let type = event["type"]?.string else { return [] }
        switch type {
        case "message_start":
            model = event["message"]?["model"]?.string
            if let u = event["message"]?["usage"]?.object { usage.merge(u) { $1 } }
        case "content_block_start":
            guard let index = event["index"]?.int, let block = event["content_block"]?.object else { return [] }
            blocks[index] = block
            if Self.isToolCall(block), let name = block["name"]?.string { return [.toolStarted(name: name)] }
            if block["type"]?.string == "text", let text = block["text"]?.string, !text.isEmpty { return [.text(text)] }
        case "content_block_delta":
            guard let index = event["index"]?.int, var block = blocks[index], let delta = event["delta"] else { return [] }
            defer { blocks[index] = block }
            switch delta["type"]?.string {
            case "text_delta":
                let piece = delta["text"]?.string ?? ""
                block["text"] = .string((block["text"]?.string ?? "") + piece)
                return piece.isEmpty ? [] : [.text(piece)]
            case "thinking_delta":
                block["thinking"] = .string((block["thinking"]?.string ?? "") + (delta["thinking"]?.string ?? ""))
            case "signature_delta":
                if let signature = delta["signature"] { block["signature"] = signature }
            case "input_json_delta":
                partialJSON[index, default: ""] += delta["partial_json"]?.string ?? ""
            case "citations_delta":
                if let citation = delta["citation"] { block["citations"] = .array((block["citations"]?.array ?? []) + [citation]) }
            default:
                break
            }
        case "content_block_stop":
            guard let index = event["index"]?.int, var block = blocks[index] else { return [] }
            if let json = partialJSON.removeValue(forKey: index) {
                let input = json.isEmpty ? JSONValue.object([:]) : (try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))) ?? .object([:])
                block["input"] = input
                blocks[index] = block
                if Self.isToolCall(block), let name = block["name"]?.string { return [.toolInput(name: name, input: input)] }
            }
        case "message_delta":
            if let reason = event["delta"]?["stop_reason"]?.string { stopReason = reason }
            if let u = event["usage"]?.object { usage.merge(u.filter { $0.value != .null }) { $1 } }
        case "error":
            let kind = event["error"]?["type"]?.string
            let message = event["error"]?["message"]?.string ?? "The reply was cut off."
            error = kind == "overloaded_error" ? .overloaded : kind == "rate_limit_error" ? .rateLimited : .api(message)
        default:
            break
        }
        return []
    }
}

/// Sends a request and hands back the response's lines; injectable for tests.
public protocol ClaudeTransport: Sendable {
    func lines(for request: URLRequest) async throws -> AsyncThrowingStream<String, Error>
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionClaudeTransport: ClaudeTransport {
    public init() {}

    public func lines(for request: URLRequest) async throws -> AsyncThrowingStream<String, Error> {
        let bytes: URLSession.AsyncBytes, response: URLResponse
        do { (bytes, response) = try await URLSession.shared.bytes(for: request) } catch {
            throw ClaudeError.connection(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var body = Data()
            for try await byte in bytes { body.append(byte); if body.count > 64_000 { break } }
            throw ClaudeAPI.describe(status: status, body: body)
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines { continuation.yield(line) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error is CancellationError ? error : ClaudeError.connection(error.localizedDescription))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            return (data, response as? HTTPURLResponse ?? HTTPURLResponse())
        } catch {
            throw ClaudeError.connection(error.localizedDescription)
        }
    }
}

public struct ClaudeClient: Sendable {
    public let apiKey: String
    let transport: any ClaudeTransport

    public init(apiKey: String, transport: any ClaudeTransport = URLSessionClaudeTransport()) {
        self.apiKey = apiKey; self.transport = transport
    }

    /// Streams one turn, calling `onEvent` as text and tool calls arrive, and returns the whole reply.
    public func stream(_ request: ClaudeRequest, onEvent: @Sendable (ClaudeStreamEvent) async -> Void) async throws -> ClaudeStreamAccumulator {
        let urlRequest = ClaudeAPI.request(ClaudeAPI.messagesURL, apiKey: apiKey, body: try request.body(), beta: [ClaudeAPI.fallbackBeta])
        var reply = ClaudeStreamAccumulator()
        for try await line in try await transport.lines(for: urlRequest) {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            for event in reply.handle(data: payload) { await onEvent(event) }
            if let error = reply.error { throw error }
        }
        return reply
    }

    /// Checks the key with a free request (the models list).
    public func checkKey() async throws {
        let (data, response) = try await transport.data(for: ClaudeAPI.request(ClaudeAPI.modelsURL, apiKey: apiKey))
        guard response.statusCode == 200 else { throw ClaudeAPI.describe(status: response.statusCode, body: data) }
    }
}
