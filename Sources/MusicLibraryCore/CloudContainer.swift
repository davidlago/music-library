import Foundation
import os

/// The app's iCloud container (`docs/icloud-plan.md`). Its identifier is the `MusicLibraryICloudContainer` key of the
/// bundle's Info.plist: `scripts/build-app.sh` writes it for a Mac build signed with an iCloud provisioning profile,
/// and the iPhone app's comes from the `ICLOUD_CONTAINER` build setting. Without the key, the entitlement or an iCloud
/// account there's no container, and nothing of iCloud shows.
public enum CloudContainer {
    public static let infoKey = "MusicLibraryICloudContainer"

    /// The container's identifier, if the bundle names a well-formed one.
    public static func identifier(in bundle: Bundle = .main) -> String? {
        identifier(from: bundle.object(forInfoDictionaryKey: infoKey))
    }

    static func identifier(from value: Any?) -> String? {
        guard let id = value as? String, isValid(id) else { return nil }
        return id
    }

    /// "iCloud." and a reverse-DNS name of letters, digits and hyphens; an unexpanded "$(…)" isn't one.
    static func isValid(_ id: String) -> Bool {
        let prefix = "iCloud."
        guard id.hasPrefix(prefix), id.utf8.count <= 255 else { return false }
        let parts = id.dropFirst(prefix.count).split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 2 && parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }

    /// The container's folder, or nil when the app isn't entitled to it or isn't signed in to iCloud. It can block
    /// while iCloud sets the container up, so never call it on the main thread.
    public static func url(identifier: String) -> URL? {
        guard FileManager.default.ubiquityIdentityToken != nil else { return nil }
        return FileManager.default.url(forUbiquityContainerIdentifier: identifier)
    }

    /// Looks for the container in the background and logs what it found (subsystem `local.musiclibrary`, category
    /// `iCloud`), so a signed build can be checked before anything uses it.
    public static func logAvailability(in bundle: Bundle = .main) {
        guard let id = identifier(in: bundle) else { return }
        Task.detached(priority: .utility) {
            let log = Logger(subsystem: "local.musiclibrary", category: "iCloud")
            if FileManager.default.ubiquityIdentityToken == nil {
                log.notice("iCloud container \(id, privacy: .public): not signed in to iCloud")
            } else if let url = FileManager.default.url(forUbiquityContainerIdentifier: id) {
                log.notice("iCloud container \(id, privacy: .public): \(url.path, privacy: .public)")
            } else {
                log.error("iCloud container \(id, privacy: .public): unavailable (not in the app's entitlements?)")
            }
        }
    }
}
