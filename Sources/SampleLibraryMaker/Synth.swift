import Foundation

/// Deterministic randomness (SplitMix64), so the same seed always makes the same song, cover and history.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    init(_ text: String) {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in text.utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
        state = h
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// 0..<1
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func noise() -> Float { Float(unit() * 2 - 1) }
    mutating func range(_ r: ClosedRange<Double>) -> Double { r.lowerBound + unit() * (r.upperBound - r.lowerBound) }
    mutating func chance(_ p: Double) -> Bool { unit() < p }
    mutating func pick<T>(_ items: [T]) -> T { items[Int(next() % UInt64(items.count))] }
}

/// How an artist's songs sound: which instruments play and how.
struct SynthStyle: Sendable {
    enum Drums: Sendable { case none, brushes, pop, fourOnFloor, boomBap, oneDrop }
    enum Chords: Sendable { case pad, epiano, strum, skank }
    enum Voice: Sendable { case none, pluck, square, bell, epiano, sine }
    enum Bass: Sendable { case none, round, pulse, dub, folk }
    enum Scale: Sendable { case major, minor, dorian }

    var tempo: ClosedRange<Double>
    var scales: [Scale]
    var drums: Drums
    var chords: Chords
    var arp: Voice
    /// Sixteenth notes instead of eighths.
    var fastArp = false
    var lead: Voice
    var bass: Bass
    var swing = 0.0
    var reverb: Float = 0.25
    var echo = false
    var lofi = false
    /// Seconds, before rounding to whole bars.
    var length: ClosedRange<Double> = 40...52
}

/// Renders a short instrumental from a style and a seed: chords, a bass line, drums, an arpeggio and a melody built
/// from a repeated two-bar motif, through a small reverb. Everything is synthesized, so the result is original.
struct SongSynth {
    static let sampleRate = 44_100
    private let sr = Float(SongSynth.sampleRate)

    let style: SynthStyle
    private var rng: SeededRandom
    private var left: [Float] = []
    private var right: [Float] = []
    private var reverbSend: [Float] = []
    private var echoSend: [Float] = []

    private var tempo = 90.0
    private var root = 57
    private var scale: [Int] = []
    private var progression: [Int] = []
    private var bars = 16

    init(style: SynthStyle, seed: String) {
        self.style = style
        rng = SeededRandom(seed)
    }

    /// Interleaved stereo samples, -1...1.
    mutating func render() -> [Float] {
        tempo = rng.range(style.tempo).rounded()
        let kind = rng.pick(style.scales)
        scale = switch kind {
        case .major: [0, 2, 4, 5, 7, 9, 11]
        case .minor: [0, 2, 3, 5, 7, 8, 10]
        case .dorian: [0, 2, 3, 5, 7, 9, 10]
        }
        root = 50 + Int(rng.next() % 8)
        progression = kind == .major
            ? rng.pick([[0, 4, 5, 3], [0, 5, 3, 4], [5, 3, 0, 4], [0, 3, 0, 4], [3, 4, 0, 5], [0, 2, 3, 4]])
            : rng.pick([[0, 5, 2, 6], [0, 6, 5, 6], [0, 3, 6, 2], [0, 5, 3, 4], [0, 2, 6, 5]])
        let barSeconds = 240 / tempo
        bars = max(8, Int((rng.range(style.length) / barSeconds / 2).rounded()) * 2)
        let total = Int((Double(bars) * barSeconds + 3) * Double(sr))
        left = Array(repeating: 0, count: total)
        right = left
        reverbSend = left
        echoSend = left

        let intro = bars >= 14 ? 4 : 2
        let outro = 2
        let melody = makeMelody()
        for bar in 0..<bars {
            let chord = progression[bar % progression.count]
            let isBody = bar >= intro && bar < bars - outro
            playChords(bar: bar, degree: chord)
            if bar >= 1 && bar < bars - 1 { playArp(bar: bar, degree: chord) }
            if isBody {
                playBass(bar: bar, degree: chord)
                playDrums(bar: bar, fill: (bar - intro) % 8 == 7)
                let phrase = (bar - intro) / 4
                if bar >= intro + 2 || bars < 12, phrase % 3 != 2 || bars < 16 {
                    playMelody(melody[(bar - intro) % melody.count], bar: bar, degree: chord)
                }
            }
        }
        // The last chord rings out.
        playChords(bar: bars, degree: progression[0], final: true)
        return mixdown()
    }

