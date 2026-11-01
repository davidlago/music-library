import Foundation

/// A Mac build signed for iCloud has a registered bundle ID instead of `local.musiclibrary`, and with it its own user
/// defaults domain. `scripts/build-app.sh` names the domain it replaces in the Info.plist key
/// `MusicLibraryImportsDefaultsFrom`, and the app copies that domain's settings (library folder, paired phones, Export
/// List, window frames…) once at launch, before anything reads one.
public enum DefaultsImport {
    public static let infoKey = "MusicLibraryImportsDefaultsFrom"
    static let doneKey = "importedDefaultsFrom"

    /// Imports the settings of the domain the bundle names, if it names one other than its own.
    public static func runIfAsked(bundle: Bundle = .main, defaults: UserDefaults = .standard) {
        guard let old = bundle.object(forInfoDictionaryKey: infoKey) as? String, !old.isEmpty,
              let id = bundle.bundleIdentifier, old != id else { return }
        run(from: old, into: defaults, domain: id)
    }

    /// Copies every setting of `oldDomain` that `domain` (the persistent domain `defaults` writes to) doesn't have,
    /// once: afterwards `doneKey` records `oldDomain`, also when it had nothing, so settings an older build writes
    /// later never come over. Returns how many settings were copied.
    @discardableResult
    public static func run(from oldDomain: String, into defaults: UserDefaults, domain: String) -> Int {
        guard defaults.string(forKey: doneKey) != oldDomain else { return 0 }
        let existing = defaults.persistentDomain(forName: domain) ?? [:]
        var copied = 0
        for (key, value) in defaults.persistentDomain(forName: oldDomain) ?? [:]
        where key != doneKey && existing[key] == nil {
            defaults.set(value, forKey: key)
            copied += 1
        }
        defaults.set(oldDomain, forKey: doneKey)
        return copied
    }
}
