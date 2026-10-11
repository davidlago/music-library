import AppKit
import Foundation
import MusicLibraryCore
import WebKit

/// Talks to the library catalog's website from inside a hidden web view. The site sits behind Cloudflare, which
/// turns away URLSession but lets a browser engine through, so pages and AJAX calls are `fetch()`ed from the
/// site's own origin in WebKit. The web view uses the default (persistent) website data store, so a sign-in
/// survives relaunches. Page and AJAX requests run one at a time with a short gap, like someone clicking around,
/// and a longer one for background work (downloading the catalog, looking titles up); cover images load
/// alongside them, as they do in a browser. When the site answers 429 (Cloudflare's rate limit), nothing more is
/// sent until a cool-down passes: the server's Retry-After, or a wait that doubles while it keeps happening.
@MainActor
final class LibraryCatalogClient: NSObject, WKNavigationDelegate {
    private(set) var site: URL
    private var webView: WKWebView?
    private var ready = false
    private var starting: Task<Void, Error>?
    private var navigationWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var chain: Task<Void, Never>?
    private var lastRequest = Date.distantPast
    /// No requests before this (after a 429).
    private(set) var cooldownUntil: Date?
    private var backoff: TimeInterval = 60

    enum Priority {
        /// Something the user is waiting for.
        case interactive
        /// Downloads and lookups.
        case background
    }

    /// Seconds between background requests: 8 to start (the site's limit is around 15 a minute sustained for
    /// ten minutes), half again longer after each 429, up to 30. Remembered between launches.
    private var backgroundGap: TimeInterval = max(8, UserDefaults.standard.double(forKey: "catalogBackgroundGap"))

    private func gap(_ priority: Priority) -> TimeInterval { priority == .interactive ? 0.8 : backgroundGap }
    private var imageSlots = 4
    private var imageWaiters: [CheckedContinuation<Void, Never>] = []

    init(site: URL) {
        self.site = site
    }

    func setSite(_ url: URL) {
        guard url != site else { return }
        site = url
        webView?.stopLoading()
        webView = nil
        ready = false
        starting = nil
    }

    /// A page or AJAX reply, by path on the catalog site.
    func get(_ path: String, priority: Priority = .interactive) async throws -> Data {
        try await serialized(priority) { try await self.fetch(path, method: "GET", form: nil, binary: false) }
    }

    /// A form POST (sign-in).
    func post(_ path: String, form: String) async throws -> Data {
        try await serialized(.interactive) { try await self.fetch(path, method: "POST", form: form, binary: false) }
    }