    // MARK: Music

    private func midi(_ degree: Int, octave: Int = 0) -> Int {
        let d = ((degree % 7) + 7) % 7
        let o = (degree - d) / 7
        return root + 12 * (o + octave) + scale[d]
    }

    private func hz(_ midi: Int) -> Float { 440 * pow(2, Float(midi - 69) / 12) }

    private var beat: Double { 60 / tempo }

    private func time(bar: Int, step: Double, steps: Double = 16) -> Double {
        var t = Double(bar) * 4 * beat + step * 4 * beat / steps
        // Swing the off-beat eighths (or sixteenths).
        if style.swing > 0, steps >= 8, Int(step) % 2 == 1 { t += style.swing * 4 * beat / steps }
        return t
    }

    private func chordTones(_ degree: Int, seventh: Bool) -> [Int] {
        seventh ? [degree, degree + 2, degree + 4, degree + 6] : [degree, degree + 2, degree + 4]
    }

    private mutating func playChords(bar: Int, degree: Int, final: Bool = false) {
        let seventh = style.chords == .epiano || style.lofi
        let notes = chordTones(degree, seventh: seventh).map { midi($0) }
        let barLength = 4 * beat
        switch style.chords {
        case .pad:
            for (i, n) in notes.enumerated() {
                pad(hz(n), start: time(bar: bar, step: 0), length: final ? 3 : barLength, amp: 0.11, pan: Float(i - 1) * 0.3)
            }
            pad(hz(notes[0] - 12), start: time(bar: bar, step: 0), length: final ? 3 : barLength, amp: 0.07, pan: 0)
        case .epiano:
            let hits: [(Double, Double)] = final ? [(0, 3)] : rng.pick([[(0, 6), (6, 10)], [(0, 10), (10, 6)], [(0, 16)], [(0, 3), (3, 7), (10, 6)]])
            for (step, steps) in hits {
                for (i, n) in notes.enumerated() {
                    epiano(hz(n), start: time(bar: bar, step: step) + Double(i) * 0.012, length: steps * beat / 4, amp: 0.13,
                           pan: Float(i) * 0.2 - 0.3)
                }
            }
        case .strum:
            let pattern: [Double] = final ? [0] : [0, 4, 6, 8, 12, 14]
            for step in pattern {
                let down = Int(step) % 4 == 0
                let voicing = [notes[0] - 12] + notes + [notes[0] + 12]
                for (i, n) in (down ? voicing : voicing.reversed()).enumerated() {
                    pluck(hz(n), start: time(bar: bar, step: step) + Double(i) * 0.011, amp: down ? 0.12 : 0.07,
                          pan: Float(i) * 0.12 - 0.3, decay: 0.996)
                }
            }
        case .skank:
            if final {
                for n in notes { epiano(hz(n), start: time(bar: bar, step: 0), length: 2, amp: 0.1, pan: 0) }
                return
            }
            for step in [4.0, 12.0] {
                for (i, n) in notes.enumerated() {
                    epiano(hz(n + 12), start: time(bar: bar, step: step), length: 0.16, amp: 0.1, pan: 0.25 + Float(i) * 0.05,
                           echo: 0.5)
                }
            }
        }
    }

    private mutating func playArp(bar: Int, degree: Int) {
        guard style.arp != .none else { return }
        let tones = chordTones(degree, seventh: false)
        let shape = [0, 1, 2, 3, 2, 1, 0, 2]
        let steps = style.fastArp ? 16 : 8
        for s in 0..<steps {
            let i = shape[s % shape.count]
            let n = midi(tones[i % 3] + (i / 3) * 7, octave: 1)
            let start = time(bar: bar, step: Double(s), steps: Double(steps))
            let length = 4 * beat / Double(steps)
            let pan: Float = s % 2 == 0 ? -0.35 : 0.35
            voice(style.arp, hz(n), start: start, length: length * 0.9, amp: s % 4 == 0 ? 0.075 : 0.055, pan: pan)
        }
    }

    private mutating func playBass(bar: Int, degree: Int) {
        let r = midi(degree, octave: -1), fifth = midi(degree + 4, octave: -1)
        let pattern: [(step: Double, steps: Double, note: Int)]
        switch style.bass {
        case .none: return
        case .round: pattern = [(0, 6, r), (6, 4, r), (10, 6, fifth)]
        case .pulse: pattern = (0..<8).map { (Double($0 * 2), 1.6, $0 % 4 == 3 ? r + 12 : r) }
        case .dub: pattern = [(0, 3, r), (4, 2, r), (6, 2, fifth), (10, 4, midi(degree + 2, octave: -1)), (14, 2, r)]
        case .folk: pattern = [(0, 7, r), (8, 7, fifth)]
        }
        for p in pattern {
            bass(hz(p.note), start: time(bar: bar, step: p.step), length: p.steps * beat / 4)
        }
    }

