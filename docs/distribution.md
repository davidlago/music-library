# Distribution

How the Mac app is signed and notarized for the Releases page, and how the iPhone app gets to TestFlight. Both need a
paid Apple Developer Program membership; the steps below are one-time setup unless noted.

## Mac app: Developer ID and notarization

The Mac app is distributed outside the Mac App Store. Signed with a Developer ID certificate and notarized by Apple, it
opens without Gatekeeper warnings, and it carries its own ffmpeg, ffprobe and fpcalc (`scripts/build-tools.sh`, LGPL
builds of FFmpeg and Chromaprint, in `Contents/Helpers`), so it needs nothing from Homebrew.

### 1. Create the Developer ID certificate

In Xcode: **Settings ▸ Accounts**, select your team, **Manage Certificates…**, **+** ▸ **Developer ID Application**.
Only the team's Account Holder can create one. Check it's in your keychain:

```bash
security find-identity -v -p codesigning
```

It shows up as `Developer ID Application: Your Name (TEAMID)`.

### 2. Create an App Store Connect API key

Notarization (and, optionally, TestFlight uploads) sign in with an API key. In
[App Store Connect](https://appstoreconnect.apple.com) ▸ **Users and Access** ▸ **Integrations** ▸ **App Store Connect API**
▸ **Team Keys**, click **+**, name it (for example "Music Library releases") and give it the **App Manager** role. Download
the `.p8` file (Apple lets you download it only once) and note the **Key ID** and the **Issuer ID** shown above the list.

Save it for local use in a keychain profile:

```bash
xcrun notarytool store-credentials music-library --key ~/path/to/AuthKey_XXXXXXXXXX.p8 --key-id XXXXXXXXXX --issuer xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```

### 3. Build and notarize on your Mac

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" UNIVERSAL=1 VERSION=1.13.0 scripts/build-app.sh
NOTARY_PROFILE=music-library scripts/notarize.sh
```

`notarize.sh` uploads the app to Apple's notary service (usually a few minutes), staples the ticket to
`build/MusicLibrary.app` and checks that Gatekeeper accepts it. If Apple rejects it, the script prints Apple's log.

### 4. Let GitHub Actions do it for releases

Pushing a `vX.Y.Z` tag signs and notarizes the release build in CI. It needs these repository secrets
(**Settings ▸ Secrets and variables ▸ Actions**, or `gh secret set`):

| Secret | Value |
|---|---|
| `DEVELOPER_ID_CERTIFICATE_P12` | the certificate and its private key, as a base64-encoded .p12 |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | the .p12's password |
| `NOTARY_API_KEY` | the contents of the `.p8` file (also used for TestFlight uploads) |
| `NOTARY_API_KEY_ID` | the key's Key ID |
| `NOTARY_API_ISSUER_ID` | the Issuer ID |

`scripts/set-signing-secret.sh` sets the certificate's two: it exports only that identity from your login keychain
(macOS asks for your login password), protects it with a random password, checks that it imports the way CI imports
it, and stores both secrets with `gh`. Then the API key's three:

```bash
scripts/set-signing-secret.sh "Developer ID Application" DEVELOPER_ID_CERTIFICATE
gh secret set NOTARY_API_KEY < ~/path/to/AuthKey_XXXXXXXXXX.p8
gh secret set NOTARY_API_KEY_ID --body XXXXXXXXXX
gh secret set NOTARY_API_ISSUER_ID --body xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```

A Developer ID certificate lasts five years; after renewing it, run the script again.

A tagged build fails rather than publishing an unsigned release when a secret is missing. Pull requests and pushes to
`main` still build an ad-hoc-signed app (with the tools).

Users of an earlier, ad-hoc-signed release are asked once to allow keychain access after updating (**Always Allow**);
later Developer ID releases keep that access.

## iPhone app: TestFlight

The iPhone app, its widgets and the Apple Watch app upload together. `iOS/Local.xcconfig` holds your team
(`DEVELOPMENT_TEAM`); the bundle identifier is `APP_BUNDLE_ID` in `iOS/Signing.xcconfig`
(`io.github.davidlago.MusicLibraryMobile`), and the version is `MARKETING_VERSION` in `iOS/Version.xcconfig`.

### 1. Register the app

Make a signed archive without uploading. With automatic signing, Xcode registers the four bundle identifiers (the app,
`.Widgets`, `.watchkitapp` and `.watchkitapp.Widgets`) and the app group with your team, and creates an Apple
Distribution certificate:

```bash
UPLOAD=0 scripts/testflight.sh
```

### 2. Create the app in App Store Connect

[App Store Connect](https://appstoreconnect.apple.com) ▸ **Apps** ▸ **+** ▸ **New App**: platform **iOS**, a name (it
must be unique on the App Store; you can change it until the first release), the primary language, the bundle ID
registered above, and any SKU (for example `music-library-ios`).

### 3. Upload a build

```bash
scripts/testflight.sh
```

It archives, signs for distribution and uploads, with the current UTC time as the build number (`BUILD=…` to choose
one). It signs in with the account in **Xcode ▸ Settings ▸ Accounts**, or with an API key:
`ASC_KEY=~/path/to/AuthKey_XXXXXXXXXX.p8 ASC_KEY_ID=… ASC_ISSUER=…`. The build appears under **TestFlight** after Apple
processes it (usually 5 to 30 minutes; you get an email).

The Info.plists declare `ITSAppUsesNonExemptEncryption = NO`: the app only uses the encryption built into iOS (TLS for
Wi-Fi sync and HTTPS), which is exempt from export documentation, so App Store Connect doesn't ask about it on every
build. The privacy manifests (`PrivacyInfo.xcprivacy` in the app and the watch app) list the "required reason" APIs the
code uses.

### 4. Install it

- **Yourself and your team (no review):** in **TestFlight** ▸ **Internal Testing**, create a group and add yourself
  (anyone with a role in your App Store Connect team, up to 100 people). Install
  [TestFlight](https://apps.apple.com/app/testflight/id899247664) on the iPhone, open the invitation email, and install.
  It replaces an app installed from Xcode with the same bundle ID.
- **Others:** **External Testing** groups (up to 10,000 people, by email or a public link) need Beta App Review for the
  first build of each version. Fill in **Test Information** (what to test, a feedback email) and, in the review notes,
  explain that the app gets its music from the Mac app (with a link to the Releases page) and how to sync, since a
  reviewer opening it without a Mac sees an empty library.

TestFlight builds expire after 90 days; upload a new one before then. Internal groups get every new build when their
**Automatic Distribution** setting is on; testers' TestFlight app then notifies them, or installs it by itself when they
turn on automatic updates in TestFlight.

### 5. Upload every release from CI

Each `vX.Y.Z` tag also uploads the iPhone app as version X.Y.Z (the `testflight` job, after the build and tests pass;
`MARKETING_VERSION` in `iOS/Version.xcconfig` only matters for local builds). It uses the notarization API key, which
uploads. An App Manager key can't use Apple's cloud-managed distribution certificates, so CI signs manually with an
Apple Distribution certificate of its own, from two more secrets, and an App Store profile per bundle ID named
"<bundle ID> App Store (CI)", which `scripts/provisioning-profiles.swift` creates (or replaces, once expired or made for
another certificate) with the API key:

1. Create it in Xcode: **Settings ▸ Accounts**, your team, **Manage Certificates…**, **+** ▸ **Apple Distribution**.
2. Store it:

   ```bash
   scripts/set-signing-secret.sh "Apple Distribution" APPLE_DISTRIBUTION_CERTIFICATE
   ```

The certificate lasts a year: when Apple emails that it's expiring, create a new one and run the script again.

To check it without a release, run the CI workflow by hand (**Actions ▸ CI ▸ Run workflow**, or
`gh workflow run ci.yml -f testflight=export`): `export` signs an .ipa without uploading, `upload` uploads it.

## The App Store

The iPhone app is on the App Store as **Dave's Music Library**. The listing (name, description, keywords, URLs, the
App Privacy and age rating answers and the review notes) is in [docs/app-store](app-store/README.md), with the
screenshots.

App Review can't pair with a Mac, so the app has a sample library: **Explore a Sample Library** on the empty Library tab
opens fictional albums built into the app (`iOS/MusicLibraryMobile/SampleLibrary.bundle`, made by
`scripts/make-sample-library.sh`). The review notes point the reviewer at it.

### One-time setup

In App Store Connect:

1. **Business**: accept the Free Apps agreement (the Paid Apps one only if the app is ever sold) and declare the EU
   trader status (not a trader).
2. The app ▸ **App Information**: subtitle, category, content rights, age rating and the privacy policy URL, as listed
   in [docs/app-store](app-store/README.md).
3. **App Privacy**: the data types listed there, then **Publish**.
4. **Pricing and Availability**: Free, all territories.

### Each release

1. Tag the release as usual: CI uploads the build to TestFlight as version X.Y.Z (see above).
2. In App Store Connect, add the version under the iOS app (**+** next to iOS App), fill in **What's New** from the
   changelog, and on the first version also the description, keywords, URLs and screenshots (`docs/app-store/iphone`
   for the 6.9-inch display, `docs/app-store/watch` for Apple Watch).
3. Select the build, fill in **App Review Information** (no sign-in, the notes from docs/app-store, the demo video as
   an attachment on the first submission), and choose when to release it.
4. **Add for Review**, then **Submit for Review**. Review usually takes a day or two; App Store Connect emails the
   outcome.

New screenshots: open the sample library in the iPhone 18 Pro Max simulator (status bar set with
`xcrun simctl status_bar booted override --time 9:41`) and take them with `xcrun simctl io booted screenshot`;
`musiclibrary://album?key=<artist>%01<album>`, `musiclibrary://now-playing` and `musiclibrary://insights?pane=listening`
open those screens directly. The watch's come from the Apple Watch simulator paired with it.
