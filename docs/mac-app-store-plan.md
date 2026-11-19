# Plan: the Mac app on the Mac App Store

A brief for a Claude session in this repository. Goal: publish the Mac app (Music Library, built with SwiftPM by
`scripts/build-app.sh`) on the Mac App Store, with uploads from CI on release tags, and submit its first version
for App Review, with the screen recording described below attached. The iPhone app is already on the App Store as
**Dave's Music Library**; the Mac app is distributed today only as a notarized Developer ID download from GitHub,
which carries on.

The same work was done for Jazz Discovery on 2026-11-19 (`/Users/davidlago/Develop/Jazz Discovery`, PR
davidlago/jazz-discovery#32, `docs/app-store.md` there ▸ "The Mac app on the Mac App Store"). Read that PR's diff
first: most of it carries over, but **Music Library differs in three ways that change the plan** (the next section).
Make the equivalent changes here, adapted, rather than copying files blindly.

## Ground rules (the user's)

- **Ask before anything that changes an account or goes out**: creating certificates, profiles, App IDs or App Store
  Connect records/versions, setting GitHub secrets or variables, uploading builds, and above all submitting for
  review. Explain what you'll do, get a yes, then do it. Reading through the API is fine.
- **Don't touch the user's own running Music Library app.** Test builds of the Mac app use a separate bundle ID and
  never the real one; quit them when done.
- Work on a branch and open a PR; commit or push only when the user asks or approved the step. Releases are tagged
  per this repository's own process (AGENTS.md, CHANGELOG.md); don't tag one without the user.
- Apple's App Store Connect backend sometimes answers 500 and still commits the change: check state before retrying.
- When a step is done or a decision is made, say so plainly, and record the state in this file's **Progress** section
  at the bottom (and in the session's memory), so a later session can pick up.

## How this differs from Jazz Discovery (decide these first, with the user)

### 1. The Mac app isn't sandboxed

The Mac App Store requires the App Sandbox for the app and every executable in it. Music Library's only Mac
entitlement today is `com.apple.security.device.audio-input` (`Resources/MusicLibrary.entitlements`); Jazz Discovery
was already sandboxed. This is the big piece of work and may cost features, so **start with an audit and a proposal,
not code**. Go through everything the Mac app does outside its container, for example:

- **The library folder and music files anywhere on disk**, external drives, imports, exports (the Export List),
  downloads, cover art and artist photos written next to files. In the sandbox these need a user-selected folder
  (`com.apple.security.files.user-selected.read-write`) kept with **security-scoped bookmarks** across launches, and
  `startAccessingSecurityScopedResource()` around every use. Check every `NSOpenPanel`, every stored path, and the
  defaults that hold paths.
- **The bundled helpers** `ffmpeg`, `ffprobe` and `fpcalc` in `Contents/Helpers` (`scripts/build-tools.sh`,
  `Tools.swift`): each must be signed with `com.apple.security.app-sandbox` and `com.apple.security.inherit` (and
  nothing else) so they run inside the app's sandbox, and they can only touch files the app can. FFmpeg is built as
  LGPL (good: no GPL in the store); keep its license files in the bundle.
- **CD ripping and importing** (`CDRipper`, `CDImporter`, `AccurateRipAudio.swift`), **vinyl digitizing**
  (`VinylImporter`, audio input: keep the entitlement and `NSMicrophoneUsageDescription`), **CoreAudio output and
  input switching** (`CoreAudioOutput.swift`, `CoreAudioInput.swift`). Find out how each reads its device; anything
  that opens raw disk devices won't work sandboxed.
- **Network**: web services (`com.apple.security.network.client`) and **syncing with the iPhone over the local
  network** (`SyncTransport.swift`, `SyncProtocol.swift`): a listener needs `com.apple.security.network.server`, plus
  `NSLocalNetworkUsageDescription` and Bonjour service types if it advertises.
- **iCloud** (the `iCloud.io.github.davidlago.MusicLibrary` container, `docs/icloud-plan.md`), the keychain, other
  apps (Apple Events or Music.app), any `Process` launches beyond the helpers, and any built-in update check (the
  store forbids self-updating).

Then propose to the user, feature by feature, what works sandboxed, what needs changes, and what can't work. Let them
choose between sandboxing every build (simplest: one app, and the GitHub build gets the same protections) and a
store-only sandboxed variant with some features turned off. Implement what they choose, then test a sandboxed build
end to end (a separate-bundle-ID test copy, ad-hoc signed, with the sandbox entitlements) before any store work.

### 2. The Mac and iPhone apps have different bundle IDs

Jazz Discovery's Mac and iPhone apps share one bundle ID, so the Mac app became a second platform (macOS) on the
existing App Store record: one product page, universal purchase, shared App Information and privacy label. Here the
Mac app is `io.github.davidlago.MusicLibrary` (the iCloud App ID, a macOS App ID, `docs/distribution.md` ▸ iCloud;
builds without a profile are `local.musiclibrary`) and the iPhone app is `io.github.davidlago.MusicLibraryMobile`.
A platform added to an existing record must use the record's bundle ID, so the choices are:

- **A separate App Store Connect record for the Mac app** with bundle ID `io.github.davidlago.MusicLibrary`
  (recommended). It needs its own name (unique on the store: "Dave's Music Library" is taken by the iPhone record;
  for example "Dave's Music Library for Mac"), SKU, App Information, App Privacy label, age rating, pricing and
  availability, copied from `docs/app-store/README.md`. **Records can't be created through the API**: the user makes
  it on the website (App Store Connect ▸ Apps ▸ **+** ▸ New App ▸ macOS), or you do it in their browser with their
  go-ahead. After that, everything else can go through the API.
- Moving the Mac app to the iPhone's bundle ID for universal purchase. Much more disruptive (iCloud container
  assignment, user defaults and keychain move again, existing users' settings), so only if the user wants it.

### 3. The Mac app is built by SwiftPM, not Xcode

Jazz Discovery's `scripts/mac-app-store.sh` archives with `xcodebuild archive` and exports and uploads with
`xcodebuild -exportArchive` (method `app-store-connect`). Here there's no Xcode project for the Mac, so the store
build is put together by hand:

1. Build with `scripts/build-app.sh` (`UNIVERSAL=1`), signed with the **Apple Distribution** identity, embedding a
   **Mac App Store** provisioning profile for `io.github.davidlago.MusicLibrary`, with the sandbox entitlements (and
   iCloud's), and the helpers signed as above. `build-app.sh` today only accepts Developer ID profiles
   (`PROVISIONING_PROFILE`); extend it, as Jazz Discovery's `build-app.sh` checks profiles, to accept a
   `MAC_APP_STORE` profile, and don't add `--timestamp` requirements that only notarization needs.
2. Package: `productbuild --component "build/MusicLibrary.app" /Applications --sign "3rd Party Mac Developer
   Installer: David Lago (2M74C6J5ZY)" "build/MusicLibrary.pkg"`.
3. Check: `pkgutil --check-signature`, then expand it (`pkgutil --expand-full`) and check the app's signature,
   entitlements (`codesign -d --entitlements - --xml`), embedded profile, architectures, Info.plist and every helper's
   signature, as was done for Jazz Discovery.
4. Upload with the API key: `xcrun altool --upload-package build/MusicLibrary.pkg --type macos --apiKey <key ID>
   --apiIssuer <issuer ID>` (altool finds the key in `~/.appstoreconnect/private_keys`; if this altool wants
   `--apple-id`/`--bundle-id`/`--bundle-version`/`--bundle-short-version-string`, give them: the Apple ID is the new
   record's), or `xcrun altool --upload-app -f … -t macos`. Put all of it in a script like Jazz Discovery's
   `scripts/mac-app-store.sh` (`UPLOAD=0` to only build and check the .pkg; build number = UTC time `%Y%m%d%H%M`).

## What carries over from Jazz Discovery (adapt each)

| Jazz Discovery (read these) | Here |
|---|---|
| `scripts/provisioning-profiles.swift --mac-app-store` (profile type `MAC_APP_STORE`, "<bundle ID> Mac App Store (CI)", for the Apple Distribution certificate) | This repo has its own `scripts/provisioning-profiles.swift`; add the same mode |
| `scripts/mac-installer-certificate.sh` + `scripts/installer-certificate.swift` | **Don't make another certificate**: the team's Mac Installer Distribution certificate ("3rd Party Mac Developer Installer: David Lago (2M74C6J5ZY)", expires 2027-11-19) was made on 2026-11-19 and is in the login keychain. Store it as this repo's `MAC_INSTALLER_CERTIFICATE_P12`/`_PASSWORD` secrets by exporting it from the keychain: this repo's `scripts/set-signing-secret.sh` looks identities up with `-p codesigning`, which doesn't list installer identities, so make it search without that policy for an "Installer" prefix (macOS asks the user for their login password). Copy the two scripts too, for the yearly renewal. |
| `scripts/import-certificate.sh`: a second run adds to the same CI keychain (password kept in `$RUNNER_TEMP/signing.keychain-password`), installer identities are found without `-p codesigning`, `-T /usr/bin/productbuild` | Same change here |
| CI job `mac-app-store` (on `v*` tags when the repository variable `MAC_APP_STORE` is `1`; by hand with a `mac_app_store: none/export/upload` input; imports both certificates; removes the keychain and its password file afterwards) | Same, running the new script; needs the build job's tools (`build-tools.sh`) |
| `ITSAppUsesNonExemptEncryption = false` in the Mac Info.plist | `build-app.sh` writes the Info.plist: add it there (check the app uses only HTTPS and hashing) |
| A privacy manifest (`PrivacyInfo.xcprivacy`) in the Mac app, like the iPhone app's | Add one in `Contents/Resources`, declaring the required-reason APIs the Mac code uses (UserDefaults at least; check file timestamps, disk space, system boot time) |
| `Keychain` in `Shared/Services/LastFM.swift`: on the Mac, items go in the **data protection keychain** (`kSecUseDataProtectionKeychain`), where they belong to the App ID, so every signed copy (App Store, TestFlight, Developer ID with profile) reads them without asking; items from the login keychain are moved the first time they're read; builds without an App ID keep using the login keychain. **The probe**: a delete of a never-saved item answers `errSecMissingEntitlement` without an App ID (a read only says "not found"). | `Sources/MusicLibraryCore/KeychainStore` keeps every secret in ONE JSON item (service `local.musiclibrary`). Same change: read from the data protection keychain first, move the old item over once, keep the login keychain for unentitled builds. The TestFlight copy of Jazz Discovery asked three times for items the GitHub copy had saved; this avoids that. Test the fallback with an ad-hoc tool as was done there; the move itself can only be tested in a TestFlight build. |
| `docs/app-store.md` ▸ "The Mac app on the Mac App Store" (one-time setup, each release, Mac listing text and review notes) | Add the same to `docs/distribution.md` ▸ The App Store and `docs/app-store/README.md` |
| Screenshots `docs/app-store/mac/*.png`: 2880 × 1800, the real window captured and framed with a kicker and headline (`scripts/app-store-art.swift`'s `MacFrame`) | Same; see Screenshots below |
| CHANGELOG entries under Unreleased; README's script list | Same |

## Screenshots

The Mac App Store takes 16:10 screenshots (1280 × 800, 1440 × 900, 2560 × 1600 or 2880 × 1800), up to ten.

- Capture the **real window** of a running test build, not an offscreen render (in Jazz Discovery the offscreen
  snapshot mode drew the sidebar blank and the glass player bar wrongly). A window of 1440 × 900 points on this Mac's
  Retina display captures at exactly 2880 × 1800: `screencapture -l <window ID> -o -x out.png`. Get the window ID
  with `CGWindowListCopyWindowInfo` (a small Swift tool filtering on the app's PID). Osascript has no accessibility
  permission here, so open pages with the app's own links (`musiclibrary://…`) and size the window with the app's
  saved frame or by hand.
- Bring the test copy to the front for capture (in the background it may not draw its window); tell the user a test
  window will appear.
- Content: ask the user whether to show their own library (as in the recording) or the sample library. If the Mac app
  has no sample library yet, App Review needs one too (see Review notes).
- Frame them with the same headline style as the iPhone set (`scripts/compose-iphone-screenshots.swift` here), at
  2880 × 1800, no alpha.

## Listing text and review notes

Start from `docs/app-store/README.md` (the iPhone listing) and write the Mac version: the Mac's own features in
place of the phone's (the library, CD ripping, vinyl digitizing, the Shop and price guide, the Shelf, syncing to the
iPhone, whatever survives the sandbox), its own keywords if they should differ, and Mac review notes.

**App Review can't use the user's library or pair an iPhone**, so the Mac app must show something without one: the
iPhone app opens a built-in sample library ("Explore a Sample Library", `scripts/make-sample-library.sh`); give the
Mac app the same if it doesn't have it, and point the review notes at it. Say which features need hardware (a CD
drive, a turntable via audio input, an iPhone on the same network) and what the reviewer sees without it.

## The review recording

The user recorded the Mac app for App Review. It's on their Desktop:
`~/Desktop/Screen Recording 2026-11-19 at 11.02.10 AM.mov`. The space before "AM" is a narrow no-break space, so
match it with a glob: `ls ~/Desktop/Screen\ Recording\ 2026-11-19\ at\ 11.02.10*.mov`. It's 71 seconds, 3692 × 2440,
147 MB, no sound. (The other recording there, 10.54.27, is Jazz Discovery's: not this one.) Look at it first (for
example a contact sheet: `ffmpeg -i "$F" -vf "fps=9/71,scale=640:-1,tile=3x3" -frames:v 1 sheet.png`). From frames
taken on 2026-11-19 it shows, in the user's own library: the Shelf (the collection as covers), a CD's album page (All
That You Can't Leave Behind) with a track playing, its "What It's Worth" price and its copy details, a vinyl record
To Digitize (I Sing the Body Electric), Local Library CDs, the Shop looking up a record's price guide and copies for
sale, and the iPhone sync page.

1. Shrink it: `ffmpeg -i "$F" -vf "scale=1920:-2" -c:v libx264 -crf 22 -preset slow -pix_fmt yuv420p -an -movflags +faststart music-library-mac-review.mp4`
   (Jazz Discovery's 36-second one came to 8.8 MB).
2. Attach it to the Mac version's App Review Information through the API (no 10 MB browser limit):
   `POST /v1/appStoreReviewAttachments` (`fileName`, `fileSize`, relationship `appStoreReviewDetail`), PUT each of
   the returned `uploadOperations`, then `PATCH` it with `uploaded: true` and `sourceFileChecksum` (MD5 hex). Check
   its `assetDeliveryState` is `COMPLETE`.
3. Add a sentence to the Mac review notes saying what the video shows (and that it's the developer's own library).

## Doing it through the App Store Connect API

The team's App Manager key does nearly everything (not creating app records): the key file is
`~/.appstoreconnect/private_keys/AuthKey_VXMBNCDJ79.p8` (key ID `VXMBNCDJ79`), the issuer ID is the UUID in
`~/.appstoreconnect/private_keys/apple_developer.txt`. Sign an ES256 JWT (`aud: appstoreconnect-v1`, 20 minutes;
`scripts/provisioning-profiles.swift` here has the code). Never print the key or issuer. Endpoints used for Jazz
Discovery:

- `POST /v1/appStoreVersions` (`platform: MAC_OS`, `versionString`, `copyright`, `releaseType: AFTER_APPROVAL`,
  relationship `app`) makes the macOS version; it copies the other localization fields where the record has them.
- `PATCH /v1/appStoreVersionLocalizations/<id>` for description, keywords, promotional text, support/marketing URLs.
- `GET /v1/appStoreVersions/<id>/appStoreReviewDetail`, then `PATCH /v1/appStoreReviewDetails/<id>` for notes and
  contact (copy the contact from the iPhone version's review detail), `demoAccountRequired: false`.
- Screenshots: `POST /v1/appScreenshotSets` (`screenshotDisplayType: APP_DESKTOP`, relationship
  `appStoreVersionLocalization`), then per file `POST /v1/appScreenshots` → PUT the `uploadOperations` → `PATCH`
  `uploaded: true` + MD5. They appear in creation order; check each `assetDeliveryState`.
- Builds: `GET /v1/builds?filter[app]=<app id>&filter[version]=<build number>` until `processingState` is `VALID`,
  then `PATCH /v1/appStoreVersions/<id>/relationships/build`.
- Submitting (only with the user's go-ahead): `POST /v1/reviewSubmissions` (`platform: MAC_OS`, relationship `app`),
  `POST /v1/reviewSubmissionItems` (relationships `reviewSubmission` and `appStoreVersion`), then `PATCH
  /v1/reviewSubmissions/<id>` with `submitted: true`. To pull one back: `PATCH` it with `canceled: true`.

## Order of work

1. Read Jazz Discovery's PR #32 and this file; check this repo's state (branch, open PRs, AGENTS.md's rules).
2. **Sandbox audit → proposal → user's decision** (section 1). **Record decision → user's decision** (section 2).
3. Implement the sandbox (and a Mac sample library if needed); test a sandboxed test copy end to end.
4. Keychain change, privacy manifest, `ITSAppUsesNonExemptEncryption`.
5. Store build script (section 3), profile mode, certificate import changes, CI job; docs and CHANGELOG. Open a PR.
6. With the user's go-ahead: the installer certificate's secrets in this repo, the Mac App Store profile, the new
   App Store Connect record (user on the website) or platform, a local `UPLOAD=0` .pkg checked inside out.
7. With the go-ahead: upload a build; the user tests it with TestFlight on the Mac (their Developer ID copy should be
   quit and moved out of /Applications first if it has the same bundle ID; check keychain prompts and that settings
   and the library folder come across).
8. Fill in the version: description, keywords, URLs, copyright, screenshots, review notes, **the recording**, the
   build. Then ask the user, and only on their yes, submit for review.
9. After the PR merges: `gh variable set MAC_APP_STORE --body 1` (with the go-ahead) so release tags upload the Mac
   app too.

## Progress

(Update as you go: date, what's done, decisions, IDs of what was made on the accounts.)

- 2026-11-19: this plan written from the Jazz Discovery session. Nothing done in this repository yet.
- 2026-11-19 (session 2): read the plan, looked at the recording (matches the description: Shelf, All That You Can't
  Leave Behind, I Sing the Body Electric, Local Library CDs, the Shop's price guide, iPhone sync; 70.9 s, 3692 × 2440,
  h264). First sandbox audit: the default library `~/Music/MusicLibrary` is covered by
  `com.apple.security.assets.music.read-write`; the library root (`Keys.root`) and export destination
  (`Keys.exportDestination`) are stored as plain paths in user defaults (need security-scoped bookmarks elsewhere);
  CD ripping/AccurateRip read `/Volumes/<disc>` (AIFF files, `.TOC.plist`) and eject with `unmountAndEjectDevice`;
  `ToolLocator` falls back to Homebrew (store build: bundled tools only); `DefaultsImport` reads another app's defaults
  domain (not possible sandboxed); Application Support/Caches data would move into the container. No Mac sample
  library yet.
  **Decisions (the user's):** sandbox **the store build only** (the GitHub/Developer ID build stays unsandboxed);
  inserted CDs get access **by asking once per disc** (an open panel pointed at the disc; no temporary exception);
  a **separate App Store Connect record** for the Mac app (bundle `io.github.davidlago.MusicLibrary`), which the user
  creates on the website.
  Side task done: iPhone 1.36.2 (build 202611111821) submitted for review through the API, Waiting for Review
  (version 9e15e7f7-5e0a-4f4d-8d07-e600ed23ff8b, review submission 20a18854-42e7-401c-8400-80c3f4f36b44).
  Work is on branch `mac-app-store`.
- 2026-11-19: the user created the Mac record on the website: **Dave’s Music Library for Mac**, Apple ID / app ID
  `6836856394`, SKU `music-library-macos`, bundle `io.github.davidlago.MusicLibrary`, primary locale en-US. It came
  with a macOS version `1.0` (`34c409c6-d471-4083-9e7b-8ba15340fe9a`, Prepare for Submission); rename it to the
  release's version before submitting. App Information, privacy label, age rating, pricing are still to fill in.
- 2026-11-19 (later): **implemented on branch `mac-app-store` (uncommitted)**: `AppSandbox`/`FolderBookmarks`
  (`Sandbox.swift`), per-disc CD access (`CDController.lockedDiscs`/`allowAccess`), bundled-tools-only and no defaults
  import when sandboxed, the Mac sample library (`SampleLibraryCopy`, File ▸ Explore a Sample Library, Listen Now's
  empty state; sync/backup/offload off while it's open), `KeychainStore` on the data protection keychain when the build
  has an App ID, `Resources/PrivacyInfo.xcprivacy`, `ITSAppUsesNonExemptEncryption`, `build-app.sh` `SANDBOX=1`/
  `BUNDLE_ID=`/Mac App Store profiles, `scripts/mac-app-store.sh`, `provisioning-profiles.swift --mac-app-store`, the
  installer certificate scripts (copied from Jazz Discovery), `import-certificate.sh`/`set-signing-secret.sh` for
  installer identities, the CI `mac-app-store` job, docs (distribution.md, app-store/README.md with the Mac listing and
  review notes, guide, CHANGELOG, AGENTS.md), `MacAppStoreTests`. `swift test`: 816 tests pass.
  **Tested in a sandboxed ad-hoc copy** (`local.musiclibrary.sandboxtest`): launch, the sample library, playback,
  importing a file chosen in the open panel (ffprobe and ffmpeg ran in the sandbox), a bookmarked Export List folder
  reopened after a relaunch and exported into. **Not tested yet**: a real CD (no disc in the drive), vinyl input, iPhone
  sync, iCloud and the keychain move (need a signed TestFlight build).
  Review video shrunk to `build/app-store/music-library-mac-review.mp4` (8.1 MB, 1920 × 1268, 71 s).
- 2026-11-19 (later, with the user's go-ahead for each): PR davidlago/music-library#82 opened. **Mac App Store
  profile** "io.github.davidlago.MusicLibrary Mac App Store (CI)" made through the API (expires 2027-10-12). Local
  `.pkg` built and checked; the first upload was refused (fpcalc's embedded bundle ID `org.acoustid.fpcalc` must be
  its signing identifier; fixed in build-app.sh), then **uploaded 1.36.2 (202611191647)**, delivery
  ad58850f-d75d-4469-bef3-dd0931aae317. **Mac record filled in through the API**: content rights (third-party), category
  Music, age rating (the iPhone's answers), privacy policy URL, subtitle; version 34c409c6 (still named **1.0**):
  description, keywords, promotional text, URLs, copyright, release after approval; review details 5dec096e (contact
  copied from the iPhone's, notes from docs/app-store) with the **review video attached** (cf316250, COMPLETE);
  **7 screenshots** (set e6d1cb57, APP_DESKTOP, all COMPLETE) from the sample library, committed in
  `docs/app-store/mac`. **Still to do**: the App Privacy label (website only: copy the iPhone's), pricing and
  availability (free, all territories), the user's TestFlight test on this Mac, renaming the version to the submitted
  build's, attaching the build, storing MAC_INSTALLER_CERTIFICATE secrets, merging, `MAC_APP_STORE=1`, submitting.
- 2026-11-19 (evening): the 202611191647 upload failed Apple's processing (90546, no asset catalog): build-app.sh now
  compiles `Assets.car` with the icon (actool, Xcode only). **Build 1.36.2 (202611191659) is VALID and in internal
  TestFlight testing** (build 11c19df2-b58b-46ca-8783-0ce42c7f59a3). Internal group "Music Library Testers"
  (165cfa63-832c-49da-8f11-633f575e58d3, all builds) made on the Mac record with the user in it (invited). Next: the
  user's TestFlight test (move the GitHub copy out of /Applications first; back up its preferences plist).
- 2026-11-19 (user's TestFlight test): **settings didn't come across** (dark mode, the Discogs token, the eBay
  sign-in) and iCloud backup stopped with "moved to David's MacBook Pro". Cause: the sandboxed copy has its own user
  defaults (in its container) and can't read the GitHub copy's: the Mac's sync/backup ID (`SyncStore` `Keys.macID`)
  is a new one, so `backup.json`'s ID looks like another Mac's. Secrets are in the GitHub copy's login keychain item,
  which a sandboxed app can't read; eBay's cookies are in the GitHub copy's web data. The backup check throws before
  writing anything, so nothing in iCloud changed. **To fix before submitting**: carry the settings (above all
  `macID`) and secrets over to the store build on its first launch.
