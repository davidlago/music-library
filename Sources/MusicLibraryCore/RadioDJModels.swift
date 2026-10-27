import Foundation

/// Where the Radio DJ's model runs: Anthropic's Claude API with its key, or OpenRouter (https://openrouter.ai), which
/// serves Claude and many other models with one key.
public enum RadioDJProvider: String, Codable, CaseIterable, Sendable {
    case anthropic
    case openRouter

    public var name: String {
        switch self {
        case .anthropic: "Anthropic"
        case .openRouter: "OpenRouter"
        }
    }
}

/// The model the DJ talks with, picked in the Mac's Settings and handed to the phone with each sync. Prices are list
/// prices in dollars per million tokens (Anthropic's from `ClaudePrice`, OpenRouter's from its models list), for
/// showing and estimating; OpenRouter's replies also say what they actually cost.
public struct RadioDJModel: Codable, Hashable, Sendable, Identifiable {
    public var provider: RadioDJProvider
    /// The API's model ID ("claude-opus-5-5", "openai/gpt-5.2").
    public var id: String
    public var name: String
    public var inputPrice: Double
    public var outputPrice: Double
    /// Cached input, when the provider says (nil: not cached, or unknown).
    public var cacheReadPrice: Double?
    /// One web search, in dollars (nil: unknown).
    public var webSearchPrice: Double?
    /// Takes photos (image input).
    public var acceptsImages: Bool
    /// The context window in tokens (nil: unknown).
    public var contextLength: Int?

    public init(provider: RadioDJProvider, id: String, name: String, inputPrice: Double, outputPrice: Double,
                cacheReadPrice: Double? = nil, webSearchPrice: Double? = nil, acceptsImages: Bool = true,
                contextLength: Int? = nil) {
        self.provider = provider; self.id = id; self.name = name; self.inputPrice = inputPrice
        self.outputPrice = outputPrice; self.cacheReadPrice = cacheReadPrice; self.webSearchPrice = webSearchPrice
        self.acceptsImages = acceptsImages; self.contextLength = contextLength
    }

    /// The selection's identity across providers (the same ID could be on both).
    public var key: String { "\(provider.rawValue):\(id)" }

    /// "$4 in · $20 out per million tokens".
    public var priceSummary: String {
        if inputPrice == 0, outputPrice == 0 { return "Free" }
        return "\(Self.price(inputPrice)) in · \(Self.price(outputPrice)) out per million tokens"
    }

    /// "$4", "$0.10", "$0.075", "$0".
    public static func price(_ dollars: Double) -> String {
        if dollars == 0 { return "$0" }
        if dollars >= 1, dollars.rounded() == dollars { return String(format: "$%.0f", dollars) }
        if dollars >= 0.1 { return String(format: "$%.2f", dollars) }
        return "$" + String(format: "%.4f", dollars).replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
    }

    // MARK: Claude API

    /// The Claude models the DJ runs well on (current, with web search and photos), best for it first.
    public static let anthropic: [RadioDJModel] = [
        claude("claude-opus-5-5", "Claude Opus 5.5"),
        claude("claude-fable-5-1", "Claude Fable 5.1"),
        claude("claude-sonnet-5-5", "Claude Sonnet 5.5"),
        claude("claude-haiku-5-5", "Claude Haiku 5.5"),
    ]

    /// What the DJ ran on before it could be chosen.
    public static let `default` = anthropic[0]

    private static func claude(_ id: String, _ name: String) -> RadioDJModel {
        let price = ClaudePrice.forModel(id)
        return RadioDJModel(provider: .anthropic, id: id, name: name, inputPrice: price.input, outputPrice: price.output,
                            cacheReadPrice: price.cacheRead, webSearchPrice: ClaudePrice.webSearch, contextLength: 1_000_000)
    }

