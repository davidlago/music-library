// The CoreAudio HAL is macOS only; the iPhone app doesn't record.
#if os(macOS)
import AudioToolbox
import CoreAudio
import Foundation

/// A device sound can be recorded from (a phono preamp's USB output, an audio interface, a USB turntable).
public struct AudioInputDevice: Identifiable, Hashable, Sendable {
    public var id: AudioObjectID
    public var uid: String
    public var name: String
    public var channels: Int
    /// The sample rates it can run at (standard rates within its ranges), lowest first.
    public var sampleRates: [Int]
    /// The bit depths of its integer physical formats, lowest first (empty when it only reports float).
    public var bitDepths: [Int]
}

public enum CoreAudioInput {
    static let standardRates = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000]

    /// Every device with input channels, the system's default input first.
    public static func devices() -> [AudioInputDevice] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard let ids = try? CoreAudioOutput.getArray(system, kAudioHardwarePropertyDevices, element: AudioObjectID(0)) else { return [] }
        let defaultID = try? CoreAudioOutput.getValue(system, kAudioHardwarePropertyDefaultInputDevice, initial: AudioObjectID(0))
        let found = ids.compactMap { id -> AudioInputDevice? in
            let channels = inputChannels(id)
            guard channels > 0 else { return nil }
            return AudioInputDevice(id: id, uid: CoreAudioOutput.uid(of: id), name: CoreAudioOutput.name(of: id), channels: channels,
                                    sampleRates: sampleRates(id), bitDepths: bitDepths(id))
        }
        return found.filter { $0.id == defaultID } + found.filter { $0.id != defaultID }
    }

    static func inputChannels(_ device: AudioObjectID) -> Int {
        var addr = CoreAudioOutput.address(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func sampleRates(_ device: AudioObjectID) -> [Int] {
        let ranges = (try? CoreAudioOutput.availableNominalRates(device)) ?? []
        var rates = Set<Int>()
        for r in ranges {
            if r.upperBound - r.lowerBound < 1 { rates.insert(Int(r.lowerBound.rounded())) }
            for s in standardRates where r.contains(Double(s)) { rates.insert(s) }
        }
        return rates.filter { $0 >= 8000 }.sorted()
    }

    static func inputStreams(_ device: AudioObjectID) -> [AudioStreamID] {
        (try? CoreAudioOutput.getArray(device, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput, element: AudioStreamID(0))) ?? []
    }

    static func bitDepths(_ device: AudioObjectID) -> [Int] {
        var depths = Set<Int>()
        for stream in inputStreams(device) {
            for f in (try? CoreAudioOutput.availablePhysicalFormats(stream)) ?? [] where f.mFormat.mFormatID == kAudioFormatLinearPCM
                && f.mFormat.mFormatFlags & kAudioFormatFlagIsFloat == 0 {
                depths.insert(Int(f.mFormat.mBitsPerChannel))
            }
        }
        return depths.sorted()
    }

    /// Sets the device's sample rate (for every app using it, as Audio MIDI Setup does).
    public static func setSampleRate(_ device: AudioObjectID, _ rate: Int) throws {
        if let now = try? CoreAudioOutput.nominalRate(device), abs(now - Double(rate)) < 0.5 { return }
        try CoreAudioOutput.setNominalRate(device, Double(rate), timeout: 2)
    }

    /// Asks the device's input for integer samples of `bits` at `rate`, when it has such a format; false when it
    /// doesn't (it then delivers what it has, converted).
    @discardableResult
    public static func setBitDepth(_ device: AudioObjectID, _ bits: Int, rate: Int) -> Bool {
        var applied = false
        for stream in inputStreams(device) {
            let formats = (try? CoreAudioOutput.availablePhysicalFormats(stream)) ?? []
            guard let match = formats.first(where: { f in
                f.mFormat.mFormatID == kAudioFormatLinearPCM && f.mFormat.mFormatFlags & kAudioFormatFlagIsFloat == 0
                    && Int(f.mFormat.mBitsPerChannel) == bits
                    && (f.mSampleRateRange.mMaximum == 0 ? abs(f.mFormat.mSampleRate - Double(rate)) < 0.5
                        : (f.mSampleRateRange.mMinimum - 0.5...f.mSampleRateRange.mMaximum + 0.5).contains(Double(rate)))
            }) else { continue }
            var format = match.mFormat
            format.mSampleRate = Double(rate)
            if (try? CoreAudioOutput.setPhysicalFormat(stream, format, timeout: 2)) != nil { applied = true }
        }
        return applied
    }

    /// The device's current sample rate.
    public static func sampleRate(_ device: AudioObjectID) -> Int? {
        (try? CoreAudioOutput.nominalRate(device)).map { Int($0.rounded()) }
    }
}
/// Records from an input device through a HAL input unit, at the device's own sample rate (no resampling): its
/// first two channels go to `sink` while one is set (written off the audio thread, in order), and their peaks are
/// kept for a meter. Thread-safe.
public final class AudioInputCapture: @unchecked Sendable {
    public let device: AudioObjectID
    public let sampleRate: Int
    /// The channels recorded: the device's first two (or its one).
    public let channels: Int
    private let deviceChannels: Int
    private let capacity = 8192
    private var unit: AudioUnit?
    private let buffers: UnsafeMutableAudioBufferListPointer
    private let lock = NSLock()
    private var _sink: VinylRecordingFile?
    private var _listener: (@Sendable (UnsafeBufferPointer<Float>) -> Void)?
    private var peaks: [Float] = [0, 0]
    private var clipped = false
    private var failed = false
    private var callbacks = 0
    private let writer = DispatchQueue(label: "local.musiclibrary.input-writer")

    public init(device: AudioObjectID) throws {
        self.device = device
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
                                             componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &desc) else { throw CoreAudioError.property("find input unit", -1) }
        var created: AudioUnit?
        try Self.check(AudioComponentInstanceNew(component, &created), "create input unit")
        guard let unit = created else { throw CoreAudioError.property("create input unit", -1) }
        func set<T>(_ property: AudioUnitPropertyID, _ scope: AudioUnitScope, _ element: AudioUnitElement, _ value: T, _ what: String) throws {
            var v = value
            try Self.check(AudioUnitSetProperty(unit, property, scope, element, &v, UInt32(MemoryLayout<T>.size)), what)
        }
        do {
            // Bus 1 is the input side, bus 0 the output side, which isn't used.
            try set(kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, UInt32(1), "enable input")
            try set(kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, UInt32(0), "disable output")
            try set(kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, device, "choose the input")
            var hardware = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try Self.check(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hardware, &size), "read the input format")
            let count = Int(hardware.mChannelsPerFrame)
            guard count > 0 else { throw VinylError.noInput }
            // The device's nominal rate is what it runs at now (the unit's copy can lag behind a change).
            let rate = CoreAudioInput.sampleRate(device) ?? Int(hardware.mSampleRate.rounded())
            guard rate > 0 else { throw VinylError.noInput }
            let client = AudioStreamBasicDescription(
                mSampleRate: Double(rate), mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
                mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: UInt32(count),
                mBitsPerChannel: 32, mReserved: 0)
            try set(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, client, "set the recording format")
            try set(kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, UInt32(capacity), "set the buffer size")
            deviceChannels = count
            channels = min(2, count)
            sampleRate = rate
        } catch {
            AudioComponentInstanceDispose(unit)
            throw error
        }
        buffers = AudioBufferList.allocate(maximumBuffers: deviceChannels)
        for i in 0..<deviceChannels {
            buffers[i] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(capacity * 4),
                                     mData: UnsafeMutableRawPointer.allocate(byteCount: capacity * 4, alignment: 16))
        }
        self.unit = unit
        var callback = AURenderCallbackStruct(inputProc: { refCon, flags, timeStamp, bus, frames, _ in
            Unmanaged<AudioInputCapture>.fromOpaque(refCon).takeUnretainedValue().render(flags, timeStamp, bus, frames)
        }, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        do {
            try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback,
                                                UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "set the input callback")
            try Self.check(AudioUnitInitialize(unit), "start the input")
            try Self.check(AudioOutputUnitStart(unit), "start the input")
        } catch {
            stop()
            throw error
        }
    }

    deinit {
        stop()
        for b in buffers { b.mData?.deallocate() }
        free(buffers.unsafeMutablePointer)
    }

    private static func check(_ status: OSStatus, _ what: String) throws {
        guard status == noErr else { throw CoreAudioError.property(what, status) }
    }

    public var sink: VinylRecordingFile? {
        get { lock.withLock { _sink } }
        set { lock.withLock { _sink = newValue } }
    }

    /// Called on the audio thread with each delivery's interleaved samples (`channels` per frame), to play them
    /// while recording. It must return quickly.
    public var listener: (@Sendable (UnsafeBufferPointer<Float>) -> Void)? {
        get { lock.withLock { _listener } }
        set { lock.withLock { _listener = newValue } }
    }

    /// Stops the input; what it delivered is written before this returns.
    public func stop() {
        let u: AudioUnit? = lock.withLock {
            defer { unit = nil }
            return unit
        }
        if let u {
            AudioOutputUnitStop(u)
            AudioUnitUninitialize(u)
            AudioComponentInstanceDispose(u)
        }
        writer.sync {}
    }

    /// The peaks since the last read (0…1, left and right) and whether any sample reached full scale.
    public func readMeter() -> (peaks: [Float], clipped: Bool) {
        lock.withLock {
            defer { peaks = [0, 0]; clipped = false }
            return (peaks, clipped)
        }
    }

    /// Writing the recording failed (the disk is full, say).
    public var writeFailed: Bool { lock.withLock { failed } }

    /// How many times the input has delivered audio (none means it isn't running).
    public var deliveries: Int { lock.withLock { callbacks } }

    private func render(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, _ timeStamp: UnsafePointer<AudioTimeStamp>,
                        _ bus: UInt32, _ frameCount: UInt32) -> OSStatus {
        guard let unit = lock.withLock({ unit }) else { return noErr }
        let frames = Int(frameCount)
        guard frames <= capacity else { return kAudioUnitErr_TooManyFramesToProcess }
        for i in 0..<deviceChannels { buffers[i].mDataByteSize = UInt32(frames * 4) }
        let status = AudioUnitRender(unit, flags, timeStamp, bus, frameCount, buffers.unsafeMutablePointer)
        guard status == noErr else { return status }
        let out = channels
        var samples = [Float](repeating: 0, count: frames * out)
        var p: [Float] = [0, 0]
        var clip = false
        var c = 0
        while c < out {
            if let data = buffers[c].mData?.assumingMemoryBound(to: Float.self) {
                var f = 0
                while f < frames {
                    let v = data[f]
                    samples[f * out + c] = v
                    let a = abs(v)
                    if a > p[c] { p[c] = a }
                    if a >= 0.999 { clip = true }
                    f += 1
                }
            }
            c += 1
        }
        if out == 1 { p[1] = p[0] }
        let (sink, listener) = lock.withLock {
            callbacks += 1
            peaks = [max(peaks[0], p[0]), max(peaks[1], p[1])]
            if clip { clipped = true }
            return (_sink, _listener)
        }
        if let listener { samples.withUnsafeBufferPointer { listener($0) } }
        if let sink {
            writer.async { [self] in
                do {
                    try samples.withUnsafeBufferPointer { try sink.append(interleaved: $0) }
                } catch {
                    lock.withLock { failed = true }
                }
            }
        }
        return noErr
    }
}
/// Carries an input's samples to an output running on another clock, for listening while recording: about
/// `latency` behind, dropping the oldest when the input runs ahead and playing silence (then filling up again) when
/// it falls behind. Thread-safe (pushed from the input's audio thread, pulled from the output's).
public final class MonitorBuffer: @unchecked Sendable {
    public let channels: Int
    private let capacity: Int
    private let target: Int
    private let ceiling: Int
    private var ring: [Float]
    private var start = 0
    private var count = 0
    private var primed = false
    private let lock = NSLock()

