import Foundation
import MusicLibraryCore
import Observation
import SwiftUI
import WebKit

/// Whether the user has signed in to eBay in the app (opt-in, for the price guide's sold listings: eBay shows those
/// only to signed-in visitors). The sign-in happens on eBay's own page in `EbaySignInView`; the app never sees the
/// password, only keeps the cookies eBay sets, in the default website data store the hidden page loader uses. Only
/// whether it's signed in is remembered (user defaults `ebaySignedIn`); a sold search that lands on eBay's sign-in
/// page again marks it expired.
@MainActor @Observable
public final class EbaySession {
    public static let defaultsKey = "ebaySignedIn"

    public private(set) var isSignedIn: Bool
    /// eBay asked to sign in again since the last sign-in.
    public private(set) var expired = false

    public init() {
        isSignedIn = UserDefaults.standard.bool(forKey: Self.defaultsKey)
    }

    /// eBay's sign-in, landing on its home page.
    public static let signInURL = URL(string: "https://signin.ebay.com/ws/eBayISAPI.dll?SignIn&ru=https%3A%2F%2Fwww.ebay.com%2F")!

    /// eBay's sign-in page, or a check on the way to it.
    public static func isSignInPage(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        return host == "signin.ebay.com" || (host.hasSuffix("ebay.com") && url.absoluteString.contains("signin.ebay.com"))
    }

    func signedIn() {
        isSignedIn = true
        expired = false
        UserDefaults.standard.set(true, forKey: Self.defaultsKey)
    }

    func signInExpired() {
        guard isSignedIn else { return }
        isSignedIn = false
        expired = true
        UserDefaults.standard.set(false, forKey: Self.defaultsKey)
    }

    /// Forgets eBay's cookies and site data (the next eBay page starts fresh, signed out).
    public func signOut() async {
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types).filter { $0.displayName.lowercased().contains("ebay") }
        await store.removeData(ofTypes: types, for: records)
        isSignedIn = false
        expired = false
        UserDefaults.standard.set(false, forKey: Self.defaultsKey)
    }
}

/// eBay's own sign-in page, in a web view sharing the hidden loader's cookies. It closes itself once eBay shows the
/// user signed in (its header greets them by name).
public struct EbaySignInView: View {
    let session: EbaySession
    let done: () -> Void
    @StateObject private var web = EbaySignInWeb()

    public init(session: EbaySession, done: @escaping () -> Void) {
        self.session = session
        self.done = done
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sign in to eBay").font(.headline)
                Spacer()
                if web.isLoading { ProgressView().controlSize(.small) }
                Button("Cancel", action: done)
            }
            .padding(12)
            Text("Sign in on eBay's own page: Music Library never sees your password, it only keeps eBay's cookies so the price guide can read recent sold prices. Sign out in Settings to forget them.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.bottom, 8)
            Divider()
            WebViewHost(view: web.view)
        }
        .onAppear {
            web.onSignedIn = {
                session.signedIn()
                done()
            }
            web.start()
        }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 520, minHeight: 640, idealHeight: 720)
        #endif
    }
}

@MainActor
final class EbaySignInWeb: NSObject, WKNavigationDelegate, ObservableObject {
    let view: WKWebView
    var onSignedIn: () -> Void = {}
    @Published var isLoading = false
    private var finished = false

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        view = WKWebView(frame: .zero, configuration: config)
        super.init()
        view.navigationDelegate = self
    }

    func start() {
        guard view.url == nil else { return }
        view.load(URLRequest(url: EbaySession.signInURL))
    }

    /// After each page: signed in once eBay's own pages (not the sign-in) greet the user by name.
    private func check() {
        guard !finished, let url = view.url, url.host?.lowercased().hasSuffix("ebay.com") == true,
              !EbaySession.isSignInPage(url) else { return }
        Task {
            let greeting = (try? await view.evaluateJavaScript(
                "(document.querySelector('#gh-ug, .gh-identity__greeting, .gh-identity') || {}).textContent || ''")) as? String ?? ""
            let text = greeting.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty, !text.localizedCaseInsensitiveContains("sign in"), !finished {
                finished = true
                onSignedIn()
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        MainActor.assumeIsolated { isLoading = true }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            isLoading = false
            check()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { isLoading = false }
    }
}

#if os(macOS)
struct WebViewHost: NSViewRepresentable {
    let view: WKWebView
    func makeNSView(context: Context) -> WKWebView { view }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#else
struct WebViewHost: UIViewRepresentable {
    let view: WKWebView
    func makeUIView(context: Context) -> WKWebView { view }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#endif
