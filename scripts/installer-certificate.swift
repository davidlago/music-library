// Creates a Mac Installer Distribution certificate for a certificate signing request through the App Store Connect API
// and saves it (DER). The Mac App Store takes the Mac app as a .pkg signed with it ("3rd Party Mac Developer
// Installer: …"); scripts/mac-installer-certificate.sh makes the key and request, runs this, and stores the result.
//
//   swift scripts/installer-certificate.swift <key.p8> <key ID> <issuer ID> <request.csr> <out.cer>
//
// Lists the team's other Mac Installer Distribution certificates first: Apple allows only a few, so an old one may
// have to be revoked (developer.apple.com ▸ Certificates) before a new one can be made.
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

let args = Array(CommandLine.arguments.dropFirst())
guard args.count == 5 else {
    fail("usage: installer-certificate.swift <key.p8> <key ID> <issuer ID> <request.csr> <out.cer>")
}
let keyPath = args[0], keyID = args[1], issuer = args[2], csrPath = args[3], outPath = args[4]

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
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
}

func attributes(_ item: [String: Any]) -> [String: Any] { item["attributes"] as? [String: Any] ?? [:] }

let existing = await api("GET", "certificates", query: ["filter[certificateType]": "MAC_INSTALLER_DISTRIBUTION", "limit": "200"])
for item in existing["data"] as? [[String: Any]] ?? [] {
    let a = attributes(item)
    print("Existing: \(a["name"] as? String ?? "?") (serial \(a["serialNumber"] as? String ?? "?"), expires \(a["expirationDate"] as? String ?? "?"))")
}

// The request as the API wants it: the PEM's base64 body.
guard let pem = try? String(contentsOfFile: csrPath, encoding: .utf8) else { fail("can't read \(csrPath)") }
let csr = pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
let created = await api("POST", "certificates", body: ["data": [
    "type": "certificates",
    "attributes": ["certificateType": "MAC_INSTALLER_DISTRIBUTION", "csrContent": csr],
]])
let a = attributes(created["data"] as? [String: Any] ?? [:])
guard let content = a["certificateContent"] as? String, let der = Data(base64Encoded: content) else {
    fail("the API returned no certificate")
}
guard (try? der.write(to: URL(fileURLWithPath: outPath))) != nil else { fail("can't save \(outPath)") }
print("Created \(a["name"] as? String ?? "the certificate") (serial \(a["serialNumber"] as? String ?? "?"), expires \(a["expirationDate"] as? String ?? "?"))")