    /// Claude API request options that differ by model: Claude Haiku 5.5 takes no `fallbacks` (its refusals have no
    /// server-side fallback), and the web tools with dynamic filtering need Claude Opus or Sonnet 4.6 and later (or Fable).
    var claudeServerFallback: Bool { !id.hasPrefix("claude-haiku") }
    var claudeDynamicWebTools: Bool { !id.hasPrefix("claude-haiku") }

    // MARK: Saved choice

    /// User defaults key of the chosen model (JSON) on the Mac and the phone.
    public static let defaultsKey = "radioDJModel"

    public static func load(from defaults: UserDefaults = .standard) -> RadioDJModel {
        defaults.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(RadioDJModel.self, from: $0) }.map(\.sanitized) ?? .default
    }

    public func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }

    /// Values from defaults or another device, kept within reason (prices are only shown and estimated with).
    public var sanitized: RadioDJModel {
        var model = self
        model.id = String(id.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        model.name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        if model.name.isEmpty { model.name = model.id }
        func clean(_ price: Double) -> Double { price.isFinite && price >= 0 ? min(price, 10_000) : 0 }
        model.inputPrice = clean(inputPrice); model.outputPrice = clean(outputPrice)
        model.cacheReadPrice = cacheReadPrice.map(clean); model.webSearchPrice = webSearchPrice.map(clean)
        if let length = contextLength, length <= 0 { model.contextLength = nil }
        if model.id.isEmpty { return .default }
        // A Claude model chosen by an earlier list: the prices of today's.
        if provider == .anthropic, let known = Self.anthropic.first(where: { $0.id == model.id }) { return known }
        return model
    }
}

// MARK: OpenRouter's models

/// Reads OpenRouter's models list (`GET /api/v1/models`): every text model that can use tools (the DJ searches the
/// collection with them), with its prices per token turned into per million.
public enum OpenRouterModelParser {
    public static func parse(_ data: Data) throws -> [RadioDJModel] {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data), let list = root["data"]?.array else {
            throw ClaudeError.api("OpenRouter's model list couldn't be read.")
        }
        var seen = Set<String>()
        return list.compactMap { entry -> RadioDJModel? in
            // `:batch` variants are only for OpenRouter's batch API, which can't stream a reply.
            guard let id = entry["id"]?.string, !id.isEmpty, !id.hasSuffix(":batch"), seen.insert(id).inserted,
                  let pricing = entry["pricing"], let input = perMillion(pricing["prompt"]),
                  let output = perMillion(pricing["completion"]) else { return nil }
            let parameters = Set(entry["supported_parameters"]?.array?.compactMap(\.string) ?? [])
            guard parameters.contains("tools") else { return nil }
            let outputs = entry["architecture"]?["output_modalities"]?.array?.compactMap(\.string) ?? ["text"]
            guard outputs.contains("text") else { return nil }
            let inputs = entry["architecture"]?["input_modalities"]?.array?.compactMap(\.string) ?? []
            // Negative prices mark router models priced per request ("openrouter/auto"); they can't be estimated.
            guard input >= 0, output >= 0 else { return nil }
            let search = number(pricing["web_search"]).flatMap { $0 > 0 ? $0 : nil }
            return RadioDJModel(provider: .openRouter, id: id, name: entry["name"]?.string ?? id,
                                inputPrice: input, outputPrice: output,
                                cacheReadPrice: perMillion(pricing["input_cache_read"]).flatMap { $0 > 0 ? $0 : nil },
                                webSearchPrice: search, acceptsImages: inputs.contains("image"),
                                contextLength: entry["context_length"]?.int).sanitized
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Prices are strings of dollars per token ("0.000004").
    static func number(_ value: JSONValue?) -> Double? {
        switch value {
        case .string(let s): Double(s)
        case .number(let n): n
        default: nil
        }
    }

    static func perMillion(_ value: JSONValue?) -> Double? {
        number(value).map { ($0 * 1_000_000 * 1_000_000).rounded() / 1_000_000 }
    }
}
