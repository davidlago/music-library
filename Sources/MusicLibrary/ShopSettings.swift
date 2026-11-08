import MusicLibraryCore
import MusicLibraryUI
import SwiftUI

/// Settings ▸ Shop: where the price guide's figures come from, and the opt-in eBay sign-in for recent sales.
struct ShopSettings: View {
    @Environment(AppModel.self) private var model
    @State private var signingIn = false

    var body: some View {
        let ebay = model.cdShop.ebay
        let discogs = model.discogsSync
        Form {
            Section {
                Text("The Shop's price guide shows what an album sells for: Discogs' marketplace (the cheapest copies and how many people have and want each edition) and eBay's listings. With your Discogs account it adds Discogs' suggested prices by condition and the versions already in your Discogs collection; signed in to eBay, it adds what copies actually sold for recently.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Discogs") {
                LabeledContent("Account") {
                    if let user = discogs.username, discogs.hasToken {
                        Label("Connected as \(user)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Text("Not connected: connect in the Discogs tab").foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                LabeledContent("Sold listings") {
                    HStack {
                        if ebay.isSignedIn {
                            Label("Signed in", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                            Button("Sign Out") { Task { await ebay.signOut() } }
                        } else {
                            if ebay.expired {
                                Label("Sign-in expired", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                            }
                            Button("Sign In to eBay…") { signingIn = true }
                        }
                    }
                }
            } header: {
                Text("eBay")
            } footer: {
                Text("eBay shows sold listings only to signed-in visitors. You sign in on eBay's own page: Music Library never sees your password, it keeps only eBay's cookies, and reads a sold search only when you open an album in the Shop or ask the Radio DJ about a price. Signing out forgets them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: 420)
        .sheet(isPresented: $signingIn) {
            EbaySignInView(session: ebay) { signingIn = false }
        }
    }
}
