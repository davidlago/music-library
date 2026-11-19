#if os(macOS)
import Foundation
import IOKit

/// Brings the Developer ID build's settings over to the Mac App Store build on the same Mac.
///
/// The sandboxed store build keeps its user defaults in its container and can't read the download's, so on its own it
/// would start over: no appearance, no paired phones, and a new Mac ID, which makes the iCloud backup think it moved
/// to another Mac. The folder they share is the library: the download (unsandboxed) writes its settings into
/// `<library>/.MusicLibrary-settings.plist` at launch and when it quits, and the store build reads them before
/// anything else does, once (`importedKey`). Only the same Mac's file is taken (`machineID`), so a library moved to
/// another Mac never gives it this Mac's ID. Secrets don't go through here: they're in the keychain the two share
/// through their App ID (`KeychainStore`).
public enum SettingsHandoff {
    public static let fileName = ".MusicLibrary-settings.plist"
    /// The exported file's date, recorded once its settings have been taken.
    public static let importedKey = "importedSettingsHandoff"
    static let format = 1

    /// This Mac's hardware UUID (IOPlatformUUID); nil if it can't be read.
    public static let machineID: String? = {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
    }()

    /// Settings that belong to one build and are never handed over: sandbox bookmarks, and the import markers.
    static func isHandedOver(_ key: String) -> Bool {
        !key.hasSuffix("Bookmark") && key != importedKey && key != "importedDefaultsFrom"
    }

    /// Writes `settings` (the download's whole defaults domain) into the library folder `root`, unless the file
    /// already holds the same. Returns true when it wrote.
    @discardableResult
    public static func export(_ settings: [String: Any], to root: URL, machineID: String? = machineID,
                              now: Date = Date()) -> Bool {
        guard let machineID, FileManager.default.fileExists(atPath: root.path) else { return false }
        let kept = settings.filter { isHandedOver($0.key) }
        let file = root.appendingPathComponent(fileName)
        if let data = try? Data(contentsOf: file),
           let old = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           old["machine"] as? String == machineID, NSDictionary(dictionary: old["settings"] as? [String: Any] ?? [:])
            .isEqual(to: kept) {
            return false
        }
        let plist: [String: Any] = ["format": format, "machine": machineID, "exportedAt": now, "settings": kept]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0) else {
            return false
        }
        return (try? data.write(to: file, options: .atomic)) != nil
    }

    /// Takes the settings the download left in the library folder `root` into `defaults`, replacing what this build
    /// has under the same keys (its own are only what it made since it was installed, such as a new Mac ID), once
    /// per exported file. Returns how many settings were taken. The file is untrusted: another Mac's, another
    /// format's or a malformed one is ignored.
    @discardableResult
    public static func importIfNeeded(from root: URL, into defaults: UserDefaults = .standard,
                                      machineID: String? = machineID) -> Int {
        let file = root.appendingPathComponent(fileName)
        guard let machineID, let data = try? Data(contentsOf: file), data.count < 4_000_000,
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              plist["format"] as? Int == format, plist["machine"] as? String == machineID,
              let exportedAt = plist["exportedAt"] as? Date, let settings = plist["settings"] as? [String: Any]
        else { return 0 }
        if let done = defaults.object(forKey: importedKey) as? Date, done >= exportedAt { return 0 }
        var taken = 0
        for (key, value) in settings where isHandedOver(key) {
            defaults.set(value, forKey: key)
            taken += 1
        }
        defaults.set(exportedAt, forKey: importedKey)
        return taken
    }
}
#endif
