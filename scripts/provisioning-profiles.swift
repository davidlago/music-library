// Makes sure each bundle ID has an App Store provisioning profile that includes the Apple Distribution certificate in
// the keychain, creating or replacing them through the App Store Connect API, and installs them for Xcode.
//
//   swift scripts/provisioning-profiles.swift <key.p8> <key ID> <issuer ID> <bundle ID>...
//
// Each profile is named "<bundle ID> App Store (CI)" (`profileName` below; scripts/testflight.sh uses the same names).
// Used by scripts/testflight.sh with DISTRIBUTION_CERTIFICATE=1 (CI), where an App Manager API key can't use Xcode's
// cloud-managed signing.
import CryptoKit
import Foundation
import Security

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

let args = CommandLine.arguments.dropFirst()
guard args.count >= 4 else { fail("usage: provisioning-profiles.swift <key.p8> <key ID> <issuer ID> <bundle ID>...") }
let keyPath = args[args.startIndex], keyID = args[args.startIndex + 1], issuer = args[args.startIndex + 2]
let bundleIDs = Array(args.dropFirst(3))

func profileName(_ bundleID: String) -> String { "\(bundleID) App Store (CI)" }

// MARK: App Store Connect API

func base64URL(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

let token: String = {
    guard let pem = try? String(contentsOfFile: keyPath, encoding: .utf8),
          let key = try? P256.Signing.PrivateKey(pemRepresentation: pem) else { fail("can't read the API key \(keyPath)") }
    let now = Int(Date().timeIntervalSince1970)
    let header = try! JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": keyID, "typ": "JWT"])
    let claims = try! JSONSerialization.data(withJSONObject: ["iss": issuer, "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"])
    let input = base64URL(header) + "." + base64URL(claims)
    let signature = try! key.signature(for: Data(input.utf8))
    return input + "." + base64URL(signature.rawRepresentation)
}()

@discardableResult
func api(_ method: String, _ path: String, query: [String: String] = [:], body: [String: Any]? = nil) async -> [String: Any] {
    var components = URLComponents(string: "https://api.appstoreconnect.apple.com/v1/\(path)")!
    if !query.isEmpty { components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
    var request = URLRequest(url: components.url!)
    request.httpMethod = method
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    if let body {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try! JSONSerialization.data(withJSONObject: body)
    }
    guard let (data, response) = try? await URLSession.shared.data(for: request), let http = response as? HTTPURLResponse else {
        fail("\(method) \(path): no response")
    }
    guard (200..<300).contains(http.statusCode) else {
        fail("\(method) \(path): HTTP \(http.statusCode) \(String(decoding: data, as: UTF8.self))")
    }
    if data.isEmpty { return [:] }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
}

func items(_ response: [String: Any]) -> [[String: Any]] { response["data"] as? [[String: Any]] ?? [] }
func attributes(_ item: [String: Any]) -> [String: Any] { item["attributes"] as? [String: Any] ?? [:] }

// MARK: The certificate

/// Serial numbers of the valid "Apple Distribution" signing identities in the keychain, as uppercase hex without
/// leading zeros (how the API lists them).
func keychainDistributionSerials() -> Set<String> {
    let query: [String: Any] = [kSecClass as String: kSecClassIdentity, kSecMatchLimit as String: kSecMatchLimitAll,
                                kSecReturnRef as String: true]
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let identities = result as? [SecIdentity] else { return [] }
    var serials = Set<String>()
    for identity in identities {
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate,
              let summary = SecCertificateCopySubjectSummary(certificate) as String?, summary.hasPrefix("Apple Distribution:"),
              let serial = SecCertificateCopySerialNumberData(certificate, nil) as Data? else { continue }
        serials.insert(normalizedSerial(serial.map { String(format: "%02X", $0) }.joined()))
    }
    return serials
}

func normalizedSerial(_ hex: String) -> String {
    let trimmed = hex.uppercased().drop { $0 == "0" }
    return trimmed.isEmpty ? "0" : String(trimmed)
}

// MARK: Main

let serials = keychainDistributionSerials()
guard !serials.isEmpty else { fail("no Apple Distribution identity in the keychain") }
let certificates = items(await api("GET", "certificates", query: ["filter[certificateType]": "DISTRIBUTION", "limit": "200"]))
guard let certificate = certificates.first(where: {
    serials.contains(normalizedSerial(attributes($0)["serialNumber"] as? String ?? ""))
}), let certificateID = certificate["id"] as? String else {
    fail("the keychain's Apple Distribution certificate isn't one of the team's (revoked or from another team?)")
}

let home = FileManager.default.homeDirectoryForCurrentUser
let installDirs = ["Library/MobileDevice/Provisioning Profiles", "Library/Developer/Xcode/UserData/Provisioning Profiles"]
    .map { home.appendingPathComponent($0) }

for bundleID in bundleIDs {
    let name = profileName(bundleID)
    let bundles = items(await api("GET", "bundleIds", query: ["filter[identifier]": bundleID, "limit": "200"]))
    guard let bundle = bundles.first(where: { attributes($0)["identifier"] as? String == bundleID }),
          let bundleResourceID = bundle["id"] as? String else {
        fail("\(bundleID) isn't registered (build it once with automatic signing, or register it in the developer portal)")
    }

    var content: String?, uuid: String?
    let existing = await api("GET", "profiles", query: ["filter[name]": name, "include": "certificates", "limit": "200"])
    for profile in items(existing) where attributes(profile)["name"] as? String == name {
        let certificateIDs = (((profile["relationships"] as? [String: Any])?["certificates"] as? [String: Any])?["data"] as? [[String: Any]] ?? [])
            .compactMap { $0["id"] as? String }
        if content == nil, attributes(profile)["profileState"] as? String == "ACTIVE", certificateIDs.contains(certificateID) {
            content = attributes(profile)["profileContent"] as? String
            uuid = attributes(profile)["uuid"] as? String
        } else if let id = profile["id"] as? String {
            await api("DELETE", "profiles/\(id)")   // expired, or made for another certificate
        }
    }
    if content == nil {
        let created = await api("POST", "profiles", body: ["data": [
            "type": "profiles",
            "attributes": ["name": name, "profileType": "IOS_APP_STORE"],
            "relationships": [
                "bundleId": ["data": ["type": "bundleIds", "id": bundleResourceID]],
                "certificates": ["data": [["type": "certificates", "id": certificateID]]],
            ],
        ]])
        content = attributes(created["data"] as? [String: Any] ?? [:])["profileContent"] as? String
        uuid = attributes(created["data"] as? [String: Any] ?? [:])["uuid"] as? String
        print("Created \(name)")
    } else {
        print("Using \(name)")
    }
    guard let content, let uuid, let data = Data(base64Encoded: content) else { fail("no content for \(name)") }
    // Xcode finds installed profiles by file name: <UUID>.mobileprovision.
    for dir in installDirs {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard (try? data.write(to: dir.appendingPathComponent("\(uuid).mobileprovision"))) != nil else {
            fail("can't install \(name) in \(dir.path)")
        }
    }
}
