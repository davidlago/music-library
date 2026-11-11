import Foundation

/// A copy's matrix/runout codes, one entry per side: a record's sides A, B, C… (two per disc), a CD's one per disc.
/// Stored as `CollectionItem.runouts`, a JSON array in `collection_items.runout_sides`.
public enum RunoutSides {
    /// The most sides kept (99 records), and the longest text kept for one side.
    public static let maxSides = 198, maxLength = 500

    /// How many sides a copy has room for: two per record, one per CD (one disc when the count isn't known), and
    /// never fewer than it already has text for.
    public static func count(medium: CollectionMedium, discs: Int?, filled: Int = 0) -> Int {
        let discs = discs.flatMap { (1...99).contains($0) ? $0 : nil } ?? 1
        let sides = medium == .vinyl ? discs * 2 : medium == .cd ? discs : 0
        return min(max(sides, filled), maxSides)
    }

    /// "Side A", "Side B"… for a record (past Z, "Side 27"); "Disc 2" for a CD of several discs, "Disc" for one.
    public static func name(_ index: Int, medium: CollectionMedium, count: Int) -> String {
        if medium == .vinyl {
            guard index < 26, let letter = UnicodeScalar(65 + index) else { return "Side \(index + 1)" }
            return "Side \(Character(letter))"
        }
        return count <= 1 ? "Disc" : "Disc \(index + 1)"
    }

    /// Each side trimmed and clipped, at most `maxSides`, and the blank sides at the end dropped (none left: empty).
    public static func normalized(_ sides: [String]) -> [String] {
        var out = sides.prefix(maxSides).map { CollectionItem.clip($0, maxLength) }
        while out.last?.isEmpty == true { out.removeLast() }
        return out
    }

    /// The JSON written to `runout_sides`, nil for none.
    static func encode(_ sides: [String]) -> String? {
        let sides = normalized(sides)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        guard !sides.isEmpty, let data = try? encoder.encode(sides) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Read back from `runout_sides`, untrusted: anything but an array of at most `maxSides` strings, each at most
    /// `maxLength` once trimmed, reads as none.
    static func decode(_ text: String?) -> [String] {
        guard let text, text.utf8.count <= maxSides * maxLength * 4 + 1024, let data = text.data(using: .utf8),
              let sides = try? JSONDecoder().decode([String].self, from: data), sides.count <= maxSides
        else { return [] }
        let trimmed = sides.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard trimmed.allSatisfy({ $0.count <= maxLength }) else { return [] }
        return normalized(trimmed)
    }

    /// The side Discogs says a runout is on ("Side A", "Side B, variant 1", "A-side", "Runout B, stamped", "Side 2",
    /// "Disc 2", "CD2"), as an index, when it says so.
    public static func side(of code: DiscogsIdentifier, medium: CollectionMedium) -> Int? {
        let text = code.description
        if medium == .vinyl {
            if let m = text.firstMatch(of: /(?i)\bside\s*([A-Z])\b/) ?? text.firstMatch(of: /(?i)\b([A-Z])[\s-]*side\b/)
                ?? text.firstMatch(of: /(?i)\b(?:runout|matrix|label)\s+([A-Z])\b/) {
                return letterIndex(m.1)
            }
            if let m = text.firstMatch(of: /(?i)\bside\s*(\d{1,3})\b/), let n = Int(m.1), n >= 1 { return n - 1 }
        } else if medium == .cd {
            if let m = text.firstMatch(of: /(?i)\b(?:disc|disk|cd)\s*(\d{1,2})\b/), let n = Int(m.1), n >= 1 { return n - 1 }
        }
        return nil
    }

    private static func letterIndex(_ s: Substring) -> Int? {
        guard let c = s.uppercased().unicodeScalars.first, ("A"..."Z").contains(c) else { return nil }
        return Int(c.value) - 65
    }
}

/// One side of a copy, for showing its runout.
public struct RunoutSide: Identifiable, Hashable, Sendable {
    public var index: Int
    public var name: String
    public var text: String
    public var id: Int { index }
}

extension CollectionItem {
    /// How many runout sides the copy has room for (`RunoutSides.count`).
    public var runoutSideCount: Int {
        RunoutSides.count(medium: medium, discs: discCount, filled: runouts.count)
    }

    /// Every side the copy has room for, blank or not (`filled`: only those with text), named.
    public func runoutSides(filled: Bool = false) -> [RunoutSide] {
        let count = runoutSideCount
        return (0..<count).compactMap { i in
            let text = i < runouts.count ? runouts[i] : ""
            if filled && text.isEmpty { return nil }
            return RunoutSide(index: i, name: RunoutSides.name(i, medium: medium, count: count), text: text)
        }
    }

    /// The runout on one side, blank when there's none.
    public func runout(side: Int) -> String { side >= 0 && side < runouts.count ? runouts[side] : "" }

    /// Sets one side's runout (nil or blank clears it), keeping the others.
    public mutating func setRunout(_ text: String?, side: Int) {
        guard side >= 0, side < RunoutSides.maxSides else { return }
        var sides = runouts
        if sides.count <= side { sides += Array(repeating: "", count: side + 1 - sides.count) }
        sides[side] = text ?? ""
        runouts = RunoutSides.normalized(sides)
    }

    /// The sides with text, one per line, "Side A: XSM 47326", for a read-only list.
    public var runoutSummary: String? {
        let sides = runoutSides(filled: true)
        return sides.isEmpty ? nil : sides.map { "\($0.name): \($0.text)" }.joined(separator: "\n")
    }
}