    private mutating func playDrums(bar: Int, fill: Bool) {
        func at(_ step: Int) -> Double { time(bar: bar, step: Double(step)) }
        switch style.drums {
        case .none: return
        case .fourOnFloor:
            for s in [0, 4, 8, 12] { kick(at(s), amp: 0.9) }
            for s in [4, 12] { snare(at(s), amp: 0.45) }
            for s in 0..<16 { hat(at(s), amp: s % 4 == 2 ? 0.22 : 0.07, open: s % 4 == 2) }
        case .pop:
            for s in [0, 8, 10] { kick(at(s), amp: 0.8) }
            for s in [4, 12] { snare(at(s), amp: 0.5) }
            for s in stride(from: 0, to: 16, by: 2) { hat(at(s), amp: 0.1, open: false) }
        case .boomBap:
            for s in [0, 7, 10] { kick(at(s), amp: 0.85) }
            for s in [4, 12] { snare(at(s), amp: 0.55) }
            for s in stride(from: 0, to: 16, by: 2) { hat(at(s), amp: s % 4 == 0 ? 0.12 : 0.08, open: false) }
            if rng.chance(0.4) { snare(at(15), amp: 0.12) }
        case .brushes:
            for s in [0, 8] { kick(at(s), amp: 0.35) }
            for s in [4, 12] { rim(at(s), amp: 0.25) }
            for s in 0..<16 { shaker(at(s), amp: s % 2 == 0 ? 0.07 : 0.04) }
        case .oneDrop:
            kick(at(8), amp: 0.9)
            rim(at(8), amp: 0.35)
            for s in stride(from: 0, to: 16, by: 2) { hat(at(s), amp: 0.08, open: false) }
        }
        if fill && style.drums != .brushes {
            for s in [13, 14, 15] { snare(at(s), amp: 0.2 + Float(s - 13) * 0.1) }
        }
    }

    /// A melody note: step in sixteenths, length in sixteenths, scale degree above the root.
    private struct Note { var step: Double; var steps: Double; var degree: Int }

    /// Four-bar phrases from two motifs (A A' B A), on scale degrees that the chords bend toward.
    private mutating func makeMelody() -> [[Note]] {
        func motif() -> [[Note]] {
            var degree = 7 + Int(rng.next() % 5)
            return (0..<2).map { _ in
                let onsets: [Double] = rng.pick([[0, 4, 8, 12], [0, 6, 8, 12, 14], [0, 2, 4, 8], [0, 8, 12], [0, 4, 6, 10], [2, 4, 8, 14]])
                return onsets.enumerated().map { i, step in
                    let next = i + 1 < onsets.count ? onsets[i + 1] : 16
                    degree = min(13, max(4, degree + rng.pick([-2, -1, -1, 0, 1, 1, 2, 3, -3])))
                    return Note(step: step, steps: min(next - step, 8), degree: degree)
                }
            }
        }
        let a = motif(), b = motif()
        var a2 = a
        if var last = a2[1].last {
            last.degree = 7
            a2[1][a2[1].count - 1] = last
        }
        return a + a2 + b + a
    }

    private mutating func playMelody(_ notes: [Note], bar: Int, degree: Int) {
        guard style.lead != .none else { return }
        let tones = Set(chordTones(degree, seventh: false).map { (($0 % 7) + 7) % 7 })
        for note in notes {
            var d = note.degree
            // Strong beats land on a chord tone.
            if Int(note.step) % 8 == 0 {
                for delta in [0, -1, 1, -2, 2] where tones.contains(((d + delta) % 7 + 7) % 7) {
                    d += delta
                    break
                }
            }
            let start = time(bar: bar, step: note.step)
            voice(style.lead, hz(midi(d)), start: start, length: note.steps * beat / 4, amp: 0.12, pan: 0.05, send: 0.35)
        }
    }

    // MARK: Instruments

