import Foundation

/// Several reads of one CD track combined sample by sample: where they differ, the value most reads agree on (the first
/// read's on a tie). A damaged spot reads differently each time while the rest reads the same, so a misread track can
/// come out right when the drive reads each sample right more often than not. Only the first read is kept whole; later
/// reads add only where they differ from it.
public struct ReadVote: Sendable {
    public private(set) var reads = 1
    private let first: [UInt32]
    /// The values later reads gave where they differed from the first, by sample.
    private var others: [Int: [UInt32]] = [:]

    public init(first: [UInt32]) { self.first = first }

    /// Samples at which the reads don't all agree.
    public var disagreements: Int { others.count }

    /// Adds a read of the same track; returns whether it's identical to the first. A read of another length isn't
    /// counted.
    @discardableResult
    public mutating func add(_ read: [UInt32]) -> Bool {
        guard read.count == first.count else { return false }
        reads += 1
        let base = first
        var differing: [(Int, UInt32)] = []
        read.withUnsafeBufferPointer { r in
            base.withUnsafeBufferPointer { f in
                for i in 0..<f.count where r[i] != f[i] { differing.append((i, r[i])) }
            }
        }
        for (i, value) in differing { others[i, default: []].append(value) }
        return differing.isEmpty
    }

    /// The combined track.
    public var result: [UInt32] {
        var out = first
        for (i, values) in others {
            var counts: [UInt32: Int] = [first[i]: reads - values.count]
            for v in values { counts[v, default: 0] += 1 }
            var best = first[i], bestCount = counts[first[i]] ?? 0
            for v in values where (counts[v] ?? 0) > bestCount {
                best = v
                bestCount = counts[v] ?? 0
            }
            out[i] = best
        }
        return out
    }
}