    /// An image (covers), outside the request queue but at most four at a time. Covers usually redirect to a
    /// cover service on another site, which `fetch()` in the page can't follow, so they load with URLSession
    /// (Cloudflare lets cover requests through), falling back to the web view.
    func image(_ path: String) async throws -> Data {
        while imageSlots == 0 { await withCheckedContinuation { imageWaiters.append($0) } }
        imageSlots -= 1
        defer {
            imageSlots += 1
            if !imageWaiters.isEmpty { imageWaiters.removeFirst().resume() }
        }
        if let url = url(for: path) {
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            if let (data, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty,
               (response.mimeType ?? "").hasPrefix("image/") {
                return data
            }
        }
        try await ensureReady()
        return try await fetch(path, method: "GET", form: nil, binary: true)
    }

    func url(for path: String) -> URL? { URL(string: path, relativeTo: site)?.absoluteURL }

    // MARK: Queue

    private func serialized<T: Sendable>(_ priority: Priority, _ operation: @escaping @MainActor () async throws -> T) async throws -> T {
        let previous = chain
        let task = Task { @MainActor () async throws -> T in
            await previous?.value
            if let until = self.cooldownUntil, until > Date() {
                // Background work waits the cool-down out; the user hears about it instead of waiting minutes.
                if priority == .interactive, until.timeIntervalSinceNow > 8 { throw CatalogError.rateLimited(until) }
                try? await Task.sleep(for: .seconds(until.timeIntervalSinceNow))
            }
            try await self.ensureReady()
            let wait = self.lastRequest.addingTimeInterval(self.gap(priority)).timeIntervalSinceNow
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            defer { self.lastRequest = Date() }
            return try await operation()
        }
        chain = Task { _ = await task.result }
        return try await task.value
    }

    // MARK: Web view

    private func ensureReady() async throws {
        if ready, webView != nil { return }
        if let starting { return try await starting.value }
        let task = Task { @MainActor in
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .default()
            // The view is never in a window; by default WebKit suspends such views when idle (between paced
            // requests), which freezes requests in flight.
            config.preferences.inactiveSchedulingPolicy = .none
            let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1024, height: 768), configuration: config)
            view.navigationDelegate = self
            self.webView = view
            try await self.loadHome()
            self.ready = true
        }
        starting = task
        defer { starting = nil }
        try await task.value
    }

    /// Starts over with a fresh page (after Cloudflare turned a request away or the page went away).
    private func restart() async throws {
        ready = false
        try await ensureReady()
    }

    /// Opens the site's home page, waiting out a Cloudflare check if one is shown.
    private func loadHome() async throws {
        guard let webView else { return }
        webView.load(URLRequest(url: site))
        await waitForNavigation(timeout: 30)
        for _ in 0..<4 where await isChallengePage() {
            await waitForNavigation(timeout: 10)
        }
        if await isChallengePage() { throw CatalogError.blocked(403) }
        guard let host = webView.url?.host, host == site.host else {
            throw CatalogError.badResponse("couldn't open \(site.absoluteString)")
        }
    }

    private func isChallengePage() async -> Bool {
        let title = (try? await webView?.evaluateJavaScript("document.title")) as? String ?? ""
        return title.contains("Just a moment") || title.contains("Attention Required") || title.contains("Cloudflare")
    }

    private func waitForNavigation(timeout: TimeInterval) async {
        let id = UUID()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            navigationWaiters[id] = c
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                self?.navigationWaiters.removeValue(forKey: id)?.resume()
            }
        }
    }

    private func finishNavigation() {
        let waiters = navigationWaiters.values
        navigationWaiters = [:]
        waiters.forEach { $0.resume() }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { finishNavigation() }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { finishNavigation() }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { finishNavigation() }
    }

    // MARK: Fetching

    private static let script = """
    const options = {method: method, credentials: 'include', headers: {'X-Requested-With': 'XMLHttpRequest'}};
    if (form !== null) {
        options.body = form;
        options.headers['Content-Type'] = 'application/x-www-form-urlencoded; charset=UTF-8';
    }
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 30000);
    options.signal = controller.signal;
    const r = await fetch(path, options);
    clearTimeout(timer);
    const retryAfter = r.headers.get('retry-after');
    if (!binary) return {status: r.status, body: await r.text(), retryAfter: retryAfter};
    const bytes = new Uint8Array(await r.arrayBuffer());
    let s = '';
    for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
    return {status: r.status, body: btoa(s)};
    """

    private func fetch(_ path: String, method: String, form: String?, binary: Bool, retried: Bool = false) async throws -> Data {
        guard let webView else { throw CatalogError.badResponse("the catalog isn't loaded") }
        let args: [String: Any] = ["path": path, "method": method, "form": form ?? NSNull(), "binary": binary]
        let started = Date()
        let reply: Reply
        do {
            reply = try await Self.withTimeout(45) {
                let raw = try await webView.callAsyncJavaScript(Self.script, arguments: args, contentWorld: .page) as? [String: Any]
                guard let raw, let status = raw["status"] as? Int, let body = raw["body"] as? String else {
                    throw CatalogError.badResponse("no reply")
                }
                return Reply(status: status, body: body, retryAfter: raw["retryAfter"] as? String)
            }
        } catch let error as CatalogError {
            throw error
        } catch {
            CatalogLog.write("\(method) \(path) failed after \(Self.elapsed(started)): \(error.localizedDescription)")
            // The page may have gone away or stopped answering (a network change, a crashed or suspended web
            // content process): start over with a fresh page, once.
            guard !retried else { throw CatalogError.badResponse(error.localizedDescription) }
            webView.stopLoading()
            self.webView = nil
            try await restart()
            return try await fetch(path, method: method, form: form, binary: binary, retried: true)
        }
        let status = reply.status, body = reply.body
        let data = binary ? (Data(base64Encoded: body) ?? Data()) : Data(body.utf8)
        CatalogLog.write("\(method) \(path) \(status) \(data.count)B \(Self.elapsed(started))")
        if status == 429 || (status == 503 && body.contains("1015")) {
            // Rate limited: back off (doubling while it keeps happening) instead of retrying.
            let retryAfter = reply.retryAfter.flatMap(TimeInterval.init) ?? 0
            let until = Date().addingTimeInterval(max(retryAfter, backoff))
            cooldownUntil = until
            backgroundGap = min(backgroundGap * 1.5, 30)
            UserDefaults.standard.set(backgroundGap, forKey: "catalogBackgroundGap")
            CatalogLog.write("rate limited; pausing until \(until.formatted(date: .omitted, time: .standard)), then one background request every \(Int(backgroundGap)) s")
            backoff = min(backoff * 2, 15 * 60)
            throw CatalogError.rateLimited(until)
        }
        switch status {
        case 200:
            backoff = 60
            return data
        case 403, 503:
            // Cloudflare may want its browser check again; reload the home page and retry once.
            guard !retried else { throw CatalogError.blocked(status) }
            try await restart()
            return try await fetch(path, method: method, form: form, binary: binary, retried: true)
        default:
            throw CatalogError.http(status)
        }
    }

    struct Reply: Sendable {
        var status: Int
        var body: String
        var retryAfter: String?
    }

    static func elapsed(_ start: Date) -> String { String(format: "%.1fs", Date().timeIntervalSince(start)) }

    /// Runs `operation`, giving up with a timeout error after `seconds` (the operation itself can't be cancelled).
    static func withTimeout<T: Sendable>(_ seconds: TimeInterval, _ operation: @escaping @MainActor () async throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            let once = ResumeOnce(continuation)
            Task { @MainActor in
                do { once.resume(.success(try await operation())) } catch { once.resume(.failure(error)) }
            }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                once.resume(.failure(TimeoutError(seconds: seconds)))
            }
        }
    }

    struct TimeoutError: LocalizedError {
        var seconds: TimeInterval
        var errorDescription: String? { "The library's website didn't answer in \(Int(seconds)) seconds." }
    }

    /// Resumes a continuation with whichever result comes first.
    final class ResumeOnce<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Error>?

        init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }

        func resume(_ result: Result<T, Error>) {
            lock.lock()
            let c = continuation
            continuation = nil
            lock.unlock()
            c?.resume(with: result)
        }
    }
}

/// A plain log of catalog requests, for diagnosing slow or stuck downloads:
/// `~/Library/Logs/MusicLibrary/catalog.log` (started over past 2 MB).
@MainActor
enum CatalogLog {
    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/MusicLibrary/catalog.log")
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func write(_ line: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 2_000_000 { try? fm.removeItem(at: url) }
        let data = Data("\(formatter.string(from: Date())) \(line)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
