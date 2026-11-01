# Building from source

Music Library is open source (MIT) and has no third-party dependencies. The Mac app is a Swift package; the iPhone app,
its widgets and the Apple Watch app are an Xcode project that shares the package's core.

## The Mac app

You need macOS 14 or later, Swift 6 (Xcode 16 or later, or just the Command Line Tools), ffmpeg (`brew install ffmpeg`,
for the tests and `swift run`) and cmake (`brew install cmake`, to build the copy of ffmpeg that goes inside the app).

```bash
git clone https://github.com/davidlago/music-library.git
cd music-library
scripts/build-app.sh            # builds build/MusicLibrary.app
open build/MusicLibrary.app
swift test                      # runs the test suite (needs ffmpeg)
```

`scripts/build-app.sh` builds FFmpeg and Chromaprint from source the first time (`scripts/build-tools.sh`, about a
minute) and puts ffmpeg, ffprobe and fpcalc inside the app. It also accepts:

| Option | Does |
|---|---|
| `BUNDLE_TOOLS=0` | Leaves the tools out; the app then uses Homebrew's |
| `VERSION=1.2.3`, `BUILD=…` | Sets the version |
| `UNIVERSAL=1` | Apple silicon and Intel (needs Xcode) |
| `SIGN_IDENTITY=…` | Signs with a certificate and the hardened runtime; one with a Team ID keeps keychain access across rebuilds |

With only the Command Line Tools installed, see [AGENTS.md](../../AGENTS.md) for a note on the SDK.

## The iPhone app

The App Store has it, but you can run your own build. You need a Mac with Xcode 27 or later, an iPhone on iOS 26 or
later with a USB cable, and an Apple ID (a free one works).

1. On the iPhone, turn on **Settings ▸ Privacy & Security ▸ Developer Mode** (the phone restarts), then connect it to the
   Mac and tap **Trust**.
2. Open `iOS/MusicLibraryMobile.xcodeproj` in Xcode. Sign in with your Apple ID in **Xcode ▸ Settings ▸ Accounts** if
   you haven't.
3. Set your team: select the **MusicLibraryMobile** target, open **Signing & Capabilities** and pick your team (with a
   free Apple ID, "Your Name (Personal Team)"). To keep the project file unchanged, put it in `iOS/Local.xcconfig`
   instead, which isn't committed:

   ```
   DEVELOPMENT_TEAM = ABCDE12345
   APP_BUNDLE_ID = com.yourname.MusicLibraryMobile
   ```

   A bundle identifier can belong to only one developer, so if Xcode says it isn't available, choose your own as above.
   The widgets, the Apple Watch app and the app group they share are named after it.
4. Pick your iPhone as the run destination and click **Run** (⌘R).
5. The first time, iOS won't open an app from an unknown developer: on the phone, open **Settings ▸ General ▸ VPN &
   Device Management**, tap your Apple ID under Developer App and tap **Trust**.

To try it in the iOS Simulator instead:

```bash
xcodebuild -project iOS/MusicLibraryMobile.xcodeproj -scheme MusicLibraryMobile -destination 'generic/platform=iOS Simulator' CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build
```

### Every 7 days (free Apple ID)

Apps installed with a free Apple ID stop opening after 7 days. Connect the phone and click **Run** in Xcode again: the
new build installs over the old one and keeps your music, library, Last.fm account and queue. Don't delete the app from
the home screen, which deletes its music too. A paid Apple Developer Program membership makes installs last a year.

### iCloud

Builds you make yourself leave out [iCloud backup](icloud.md): iCloud needs a registered App ID with an iCloud container,
which a free Apple ID can't have. With a paid membership, register one (`docs/distribution.md` ▸ iCloud has the steps),
then build the Mac app with `PROVISIONING_PROFILE=…` and `SIGN_IDENTITY=…`, and the iPhone app with
`APP_ENTITLEMENTS = MusicLibraryMobile.entitlements` in `iOS/Local.xcconfig`.

## Releases

Releases are built by GitHub Actions: pushing a tag like `v1.2.3` runs the tests, builds a universal app, signs it with a
Developer ID certificate, has Apple notarize it and publishes it on the
[Releases page](https://github.com/davidlago/music-library/releases), and uploads the iPhone app to TestFlight.
[docs/distribution.md](../distribution.md) has the one-time setup.

## Contributing

[AGENTS.md](../../AGENTS.md) describes the architecture, conventions and commands in detail. Tests use Swift Testing
(`swift test`); network tests only run with `MUSICLIB_LIVE_TESTS=1`. Add user-visible changes to
[CHANGELOG.md](../../CHANGELOG.md) under **Unreleased** in the same pull request.
