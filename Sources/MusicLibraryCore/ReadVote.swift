import Foundation

/// Several reads of one CD track combined sample by sample: where they differ, the value most reads agree on (the first
/// read's on a tie). A damaged spot reads differently each time while the rest reads the same, so a misread track can
/// come out right when the drive reads each sample right more often than not; when it doesn't, `spots` gives each read's
/// version of the damaged spots, for `AccurateRipVerifier.repair` to try in combination. Only the first read is kept
/// whole; later reads add only where they differ from it.
public struct ReadVote: Sendable {
    /// A damaged spot: disputed samples less than a sector apart, with the versions of them the reads gave (the
    /// vote's first, then the others in the order they were first read).
    public struct Spot: Sendable, Equatable {
        public let positions: [Int]
        public let versions: [[UInt32]]
    }

    public private(set) var reads = 1
    private let first: [UInt32]
    /// The values later reads (numbered from 1) gave where they differed from the first, by sample.
    private var others: [Int: [(read: Int, value: UInt32)]] = [:]

    public init(first: [UInt32]) { self.first = first }

    /// Samples at which the reads don't all agree.
    public var disagreements: Int { others.count }

    /// Adds a read of the same track; returns whether it's identical to the first. A read of another length isn't
    /// counted.
    @discardableResult
    public mutating func add(_ read: [UInt32]) -> Bool {
        guard read.count == first.count else { return false }
        let base = first, number = reads
        var differing: [(Int, UInt32)] = []
        read.withUnsafeBufferPointer { r in
            base.withUnsafeBufferPointer { f in
                for i in 0..<f.count where r[i] != f[i] { differing.append((i, r[i])) }
            }
        }
        reads += 1
        for (i, value) in differing { others[i, default: []].append((number, value)) }
        return differing.isEmpty
    }

    /// The combined track.
    public var result: [UInt32] {
        var out = first
        for i in others.keys { out[i] = voted(at: i) }
        return out
    }

    private func voted(at i: Int) -> UInt32 {
        guard let values = others[i] else { return first[i] }
        var counts: [UInt32: Int] = [first[i]: reads - values.count]
        for v in values { counts[v.value, default: 0] += 1 }
        var best = first[i], bestCount = counts[first[i]] ?? 0
        for v in values where (counts[v.value] ?? 0) > bestCount {
            best = v.value
            bestCount = counts[v.value] ?? 0
        }
        return best
    }

    /// The damaged spots, in order.
    public func spots() -> [Spot] {
        var groups: [[Int]] = []
        for i in others.keys.sorted() {
            if let last = groups.last?.last, i - last < AccurateRip.samplesPerSector { groups[groups.count - 1].append(i) } else { groups.append([i]) }
        }
        return groups.map { positions in
            var versions = [positions.map(voted(at:))]
            for read in 0..<reads {
                let version = positions.map { p in others[p]?.first(where: { $0.read == read })?.value ?? first[p] }
                if !versions.contains(version) { versions.append(version) }
            }
            return Spot(positions: positions, versions: versions)
        }
    }
}