    public init(channels: Int, sampleRate: Int, latency: Double = 0.05) {
        self.channels = max(1, channels)
        target = max(64, Int(latency * Double(sampleRate)))
        ceiling = target * 4
        capacity = max(ceiling * 2, sampleRate)
        ring = [Float](repeating: 0, count: capacity * self.channels)
    }

    /// Frames waiting to be played.
    public var buffered: Int { lock.withLock { count } }

    /// Adds interleaved samples (`channels` per frame).
    public func push(_ samples: UnsafeBufferPointer<Float>) {
        let frames = samples.count / channels
        guard frames > 0 else { return }
        lock.withLock {
            let skip = max(0, frames - capacity)
            var f = skip
            while f < frames {
                if count == capacity { start = (start + 1) % capacity; count -= 1 }
                let at = (start + count) % capacity
                var c = 0
                while c < channels { ring[at * channels + c] = samples[f * channels + c]; c += 1 }
                count += 1
                f += 1
            }
            // The input's clock ran ahead: catch up instead of falling further behind.
            if count > ceiling {
                let drop = count - target
                start = (start + drop) % capacity
                count -= drop
            }
        }
    }

    /// Fills `frames` frames of each channel's buffer in `outputs` (as many as the output has; a mono input plays on
    /// every one), with silence where nothing is waiting.
    public func pull(frames: Int, into outputs: UnsafeMutableAudioBufferListPointer) {
        lock.withLock {
            if !primed, count >= target { primed = true }
            let n = primed ? min(frames, count) : 0
            for (k, buffer) in outputs.enumerated() {
                guard let out = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let c = min(k, channels - 1)
                var f = 0
                while f < n { out[f] = ring[((start + f) % capacity) * channels + c]; f += 1 }
                while f < frames { out[f] = 0; f += 1 }
            }
            start = (start + n) % capacity
            count -= n
            // Ran dry: wait until there's enough again, so it doesn't stutter sample by sample.
            if primed, n < frames { primed = false }
        }
    }
}
#endif
