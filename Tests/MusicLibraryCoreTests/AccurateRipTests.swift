import Foundation
import Testing
@testable import MusicLibraryCore

/// A TOC with audio tracks starting at `starts` (blocks, lead-in included) and ending at `leadout`.
private func toc(_ starts: [Int], leadout: Int) -> CDTOC {
    let tracks = starts.enumerated().map { CDTrack(number: $0.offset + 1, startBlock: $0.element, isData: false, session: 1) }
    return CDTOC(firstTrack: 1, lastTrack: starts.count, leadout: leadout, tracks: tracks)
}

/// The checksums as AccurateRip defines them, written out the slow way: a multiplier counting the track's samples
/// from 1, with the first track checked from multiplier 2940 and the last up to its length minus 2940.
private func referenceChecksums(_ track: ArraySlice<UInt32>, isFirst: Bool, isLast: Bool) -> (v1: UInt32, v2: UInt32) {
    let from = isFirst ? 2940 : 0
    let to = isLast ? track.count - 2940 : track.count
    var low: UInt64 = 0, high: UInt64 = 0
    for (i, x) in track.enumerated() {
        let multiplier = i + 1
        guard multiplier >= from, multiplier <= to else { continue }
        let product = UInt64(x) * UInt64(multiplier)
        low += product & 0xFFFF_FFFF
        high += product >> 32
    }
    return (UInt32(truncatingIfNeeded: low), UInt32(truncatingIfNeeded: low + high))
}

private func referenceSector450(_ track: ArraySlice<UInt32>) -> UInt32 {
    let start = track.startIndex + 450 * 588
    var crc: UInt32 = 0
    for k in 0..<588 { crc &+= track[start + k] &* UInt32(k + 1) }
    return crc
}

/// A disc's audio held in memory, as a drive with `offset` reads it: shifted, with silence past the disc's ends.
private struct SimulatedDisc: AccurateRipAudioSource {
    var audio: [UInt32]
    var lengths: [Int]
    var offset = 0
    var unreadable: Set<Int> = []

    func samples(track index: Int, range: Range<Int>) async throws -> [UInt32]? {
        guard !unreadable.contains(index) else { return nil }
        let start = lengths[..<index].reduce(0, +)
        return range.map { i in
            let at = start + i - offset
            return audio.indices.contains(at) ? audio[at] : 0
        }
    }
}

private func randomAudio(_ count: Int, seed: UInt64) -> [UInt32] {
    var state = seed
    return (0..<count).map { _ in
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return UInt32(truncatingIfNeeded: state >> 29)
    }
}

/// Three 460-sector tracks (long enough for the sector 450 checksum) of random audio.
private let discTOC = toc([150, 610, 1070], leadout: 1530)
private let discLengths = [460, 460, 460].map { $0 * 588 }
private let discAudio = randomAudio(discLengths.reduce(0, +), seed: 7)

private func track(_ index: Int, of audio: [UInt32] = discAudio) -> ArraySlice<UInt32> {
    let start = discLengths[..<index].reduce(0, +)
    return audio[start..<(start + discLengths[index])]
}

/// A database with an older pressing listing v1 checksums and a newer one listing v2 with sector 450 checksums.
private func database(_ audio: [UInt32] = discAudio) -> [AccurateRipPressing] {
    let refs = (0..<3).map { referenceChecksums(track($0, of: audio), isFirst: $0 == 0, isLast: $0 == 2) }
    return [
        AccurateRipPressing(tracks: refs.map { .init(confidence: 12, checksum: $0.v1, sector450: 0) }),
        AccurateRipPressing(tracks: (0..<3).map { .init(confidence: 40, checksum: refs[$0].v2, sector450: referenceSector450(track($0, of: audio))) }),
    ]
}

@Suite struct AccurateRipTests {
    @Test func identifiesARealDisc() {
        // A real 11-track CD's TOC; AccurateRip has it under this file name.
        let disc = AccurateRipDisc(toc: toc([150, 16995, 34582, 46052, 60075, 79487, 98147, 112357, 127765, 140730, 155605], leadout: 174405))
        #expect(disc.url.absoluteString == "https://www.accuraterip.com/accuraterip/6/4/0/dBAR-011-000ff046-0089de0d-8a09130b.bin")
    }

