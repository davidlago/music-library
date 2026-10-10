import Foundation

public struct AudioFormat: Codable, Hashable, Sendable {
    public var codec: String
    public var sampleRate: Int?
    public var bitDepth: Int?
    public var bitrate: Int?
    public var channels: Int?

    public init(codec: String, sampleRate: Int? = nil, bitDepth: Int? = nil, bitrate: Int? = nil, channels: Int? = nil) {
        self.codec = codec; self.sampleRate = sampleRate; self.bitDepth = bitDepth
        self.bitrate = bitrate; self.channels = channels
    }

    public static let lossyCodecs: Set<String> = ["mp3", "aac", "vorbis", "opus", "wmav1", "wmav2", "ac3", "eac3"]

    public var codecLabel: String {
        let c = codec.lowercased()
        if c.hasPrefix("pcm") { return "PCM" }
        return c == "vorbis" ? "Vorbis" : c.uppercased()
    }

    public static func kHzString(_ rate: Double) -> String {
        var s = String(format: "%.2f", rate / 1000)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    public var summary: String {
        var tail: [String] = []
        if let bitDepth { tail.append("\(bitDepth)-bit") }
        else if let bitrate { tail.append("\((bitrate + 500) / 1000) kbps") }
        if let sampleRate { tail.append("\(Self.kHzString(Double(sampleRate))) kHz") }
        return tail.isEmpty ? codecLabel : "\(codecLabel) · " + tail.joined(separator: " / ")
    }

    /// e.g. "FLAC 24/96" or "MP3 320k".
    public var compact: String {
        if let bitDepth, let sampleRate { return "\(codecLabel) \(bitDepth)/\(Self.kHzString(Double(sampleRate)))" }
        if let bitrate { return "\(codecLabel) \((bitrate + 500) / 1000)k" }
        if let sampleRate { return "\(codecLabel) \(Self.kHzString(Double(sampleRate)))" }
        return codecLabel
    }
}

public struct PhysicalFormatOption: Hashable, Sendable {
    public var minRate: Double
    public var maxRate: Double
    public var bitDepth: Int
    public var isFloat: Bool
    public var isMixable: Bool
    public var isLinearPCM: Bool

    public init(minRate: Double, maxRate: Double, bitDepth: Int, isFloat: Bool = false, isMixable: Bool = true, isLinearPCM: Bool = true) {
        self.minRate = minRate; self.maxRate = maxRate; self.bitDepth = bitDepth
        self.isFloat = isFloat; self.isMixable = isMixable; self.isLinearPCM = isLinearPCM
    }
}

public enum OutputFormatChooser {
    static let tolerance = 0.5

    static func contains(_ r: ClosedRange<Double>, _ x: Double) -> Bool {
        x >= r.lowerBound - tolerance && x <= r.upperBound + tolerance
    }

    static func isInteger(_ x: Double) -> Bool { abs(x - x.rounded()) < 0.001 }

    public static func chooseSampleRate(source: Double, available: [ClosedRange<Double>]) -> Double? {
        guard !available.isEmpty, source > 0 else { return nil }
        if available.contains(where: { contains($0, source) }) { return source }

        var multiples: [Double] = []
        var divisors: [Double] = []
        for r in available {
            if r.lowerBound == r.upperBound {
                let ratio = r.lowerBound / source
                if ratio > 1, isInteger(ratio) { multiples.append(r.lowerBound) }
                let inverse = source / r.lowerBound
                if inverse > 1, isInteger(inverse) { divisors.append(r.lowerBound) }
            } else {
                for k in 2...16 {
                    let up = source * Double(k)
                    if contains(r, up) { multiples.append(up) }
                    let down = source / Double(k)
                    if contains(r, down) { divisors.append(down) }
                }
            }
        }
        if let m = multiples.min() { return m }
        if let d = divisors.max() { return d }
        let above = available.compactMap { $0.lowerBound > source ? $0.lowerBound : nil }
        if let a = above.min() { return a }
        return available.map(\.upperBound).max()
    }

    public static func choosePhysicalFormat(rate: Double, sourceBits: Int?, available: [PhysicalFormatOption]) -> Int? {
        let usable = available.enumerated().filter {
            $0.element.isLinearPCM && contains($0.element.minRate...max($0.element.minRate, $0.element.maxRate), rate)
        }
        guard !usable.isEmpty else { return nil }
        let depths = Set(usable.map { $0.element.bitDepth })
        let depth: Int
        if let bits = sourceBits {
            if depths.contains(bits) { depth = bits }
            else if let larger = depths.filter({ $0 > bits }).min() { depth = larger }
            else { depth = depths.max() ?? bits }
        } else {
            depth = depths.max() ?? 0
        }
        let best = usable.filter { $0.element.bitDepth == depth }.min { a, b in
            if a.element.isFloat != b.element.isFloat { return !a.element.isFloat }
            if a.element.isMixable != b.element.isMixable { return a.element.isMixable }
            return a.offset < b.offset
        }
        return best?.offset
    }
}

public struct OutputState: Hashable, Sendable {
    public var deviceName: String
    public var sampleRate: Double
    public var bitDepth: Int?
    public var sourceRate: Double
    public var matched: Bool

    public init(deviceName: String, sampleRate: Double, bitDepth: Int?, sourceRate: Double, matched: Bool) {
        self.deviceName = deviceName; self.sampleRate = sampleRate; self.bitDepth = bitDepth
        self.sourceRate = sourceRate; self.matched = matched
    }

    public var summary: String {
        var s = "\(deviceName) \(AudioFormat.kHzString(sampleRate)) kHz"
        if let bitDepth { s += " / \(bitDepth)-bit" }
        return s
    }
}
