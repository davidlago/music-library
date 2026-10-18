import AppKit
import Foundation
import MusicLibraryCore
import WebKit

enum CDShopError: LocalizedError {
    case blocked
    case timedOut
    case unexpectedPage

    var errorDescription: String? {
        switch self {
        case .blocked: "The site asked to check that you're not a robot. Open it in your browser instead."
        case .timedOut: "The site didn't answer in time."
        case .unexpectedPage: "The site showed an unexpected page."
        }
    }
}

/// Opens marketplace pages in hidden web views, one per store, and hands back the HTML as WebKit rendered it.
/// The stores sit behind bot checks (Cloudflare, eBay's own) that turn URLSession away but let a browser engine
/// through after a moment, and Discogs draws its listings with script. Nothing is signed in to. Each store gets
/// one page at a time, a few seconds apart, like someone browsing; the default (persistent) website data store
/// keeps the cookies the checks set, so later visits go straight through.
@MainActor
final class CDShopPageLoader: NSObject, WKNavigationDelegate {
    private var views: [CDShop: WKWebView] = [:]
    private var chains: [CDShop: Task<Void, Never>] = [:]
    private var lastLoad: [CDShop: Date] = [:]
    private var waiters: [ObjectIdentifier: [CheckedContinuation<Void, Never>]] = [:]

    static let gap: TimeInterval = 3

    /// Elements that show a page has its listings, or says it has none.
    private static func readySelector(_ shop: CDShop) -> String? {
        switch shop {
        case .discogs: "article.msr-listing-card, [class*='empty-state'], [class*='no-results'], [class*='NoResults']"
        default: nil
        }
    }

    func html(_ url: URL, shop: CDShop) async throws -> String {
        let previous = chains[shop]
        let task = Task { @MainActor () async throws -> String in
            await previous?.value
            if let last = lastLoad[shop] {
                let wait = last.addingTimeInterval(Self.gap).timeIntervalSinceNow
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            }
            defer { lastLoad[shop] = Date() }
            return try await load(url, shop: shop)
        }
        chains[shop] = Task { _ = await task.result }
        return try await task.value
    }

    private func view(for shop: CDShop) -> WKWebView {
        if let v = views[shop] { return v }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        // The view is never in a window; by default WebKit suspends such views, freezing their pages.
        config.preferences.inactiveSchedulingPolicy = .none
        config.mediaTypesRequiringUserActionForPlayback = .all
        // Tall, because Discogs only draws the listings in view.
        let v = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 10_000), configuration: config)
        v.navigationDelegate = self
        views[shop] = v
        return v
    }

    private func load(_ url: URL, shop: CDShop, attempt: Int = 0) async throws -> String {
        let v = view(for: shop)
        v.load(URLRequest(url: url))
        await waitForNavigation(v, timeout: 30)
        let started = Date()
        var lastLength = -1
        while true {
            let title = (try? await v.evaluateJavaScript("document.title")) as? String ?? ""
            if CDShopParser.isChallenge(title: title) {
                if Date().timeIntervalSince(started) > 25 { throw CDShopError.blocked }
            } else if shop == .ebay, title.hasPrefix("Error Page") {
                // eBay turns searches away now and then, more so in a row (and wants its home page first on a
                // fresh start); waiting a little longer each time gets them through.
                guard attempt < 3 else { throw CDShopError.unexpectedPage }
                if attempt == 0 {
                    v.load(URLRequest(url: shop.home))
                    await waitForNavigation(v, timeout: 30)
                }
                try? await Task.sleep(for: .seconds(2 + 3 * Double(attempt)))
                return try await load(url, shop: shop, attempt: attempt + 1)
            } else if let host = v.url, !shop.owns(host) {
                throw CDShopError.unexpectedPage
            } else if let selector = Self.readySelector(shop) {
                let found = (try? await v.callAsyncJavaScript("return document.querySelector(s) !== null",
                                                              arguments: ["s": selector], contentWorld: .page)) as? Bool ?? false
                let length = (try? await v.evaluateJavaScript("document.body ? document.body.innerHTML.length : 0")) as? Int ?? 0
                if found {
                    // Let the rest of the list draw.
                    try? await Task.sleep(for: .seconds(1))
                    break
                }
                // No listings: once the page has stopped changing for a while, it has none.
                if length == lastLength, Date().timeIntervalSince(started) > 12 { break }
                lastLength = length
            } else {
                break
            }
            if Date().timeIntervalSince(started) > 40 { throw CDShopError.timedOut }
            try? await Task.sleep(for: .seconds(0.75))
        }
        return (try await v.evaluateJavaScript("document.documentElement.outerHTML")) as? String ?? ""
    }

    // MARK: Navigation

    private func waitForNavigation(_ view: WKWebView, timeout: TimeInterval) async {
        let key = ObjectIdentifier(view)
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            waiters[key, default: []].append(c)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                self?.finish(key)
            }
        }
    }

    private func finish(_ key: ObjectIdentifier) {
        let list = waiters.removeValue(forKey: key) ?? []
        list.forEach { $0.resume() }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { finish(ObjectIdentifier(webView)) }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { finish(ObjectIdentifier(webView)) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { finish(ObjectIdentifier(webView)) }
    }
}
