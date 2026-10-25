import Foundation

/// The DJ's way to the Shop (Mac only, where the Shop is): the `open_shop` client tool. When the listener wants to
/// buy an album on CD or vinyl, the DJ calls it with what to look for; the app opens the Shop searching MusicBrainz
/// for it, and the tool's result tells the DJ which albums and how many editions came up, so it can point the
/// listener to the right one. The listener picks the edition and sees the copies for sale; nothing is bought.
public struct RadioDJShopRequest: Hashable, Sendable {
    public static let toolName = "open_shop"

    public var album: String
    public var artist: String
    public var format: ShopFormat
    /// A barcode or catalog number, when the DJ knows the exact edition's.
    public var code: String

    public init(album: String, artist: String, format: ShopFormat, code: String = "") {
        self.album = album; self.artist = artist; self.format = format; self.code = code
    }

    /// The Shop's search for it.
    public var query: CDSearchQuery { CDSearchQuery(album: album, artist: artist, code: code, format: format) }

    public static var tool: JSONValue {
        let description = """
        Open the app's Shop page searching for an album on CD or vinyl, so the listener can compare copies for sale \
        (new and used, from Discogs, eBay, CDandLP and Alibris, shipping to the US). Use it when the listener asks \
        for help finding, buying or pricing a copy, or agrees when you offer. The Shop searches MusicBrainz for the \
        album's editions in that format and shows them; the listener picks an edition (or any edition) there, and \
        nothing is bought. Give the album's title and artist as MusicBrainz would list them, and a barcode or \
        catalog number only when you're sure of the exact edition's. The result says what the search found.
        """
        let properties: [String: JSONValue] = [
            "album": .object(["type": .string("string"), "description": .string("The album's title.")]),
            "artist": .object(["type": .string("string"), "description": .string("The album's artist (empty for a various-artists compilation).")]),
            "format": .object(["type": .string("string"), "enum": .array(ShopFormat.allCases.map { .string($0.rawValue) }),
                               "description": .string("cd or vinyl: what the listener wants to buy.")]),
            "code": .object(["type": .string("string"), "description": .string("Optional: the exact edition's barcode or catalog number.")]),
        ]
        return .object([
            "name": .string(toolName),
            "description": .string(description),
            "input_schema": .object(["type": .string("object"), "properties": .object(properties),
                                     "required": .array([.string("album"), .string("artist"), .string("format")]),
                                     "additionalProperties": .bool(false)]),
            "eager_input_streaming": .bool(true),
        ])
    }

    /// The request in a tool call's input, or what's wrong with it (the input streams as it's written, so it's checked).
    public static func parse(_ input: JSONValue) -> Result<RadioDJShopRequest, ShopInputError> {
        guard let object = input.object else { return .failure(ShopInputError("the input must be an object")) }
        func text(_ key: String) -> String? {
            object[key]?.string.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)) }
        }
        guard let album = text("album"), let artist = text("artist") else {
            return .failure(ShopInputError("album and artist must be strings"))
        }
        guard let format = text("format").flatMap({ ShopFormat(rawValue: $0.lowercased()) }) else {
            return .failure(ShopInputError("format must be cd or vinyl"))
        }
        if object["code"] != nil, object["code"]?.string == nil { return .failure(ShopInputError("code must be a string")) }
        let request = RadioDJShopRequest(album: album, artist: artist, format: format, code: text("code") ?? "")
        guard !request.query.isEmpty else { return .failure(ShopInputError("give at least the album or the artist")) }
        return .success(request)
    }

    public struct ShopInputError: Error, Equatable, Sendable {
        public var message: String
        init(_ message: String) { self.message = message }
    }

    /// What the tool tells the DJ about the search the Shop ran: the albums found (at most `limit`) with their
    /// editions in the format, or that none were.
    public static func summary(_ albums: [CDAlbum], request: RadioDJShopRequest, error: String? = nil, limit: Int = 8) -> String {
        let format = request.format
        let looking = "The Shop is open, searching for \(format == .cd ? "CDs" : "vinyl records") of " +
            [request.album.isEmpty ? nil : "*\(request.album)*", request.artist.isEmpty ? nil : "by \(request.artist)"]
                .compactMap { $0 }.joined(separator: " ") + "."
        if let error { return "\(looking) The MusicBrainz search failed (\(error)); the listener can try again from the Shop page." }
        guard !albums.isEmpty else {
            return "\(looking) MusicBrainz lists no \(format.name) editions matching it; the page offers to search the stores by name instead, which finds copies of releases MusicBrainz doesn't list."
        }
        let rows = albums.prefix(limit).map { a -> String in
            var line = "- *\(a.title)* — \(a.artist)"
            let facts = [a.kind.isEmpty ? nil : a.kind, a.year.map(String.init),
                         a.editionsLoaded ? "\(a.editions.count) \(format.name) edition\(a.editions.count == 1 ? "" : "s")" : nil]
                .compactMap { $0 }
            if !facts.isEmpty { line += " (\(facts.joined(separator: ", ")))" }
            let years = a.editions.compactMap(\.year)
            if let first = years.min(), let last = years.max(), first != last { line += ", editions from \(first) to \(last)" }
            return line
        }
        let more = albums.count > limit ? "\n…and \(albums.count - limit) more." : ""
        return """
        \(looking) MusicBrainz found \(albums.count == 1 ? "1 album" : "\(albums.count) albums"):
        \(rows.joined(separator: "\n"))\(more)
        On the page the listener picks one edition, or any \(format.name) edition of an album, to see copies for sale and their prices.
        """
    }
}