    @Test func parsesARealResponse() throws {
        let data = try TestSupport.fixture("accuraterip_dBAR-011-000ff046-0089de0d-8a09130b", ext: "bin")
        let disc = AccurateRipDisc(toc: toc([150, 16995, 34582, 46052, 60075, 79487, 98147, 112357, 127765, 140730, 155605], leadout: 174405))
        let pressings = try AccurateRipPressing.parse(data, disc: disc)
        #expect(pressings.count == 7)
        #expect(pressings[0].tracks.count == 11)
        #expect(pressings[0].tracks[0] == .init(confidence: 156, checksum: 0x0827_C6FE, sector450: 0x951D_F289))
        #expect(pressings[6].tracks[1].isEmpty)
        // Truncated responses are refused; another disc's pressings are left out.
        #expect(throws: AccurateRipError.self) { try AccurateRipPressing.parse(data.prefix(20), disc: disc) }
        let other = AccurateRipDisc(toc: toc([150, 20000], leadout: 40000))
        #expect(try AccurateRipPressing.parse(data, disc: other).isEmpty)
    }

    @Test func checksumsMatchTheDefinitionAtEveryOffset() {
        // Silence before and after the disc, as the verifier reads it.
        let reach = AccurateRip.maxPressingOffset
        let padded = [UInt32](repeating: 0, count: reach) + discAudio + [UInt32](repeating: 0, count: reach)
        for index in 0..<3 {
            let start = reach + discLengths[..<index].reduce(0, +)
            let samples = Array(padded[(start - reach)..<(start + discLengths[index] + reach)])
            let audio = AccurateRipTrackAudio(samples: samples, lead: reach, count: discLengths[index], isFirst: index == 0, isLast: index == 2)
            let range = audio.offsets!
            #expect(range == -reach...reach)
            let drive = -AccurateRip.maxOffset...AccurateRip.maxOffset
            let v1 = audio.v1Checksums(drive)
            let sector450 = audio.sector450Checksums(range)!
            for offset in [-reach, -5574, -AccurateRip.maxOffset, -588, -1, 0, 1, 700, AccurateRip.maxOffset, 6000, reach] {
                let shifted = padded[(start + offset)..<(start + offset + discLengths[index])]
                let reference = referenceChecksums(shifted, isFirst: index == 0, isLast: index == 2)
                if drive.contains(offset) { #expect(v1[offset - drive.lowerBound] == reference.v1, "track \(index + 1) at \(offset)") }
                #expect(audio.checksums(at: offset) == reference, "track \(index + 1) at \(offset)")
                #expect(sector450[offset - range.lowerBound] == referenceSector450(shifted), "track \(index + 1) at \(offset)")
            }
        }
    }

    @Test(arguments: [0, 6, 667, -1164, 2900])
    func verifiesARipAtAnyDriveOffset(offset: Int) async throws {
        let rip = SimulatedDisc(audio: discAudio, lengths: discLengths, offset: offset)
        let report = try await AccurateRipVerifier(toc: discTOC, pressings: database()).verify([1, 2, 3], audio: rip)
        #expect(report.offset == offset)
        #expect(report.tracks == [1: .accurate(confidence: 40), 2: .accurate(confidence: 40), 3: .accurate(confidence: 40)])
    }

    @Test func findsAnotherPressingsOffset() async throws {
        // Pressings can hold the same audio further apart than drives read: found by the sector 450 checksums (not by
        // the older v1-only pressing). Like real CDs, the disc starts and ends in silence.
        var quiet = discAudio
        for i in 0..<10_000 { quiet[i] = 0; quiet[quiet.count - 1 - i] = 0 }
        for offset in [6000, -5574] {
            let rip = SimulatedDisc(audio: quiet, lengths: discLengths, offset: offset)
            let report = try await AccurateRipVerifier(toc: discTOC, pressings: database(quiet)).verify([1, 2, 3], audio: rip)
            #expect(report.offset == offset)
            #expect(report.tracks == [1: .accurate(confidence: 40), 2: .accurate(confidence: 40), 3: .accurate(confidence: 40)])
        }
    }

    @Test func findsTheMisreadTrack() async throws {
        var damaged = discAudio
        damaged[discLengths[0] + 100_000] ^= 0x0001_0000
        let rip = SimulatedDisc(audio: damaged, lengths: discLengths, offset: 6)
        let report = try await AccurateRipVerifier(toc: discTOC, pressings: database()).verify([1, 2, 3], audio: rip)
        #expect(report.offset == 6)
        #expect(report.tracks == [1: .accurate(confidence: 40), 2: .inaccurate, 3: .accurate(confidence: 40)])
    }

    @Test func cantTellWithoutAMatchingPressing() async throws {
        // Another pressing (different audio): nothing matches, so it can't be told from a bad rip.
        let other = database(randomAudio(discAudio.count, seed: 99))
        let rip = SimulatedDisc(audio: discAudio, lengths: discLengths)
        let report = try await AccurateRipVerifier(toc: discTOC, pressings: other).verify([1, 2, 3], audio: rip)
        #expect(report.offset == nil)
        #expect(report.tracks == [1: .unknown, 2: .unknown, 3: .unknown])
    }

    @Test func checksOneTrackAgainAtTheOffsetFoundBefore() async throws {
        // Only v2 checksums without sector 450 ones: a lone track can only be checked at a known offset.
        let refs = (0..<3).map { referenceChecksums(track($0), isFirst: $0 == 0, isLast: $0 == 2) }
        let v2Only = [AccurateRipPressing(tracks: refs.map { .init(confidence: 9, checksum: $0.v2, sector450: 0) })]
        let rip = SimulatedDisc(audio: discAudio, lengths: discLengths, offset: 48)
        let verifier = AccurateRipVerifier(toc: discTOC, pressings: v2Only)
        #expect(try await verifier.verify([2], audio: rip).tracks == [2: .unknown])
        #expect(try await verifier.verify([2], audio: rip, offsetHint: 48).tracks == [2: .accurate(confidence: 9)])
    }

    @Test func needsTheNeighboringTracksForOffsets() async throws {
        // Track 2 can't be read around at a positive offset without track 3's start.
        let rip = SimulatedDisc(audio: discAudio, lengths: discLengths, offset: 30, unreadable: [2])
        let report = try await AccurateRipVerifier(toc: discTOC, pressings: database()).verify([1, 2], audio: rip)
        #expect(report.tracks == [1: .accurate(confidence: 40), 2: .unknown])
    }

    @Test func combinesReadsSampleBySample() {
        // Each read gets a few samples wrong, in different places: the majority is the true audio.
        let truth = randomAudio(50_000, seed: 3)
        func read(_ errors: [Int]) -> [UInt32] {
            var r = truth
            for i in errors { r[i] ^= 0x0001_0001 }
            return r
        }
        var vote = ReadVote(first: read([10, 20_000]))
        let second = vote.add(read([10, 30_000])), third = vote.add(read([40_000]))
        #expect(!second && !third)
        #expect(vote.reads == 3)
        #expect(vote.disagreements == 4)
        // Sample 10 was misread twice out of three: the majority is wrong there; the other spots are right.
        let combined = vote.result
        #expect(combined[10] == truth[10] ^ 0x0001_0001)
        #expect(combined[20_000] == truth[20_000] && combined[30_000] == truth[30_000] && combined[40_000] == truth[40_000])
        let sameAsFirst = vote.add(read([10, 20_000]))
        #expect(sameAsFirst)
        // Two reads that disagree: a tie, so the first read's value.
        var pair = ReadVote(first: read([5]))
        pair.add(read([6]))
        #expect(pair.result == read([5]))
        // A read of another length isn't counted.
        let wrongLength = pair.add([1, 2, 3])
        #expect(!wrongLength && pair.reads == 2)
    }

    @Test func checksATrackHeldInMemory() async throws {
        // The rip being checked comes from memory; the tracks around it from the disc.
        var damaged = discAudio
        damaged[discLengths[0] + 100_000] ^= 0x0001_0000
        let disc = SimulatedDisc(audio: damaged, lengths: discLengths)
        let verifier = AccurateRipVerifier(toc: discTOC, pressings: database())
        #expect(try await verifier.verify([2], audio: disc, offsetHint: 0).tracks == [2: .inaccurate])
        let fixed = AccurateRipAudioOverlay(base: disc, tracks: [1: Array(track(1))])
        #expect(try await verifier.verify([2], audio: fixed, offsetHint: 0).tracks == [2: .accurate(confidence: 40)])
    }
}