    private mutating func voice(_ v: SynthStyle.Voice, _ f: Float, start: Double, length: Double, amp: Float, pan: Float, send: Float = 0.3) {
        switch v {
        case .none: break
        case .pluck: pluck(f, start: start, amp: amp * 1.3, pan: pan, decay: 0.995)
        case .square: square(f, start: start, length: length, amp: amp * 0.55, pan: pan, send: send)
        case .bell: bell(f, start: start, amp: amp, pan: pan)
        case .epiano: epiano(f, start: start, length: max(length, 0.25), amp: amp, pan: pan)
        case .sine: sine(f, start: start, length: length, amp: amp, pan: pan)
        }
    }

    private mutating func write(_ i: Int, _ v: Float, pan: Float, send: Float, echo: Float = 0) {
        guard i >= 0, i < left.count else { return }
        let p = (pan + 1) * 0.25 * .pi
        left[i] += v * cos(p)
        right[i] += v * sin(p)
        reverbSend[i] += v * send
        if echo > 0 { echoSend[i] += v * echo }
    }

    private func envelope(_ t: Float, attack: Float, length: Float, release: Float) -> Float {
        if t < attack { return t / attack }
        if t < length { return 1 }
        return max(0, 1 - (t - length) / release)
    }

    private mutating func pad(_ f: Float, start: Double, length: Double, amp: Float, pan: Float) {
        let s0 = Int(start * Double(sr)), attack: Float = 0.35, release: Float = 0.9
        let count = Int((Float(length) + release) * sr)
        var phases: [Float] = [0, 0.33, 0.66]
        let detune: [Float] = [1, 1.004, 0.996]
        var lp: Float = 0
        let cutoff: Float = style.lofi ? 0.06 : 0.1
        for n in 0..<count {
            let t = Float(n) / sr
            var v: Float = 0
            for k in 0..<3 {
                v += phases[k] * 2 - 1
                phases[k] += f * detune[k] / sr
                if phases[k] >= 1 { phases[k] -= 1 }
            }
            lp += (v / 3 - lp) * cutoff
            write(s0 + n, lp * amp * envelope(t, attack: attack, length: Float(length), release: release), pan: pan, send: 0.6)
        }
    }

    private mutating func epiano(_ f: Float, start: Double, length: Double, amp: Float, pan: Float, echo: Float = 0) {
        let s0 = Int(start * Double(sr)), release: Float = 0.25
        let count = Int((Float(length) + release) * sr)
        for n in 0..<count {
            let t = Float(n) / sr
            let index = 1.8 * exp(-t * 5) + 0.25
            let mod = sin(2 * .pi * f * t) * index
            let tine = sin(2 * .pi * f * 7 * t) * 0.08 * exp(-t * 18)
            let v = (sin(2 * .pi * f * t + mod) + tine) * exp(-t * 1.6)
            write(s0 + n, v * amp * envelope(t, attack: 0.004, length: Float(length), release: release), pan: pan, send: 0.3, echo: echo)
        }
    }

    private mutating func bell(_ f: Float, start: Double, amp: Float, pan: Float) {
        let s0 = Int(start * Double(sr))
        let count = Int(1.6 * sr)
        for n in 0..<count {
            let t = Float(n) / sr
            let mod = sin(2 * .pi * f * 3.5 * t) * 2.2 * exp(-t * 6)
            let v = sin(2 * .pi * f * t + mod) * exp(-t * 3) * min(1, t * 400)
            write(s0 + n, v * amp, pan: pan, send: 0.45)
        }
    }

    private mutating func sine(_ f: Float, start: Double, length: Double, amp: Float, pan: Float) {
        let s0 = Int(start * Double(sr))
        let count = Int((Float(length) + 0.15) * sr)
        var phase: Float = 0
        for n in 0..<count {
            let t = Float(n) / sr
            let vibrato = 1 + 0.004 * sin(2 * .pi * 5 * t) * min(1, t * 3)
            phase += f * vibrato / sr
            let v = sin(2 * .pi * phase) + 0.2 * sin(4 * .pi * phase)
            write(s0 + n, v * amp * envelope(t, attack: 0.03, length: Float(length), release: 0.15), pan: pan, send: 0.4)
        }
    }

