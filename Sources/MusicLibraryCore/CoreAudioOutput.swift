import CoreAudio
import Foundation

public enum CoreAudioError: Error, LocalizedError {
    case property(String, OSStatus)
    case timeout(String)
    case noOutputStream

    public var errorDescription: String? {
        switch self {
        case .property(let what, let status): return "CoreAudio \(what) failed (OSStatus \(status))"
        case .timeout(let what): return "Output device did not apply \(what) in time"
        case .noOutputStream: return "Output device has no output stream"
        }
    }
}

public enum CoreAudioOutput {
    private static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func getValue<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, initial: T) throws -> T {
        var addr = address(selector, scope: scope)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value)
        guard status == noErr else { throw CoreAudioError.property("read \(selector)", status) }
        return value
    }

    private static func getArray<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, element: T) throws -> [T] {
        var addr = address(selector, scope: scope)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size)
        guard status == noErr else { throw CoreAudioError.property("size \(selector)", status) }
        let count = Int(size) / MemoryLayout<T>.stride
        var result = [T](repeating: element, count: count)
        status = result.withUnsafeMutableBytes { AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0.baseAddress!) }
        guard status == noErr else { throw CoreAudioError.property("read \(selector)", status) }
        return result
    }

    private static func setValue<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ value: T) throws {
        var addr = address(selector, scope: scope)
        var v = value
        let status = AudioObjectSetPropertyData(object, &addr, 0, nil, UInt32(MemoryLayout<T>.size), &v)
        guard status == noErr else { throw CoreAudioError.property("write \(selector)", status) }
    }

    public static func defaultOutputDevice() throws -> AudioObjectID {
        try getValue(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, initial: AudioObjectID(0))
    }

    private static func stringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
        var addr = address(selector)
        var str: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &str) == noErr, let str else { return "" }
        return str.takeRetainedValue() as String
    }

    public static func name(of device: AudioObjectID) -> String { stringProperty(device, kAudioDevicePropertyDeviceNameCFString) }
    public static func uid(of device: AudioObjectID) -> String { stringProperty(device, kAudioDevicePropertyDeviceUID) }

    public static func deviceID(forUID uid: String) -> AudioObjectID? {
        guard let ids = try? getArray(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices, element: AudioObjectID(0)) else { return nil }
        return ids.first { Self.uid(of: $0) == uid }
    }

    public static func availableNominalRates(_ device: AudioObjectID) throws -> [ClosedRange<Double>] {
        try getArray(device, kAudioDevicePropertyAvailableNominalSampleRates, element: AudioValueRange())
            .map { $0.mMinimum...max($0.mMinimum, $0.mMaximum) }
    }

    public static func nominalRate(_ device: AudioObjectID) throws -> Double {
        try getValue(device, kAudioDevicePropertyNominalSampleRate, initial: Float64(0))
    }

    public static func setNominalRate(_ device: AudioObjectID, _ rate: Double, timeout: TimeInterval = 1.5) throws {
        try setValue(device, kAudioDevicePropertyNominalSampleRate, Float64(rate))
        try poll("sample rate \(rate)", timeout: timeout) { abs(((try? nominalRate(device)) ?? 0) - rate) < 0.5 }
    }

    public static func outputStreams(_ device: AudioObjectID) throws -> [AudioStreamID] {
        try getArray(device, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput, element: AudioStreamID(0))
    }

    public static func availablePhysicalFormats(_ stream: AudioStreamID) throws -> [AudioStreamRangedDescription] {
        try getArray(stream, kAudioStreamPropertyAvailablePhysicalFormats, element: AudioStreamRangedDescription())
    }

    public static func physicalFormat(_ stream: AudioStreamID) throws -> AudioStreamBasicDescription {
        try getValue(stream, kAudioStreamPropertyPhysicalFormat, initial: AudioStreamBasicDescription())
    }

    static func matches(_ a: AudioStreamBasicDescription, _ b: AudioStreamBasicDescription) -> Bool {
        abs(a.mSampleRate - b.mSampleRate) < 0.5 && a.mBitsPerChannel == b.mBitsPerChannel
            && a.mFormatID == b.mFormatID && (a.mFormatFlags & kAudioFormatFlagIsFloat) == (b.mFormatFlags & kAudioFormatFlagIsFloat)
    }

    public static func setPhysicalFormat(_ stream: AudioStreamID, _ format: AudioStreamBasicDescription, timeout: TimeInterval = 1.5) throws {
        try setValue(stream, kAudioStreamPropertyPhysicalFormat, format)
        try poll("physical format", timeout: timeout) {
            guard let now = try? physicalFormat(stream) else { return false }
            return matches(now, format)
        }
    }

    public static func option(from r: AudioStreamRangedDescription) -> PhysicalFormatOption {
        let lo = r.mSampleRateRange.mMaximum > 0 ? r.mSampleRateRange.mMinimum : r.mFormat.mSampleRate
        let hi = r.mSampleRateRange.mMaximum > 0 ? r.mSampleRateRange.mMaximum : r.mFormat.mSampleRate
        return PhysicalFormatOption(
            minRate: lo, maxRate: hi, bitDepth: Int(r.mFormat.mBitsPerChannel),
            isFloat: r.mFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0,
            isMixable: r.mFormat.mFormatFlags & kAudioFormatFlagIsNonMixable == 0,
            isLinearPCM: r.mFormat.mFormatID == kAudioFormatLinearPCM)
    }

    private static func poll(_ what: String, timeout: TimeInterval, _ done: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if done() { return }
            Thread.sleep(forTimeInterval: 0.02)
        }
        if done() { return }
        throw CoreAudioError.timeout(what)
    }
}

