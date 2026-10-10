import Foundation

public enum AcoustIDParser {
    public static func parse(_ data: Data, limit: Int = 25) throws -> [MatchCandidate] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NetworkError.badResponse("AcoustID response is not a JSON object")
        }
        if (root["status"] as? String) != "ok" {
            let msg = (root["error"] as? [String: Any])?["message"] as? String ?? "status not ok"
            throw NetworkError.badResponse("AcoustID: \(msg)")
        }
        var out: [MatchCandidate] = []
        for result in root["results"] as? [[String: Any]] ?? [] {
            let score = Int(((result["score"] as? Double) ?? 0) * 100 + 0.5)
            for rec in result["recordings"] as? [[String: Any]] ?? [] {
                guard let rid = rec["id"] as? String else { continue }
                let artists = rec["artists"] as? [[String: Any]] ?? []
                let artist = artists.map { ($0["name"] as? String ?? "") + ($0["joinphrase"] as? String ?? "") }.joined()
                let title = rec["title"] as? String ?? ""
                let duration = (rec["duration"] as? Double)
                for rg in rec["releasegroups"] as? [[String: Any]] ?? [] {
                    for rel in rg["releases"] as? [[String: Any]] ?? [] {
                        guard let relId = rel["id"] as? String else { continue }
                        var date: String?
                        var year: Int?
                        if let d = rel["date"] as? [String: Any], let y = d["year"] as? Int {
                            year = y
                            date = String(format: "%04d", y)
                            if let mo = d["month"] as? Int {
                                date! += String(format: "-%02d", mo)
                                if let dd = d["day"] as? Int { date! += String(format: "-%02d", dd) }
                            }
                        }
                        out.append(MatchCandidate(
                            recordingId: rid, releaseId: relId, releaseGroupId: rg["id"] as? String,
                            title: title, artist: artist, album: rel["title"] as? String ?? (rg["title"] as? String ?? ""),
                            date: date, year: year, durationSeconds: duration, score: score,
                            releaseType: rg["type"] as? String, releaseStatus: nil, source: .acoustID))
                    }
                }
            }
        }
        let sorted = out.enumerated().sorted { a, b in
            if a.element.score != b.element.score { return a.element.score > b.element.score }
            return a.offset < b.offset
        }.map(\.element)
        return Array(sorted.prefix(limit))
    }
}

public struct AcoustIDClient: Sendable {
    public let apiKey: String
    public let fpcalc: URL
    private let session: URLSession

    public init?(apiKey: String, tools: ToolLocator = ToolLocator(), session: URLSession = .shared) {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, let fp = tools.fpcalc else { return nil }
        self.apiKey = key; self.fpcalc = fp; self.session = session
    }

    public static func parseFingerprint(_ data: Data) throws -> (duration: Int, fingerprint: String) {
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fp = o["fingerprint"] as? String,
              let d = (o["duration"] as? Double) ?? (o["duration"] as? Int).map(Double.init) else {
            throw NetworkError.badResponse("fpcalc output not understood")
        }
        return (Int(d.rounded()), fp)
    }

    public func lookup(file: URL) async throws -> [MatchCandidate] {
        let out = try await ProcessRunner.run(fpcalc, ["-json", file.path])
        let (duration, fingerprint) = try Self.parseFingerprint(out.stdout)
        var request = URLRequest(url: URL(string: "https://api.acoustid.org/v2/lookup")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var c = URLComponents()
        c.queryItems = [
            .init(name: "client", value: apiKey), .init(name: "duration", value: String(duration)),
            .init(name: "fingerprint", value: fingerprint),
            .init(name: "meta", value: "recordings releasegroups releases"),
        ]
        request.httpBody = Data((c.percentEncodedQuery ?? "").utf8)
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw NetworkError.http(code, "api.acoustid.org") }
        return try AcoustIDParser.parse(data)
    }
}