    private mutating func square(_ f: Float, start: Double, length: Double, amp: Float, pan: Float, send: Float) {
        let s0 = Int(start * Double(sr))
        let count = Int((Float(length) + 0.06) * sr)
        var phase: Float = 0, lp: Float = 0
        for n in 0..<count {
            let t = Float(n) / sr
            phase += f / sr
            if phase >= 1 { phase -= 1 }
            lp += ((phase < 0.25 ? 1 : -1) - lp) * 0.35
            let env = envelope(t, attack: 0.003, length: Float(length), release: 0.06) * (0.6 + 0.4 * exp(-t * 8))
            write(s0 + n, lp * amp * env, pan: pan, send: send)
        }
    }

    /// Karplus-Strong: a burst of noise through a short delay line sounds like a plucked string.
    private mutating func pluck(_ f: Float, start: Double, amp: Float, pan: Float, decay: Float) {
        let s0 = Int(start * Double(sr))
        let period = max(2, Int(sr / f))
        var line = (0..<period).map { _ in rng.noise() }
        for i in 1..<period { line[i] = (line[i] + line[i - 1]) * 0.5 }
        let count = Int(2.2 * sr)
        var idx = 0
        for n in 0..<count {
            let next = (idx + 1) % period
            let v = line[idx]
            line[idx] = (line[idx] + line[next]) * 0.5 * decay
            idx = next
            write(s0 + n, v * amp, pan: pan, send: 0.3)
        }
    }

    private mutating func bass(_ f: Float, start: Double, length: Double) {
        let s0 = Int(start * Double(sr))
        let count = Int((Float(length) + 0.05) * sr)
        var phase: Float = 0, lp: Float = 0
        let gain: Float = style.bass == .dub ? 0.42 : 0.3
        for n in 0..<count {
            let t = Float(n) / sr
            phase += f / sr
            if phase >= 1 { phase -= 1 }
            var v: Float
            if style.bass == .pulse {
                lp += ((phase * 2 - 1) - lp) * 0.08
                v = lp * 1.4
            } else {
                v = sin(2 * .pi * phase) + 0.25 * sin(4 * .pi * phase)
            }
            v = tanh(v * 1.5)
            write(s0 + n, v * gain * envelope(t, attack: 0.008, length: Float(length), release: 0.05), pan: 0, send: 0.02)
        }
    }

    private mutating func kick(_ start: Double, amp: Float) {
        let s0 = Int(start * Double(sr))
        var phase: Float = 0
        for n in 0..<Int(0.45 * sr) {
            let t = Float(n) / sr
            phase += (45 + 90 * exp(-t * 30)) / sr
            write(s0 + n, sin(2 * .pi * phase) * exp(-t * 7) * amp * 0.75, pan: 0, send: 0.03)
        }
    }

    private mutating func snare(_ start: Double, amp: Float) {
        let s0 = Int(start * Double(sr))
        var lp: Float = 0
        for n in 0..<Int(0.25 * sr) {
            let t = Float(n) / sr
            let noise = rng.noise()
            lp += (noise - lp) * 0.3
            let v = (noise - lp) * exp(-t * 16) + sin(2 * .pi * 185 * t) * exp(-t * 25) * 0.5
            write(s0 + n, v * amp * 0.5, pan: 0.05, send: 0.25)
        }
    }

    private mutating func rim(_ start: Double, amp: Float) {
        let s0 = Int(start * Double(sr))
        for n in 0..<Int(0.06 * sr) {
            let t = Float(n) / sr
            write(s0 + n, (sin(2 * .pi * 1700 * t) + rng.noise() * 0.3) * exp(-t * 70) * amp * 0.5, pan: -0.1, send: 0.3)
        }
    }

    private mutating func hat(_ start: Double, amp: Float, open: Bool) {
        let s0 = Int(start * Double(sr))
        var lp: Float = 0
        let decay: Float = open ? 9 : 45
        for n in 0..<Int((open ? 0.3 : 0.08) * sr) {
            let t = Float(n) / sr
            let noise = rng.noise()
            lp += (noise - lp) * 0.6
            write(s0 + n, (noise - lp) * exp(-t * decay) * amp * 0.6, pan: 0.3, send: 0.1)
        }
    }

    private mutating func shaker(_ start: Double, amp: Float) {
        let s0 = Int(start * Double(sr))
        var lp: Float = 0
        for n in 0..<Int(0.07 * sr) {
            let t = Float(n) / sr
            let noise = rng.noise()
            lp += (noise - lp) * 0.5
            let env = min(1, t * 120) * exp(-t * 40)
            write(s0 + n, (noise - lp) * env * amp * 0.6, pan: -0.3, send: 0.15)
        }
    }

    // MARK: Mixing