/// Switches the default output device to the format that best matches a track and restores it later.
public final class OutputMatcher: @unchecked Sendable {
    private struct Original {
        var uid: String
        var rate: Double
        var physical: AudioStreamBasicDescription?
    }

    private let lock = NSLock()
    private var originals: [String: Original] = [:]
    public private(set) var lastError: String?

    public init() {}

    public func apply(for format: AudioFormat, matchBitDepth: Bool) -> OutputState? {
        lock.lock(); defer { lock.unlock() }
        guard let sourceInt = format.sampleRate, sourceInt > 0 else { return nil }
        let source = Double(sourceInt)
        do {
            let device = try CoreAudioOutput.defaultOutputDevice()
            let name = CoreAudioOutput.name(of: device)
            let uid = CoreAudioOutput.uid(of: device)
            let current = try CoreAudioOutput.nominalRate(device)
            let rates = (try? CoreAudioOutput.availableNominalRates(device)) ?? []
            let target = OutputFormatChooser.chooseSampleRate(source: source, available: rates) ?? current

            let stream = try? CoreAudioOutput.outputStreams(device).first
            var targetPhysical: AudioStreamBasicDescription?
            var currentPhysical: AudioStreamBasicDescription?
            if let stream {
                currentPhysical = try? CoreAudioOutput.physicalFormat(stream)
                if matchBitDepth, let ranged = try? CoreAudioOutput.availablePhysicalFormats(stream) {
                    let options = ranged.map(CoreAudioOutput.option(from:))
                    if let idx = OutputFormatChooser.choosePhysicalFormat(rate: target, sourceBits: format.bitDepth, available: options) {
                        var desc = ranged[idx].mFormat
                        desc.mSampleRate = target
                        targetPhysical = desc
                    }
                }
            }
            let rateDiffers = abs(current - target) >= 0.5
            let physicalDiffers = targetPhysical.map { t in currentPhysical.map { !CoreAudioOutput.matches($0, t) } ?? true } ?? false
            if rateDiffers || physicalDiffers {
                if originals[uid] == nil {
                    originals[uid] = Original(uid: uid, rate: current, physical: currentPhysical)
                }
                if rateDiffers { try CoreAudioOutput.setNominalRate(device, target) }
                if let stream, let t = targetPhysical,
                   let now = try? CoreAudioOutput.physicalFormat(stream), !CoreAudioOutput.matches(now, t) {
                    try CoreAudioOutput.setPhysicalFormat(stream, t)
                }
            }
            lastError = nil
            let rate = (try? CoreAudioOutput.nominalRate(device)) ?? target
            let bits = stream.flatMap { try? CoreAudioOutput.physicalFormat($0) }.map { Int($0.mBitsPerChannel) }
            return OutputState(deviceName: name, sampleRate: rate, bitDepth: bits, sourceRate: source, matched: abs(rate - source) < 0.5)
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    public func restoreAll() {
        lock.lock(); defer { lock.unlock() }
        for (uid, original) in originals {
            guard let device = CoreAudioOutput.deviceID(forUID: uid) else { continue }
            do {
                if let current = try? CoreAudioOutput.nominalRate(device), abs(current - original.rate) >= 0.5 {
                    try CoreAudioOutput.setNominalRate(device, original.rate)
                }
                if let stream = try CoreAudioOutput.outputStreams(device).first, let physical = original.physical,
                   let now = try? CoreAudioOutput.physicalFormat(stream), !CoreAudioOutput.matches(now, physical) {
                    try CoreAudioOutput.setPhysicalFormat(stream, physical)
                }
            } catch {
                lastError = error.localizedDescription
            }
        }
        originals.removeAll()
    }
}
