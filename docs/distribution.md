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
| `DEVELOPER_ID_CERTIFICATE_P12` | the certificate and its private key, exported as .p12 and base64-encoded |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | the password you gave the .p12 |
| `NOTARY_API_KEY` | the contents of the `.p8` file |
| `NOTARY_API_KEY_ID` | the key's Key ID |
| `NOTARY_API_ISSUER_ID` | the Issuer ID |

To export the certificate, open **Keychain Access**, find **Developer ID Application: …** under **My Certificates**,
right-click it, choose **Export…**, save it as a .p12 and set a password. Then:

```bash
base64 -i DeveloperID.p12 | gh secret set DEVELOPER_ID_CERTIFICATE_P12
gh secret set DEVELOPER_ID_CERTIFICATE_PASSWORD
gh secret set NOTARY_API_KEY < ~/path/to/AuthKey_XXXXXXXXXX.p8
gh secret set NOTARY_API_KEY_ID --body XXXXXXXXXX
gh secret set NOTARY_API_ISSUER_ID --body xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
rm DeveloperID.p12
```

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

TestFlight builds expire after 90 days; upload a new one before then. When the Mac app's version changes, update
`MARKETING_VERSION` in `iOS/Version.xcconfig` too.

### Later: the App Store

Submitting to the App Store adds screenshots, a description, a privacy policy URL, the App Privacy questionnaire
(listening history goes to Last.fm when connected; the area searched goes to Ticketmaster and JamBase) and App Review.
The same caveat about the empty library applies: a sample library or a demo video in the review notes helps.