    private mutating func mixdown() -> [Float] {
        let count = left.count
        var wetL = [Float](repeating: 0, count: count), wetR = wetL
        var reverbL = Reverb(spread: 0), reverbR = Reverb(spread: 23)
        for i in 0..<count {
            let input = reverbSend[i] * 0.02
            wetL[i] = reverbL.process(input)
            wetR[i] = reverbR.process(input)
        }
        if style.echo {
            // A dotted-eighth ping-pong delay.
            let delay = Int(0.75 * beat * Double(sr))
            var echoL = [Float](repeating: 0, count: count), echoR = echoL
            for i in 0..<count {
                let fromR = i >= delay ? echoR[i - delay] : 0
                let fromL = i >= delay ? echoL[i - delay] : 0
                echoL[i] = echoSend[i] + fromR * 0.55
                echoR[i] = fromL * 0.55
                left[i] += echoL[i] * 0.5
                right[i] += echoR[i] * 0.5
            }
        }
        var noise = SeededRandom(seed: 7)
        var out = [Float](repeating: 0, count: count * 2)
        var lpL: Float = 0, lpR: Float = 0
        var peak: Float = 0.0001, power: Double = 0
        for i in 0..<count {
            var l = left[i] + wetL[i] * style.reverb * 3
            var r = right[i] + wetR[i] * style.reverb * 3
            if style.lofi {
                // Dull, a little hiss and the odd crackle.
                lpL += (l - lpL) * 0.28
                lpR += (r - lpR) * 0.28
                l = lpL + noise.noise() * 0.004
                r = lpR + noise.noise() * 0.004
                if noise.chance(0.00015) {
                    let pop = noise.noise() * 0.08
                    l += pop
                    r += pop
                }
            }
            out[2 * i] = l
            out[2 * i + 1] = r
            peak = max(peak, abs(l), abs(r))
            power += Double(l * l + r * r)
        }
        // About the same loudness for every song, without clipping.
        let rms = Float((power / Double(2 * count)).squareRoot())
        let gain = min(0.9 / peak, 0.13 / max(rms, 0.0001))
        let fadeIn = Int(0.02 * sr), fadeOut = Int(2.5 * sr)
        for i in 0..<count {
            var g = gain
            if i < fadeIn { g *= Float(i) / Float(fadeIn) }
            if i > count - fadeOut { g *= Float(count - i) / Float(fadeOut) }
            out[2 * i] = tanh(out[2 * i] * g * 1.1) / tanh(1.1)
            out[2 * i + 1] = tanh(out[2 * i + 1] * g * 1.1) / tanh(1.1)
        }
        return out
    }

    /// 16-bit stereo WAV.
    static func wav(_ samples: [Float]) -> Data {
        var data = Data()
        func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = samples.count * 2
        data.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36 + bytes))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); put(UInt32(16)); put(UInt16(1)); put(UInt16(2))
        put(UInt32(sampleRate)); put(UInt32(sampleRate * 4)); put(UInt16(4)); put(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); put(UInt32(bytes))
        data.reserveCapacity(data.count + bytes)
        for s in samples { put(Int16(max(-1, min(1, s)) * 32767)) }
        return data
    }
}

/// Freeverb's comb and allpass filters (its tunings at 44.1 kHz).
private struct Reverb {
    private struct Comb {
        var buffer: [Float], index = 0, store: Float = 0
        mutating func process(_ x: Float) -> Float {
            let y = buffer[index]
            store = y * 0.8 + store * 0.2
            buffer[index] = x + store * 0.84
            index = index + 1 == buffer.count ? 0 : index + 1
            return y
        }
    }

    private struct Allpass {
        var buffer: [Float], index = 0
        mutating func process(_ x: Float) -> Float {
            let b = buffer[index]
            buffer[index] = x + b * 0.5
            index = index + 1 == buffer.count ? 0 : index + 1
            return b - x
        }
    }

    private var combs: [Comb]
    private var allpasses: [Allpass]

    init(spread: Int) {
        combs = [1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617].map { Comb(buffer: Array(repeating: 0, count: $0 + spread)) }
        allpasses = [556, 441, 341, 225].map { Allpass(buffer: Array(repeating: 0, count: $0 + spread)) }
    }

    mutating func process(_ x: Float) -> Float {
        var sum: Float = 0
        for i in combs.indices { sum += combs[i].process(x) }
        for i in allpasses.indices { sum = allpasses[i].process(sum) }
        return sum
    }
}
