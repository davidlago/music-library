# iPhone companion app: plan

An iPhone app that holds a synced copy of part of the library and plays it offline, through a USB DAC at each file's own sample rate. The Mac app stays the only place music is imported, tagged and organized. The phone plays and records listens and likes, and sends those back on the next sync.

## Goals and non-goals

v1 goals:
- Sync a selection (albums, artists, playlists, smart playlists, Liked Songs, or everything) from the Mac over Wi-Fi. Only changes are sent, and a sync that's cut off picks up where it stopped.
- Browse and search offline with the same query language, covers, playlists and Liked Songs.
- Play FLAC, ALAC, AAC, MP3, AIFF and WAV, switching the USB DAC to each file's sample rate. Show the file's format and the DAC's actual rate.
- Scrobble to Last.fm from the phone as you listen (now playing, and plays queued while offline), with the same rules and account as the Mac.
- Record plays and likes on the phone and merge them into the Mac's history on sync, so Insights counts them.

Not in v1: importing or tagging on the phone, the library catalog, concerts, cover/photo editing, Music DNA, Insights, CarPlay, and streaming from the Mac.

## What we can reuse

`MusicLibraryCore` doesn't import AppKit. Only these parts depend on macOS:

| File | macOS-only part | On iOS |
| --- | --- | --- |
| `Tools.swift` | `Process` / `ProcessRunner` (ffmpeg, ffprobe, fpcalc) | excluded |
| `Tags.swift` | `TagReader`/`TagWriter` (run ffprobe/ffmpeg) | excluded; the phone reads tags from the synced database |
| `AcoustID.swift`, `AlbumCover.swift` | fingerprinting, cover embedding | excluded |
| `AudioCD.swift` | ripping (`rip`, `ripAndImport`) | keep `CDTOC` (pure parsing, used by `MusicBrainz.swift`); exclude ripping |
| `Import.swift` | `ImportService` | keep `PlaylistExporter` (used by `LibraryExport`); exclude the importer. `LibraryLocation.defaultRoot` is `Documents/Music Library` on iOS |
| `CoreAudioOutput.swift` | `OutputMatcher` (CoreAudio HAL device properties) | excluded; iOS uses `AVAudioSession` instead |
| `LibraryCatalogParser.swift` | `XMLDocument` (not on iOS) | excluded, along with `CatalogEnricher.details`; the catalog is Mac-only |

Everything else should compile for iOS as is: `Database`/SQLite, `Models`, `Search`/`SearchIndex`, `PlayQueue` (and its `Snapshot`), `ListenTracker`, `LastFM`, `Scrobbler` (moved from the Mac app into Core in phase 1), `Themes`, `ArtistInfo`/`AlbumInfo` parsers, `LibraryPath`, `MusicDNA` (CoreGraphics), `Concerts` (CoreLocation/Contacts), and `Keychain` (it only uses generic-password attributes available on iOS).

Data the phone gets for free from an export-style sync:
- `Music/<Artist>/<Album (Year)>/NN - Title.ext` plus `cover.jpg` per album.
- A `library.sqlite` snapshot (`VACUUM INTO`). It includes tracks (with `codec`, `sample_rate`, `bit_depth` already filled in), playlists, smart playlists, `liked_tracks`, `plays`, `artist_info`/`album_info` and `artist_photos`.
- `Artist Images/`.
- Track `sha256` is `UNIQUE` in `tracks`. That makes it a stable identity to check alongside the track id.

Every extension in `supportedExtensions` (`mp3 flac m4a aac aif aiff wav`) plays on iOS with AVFoundation, so no transcoding is needed.

## Architecture

```
Mac app (MusicLibrary)                        iPhone app (MusicLibraryMobile)
  Sync List (like the Export List)              Library root: Documents/Music Library/
  SyncClient  ──NWBrowser──►  Bonjour  ◄──NWListener──  SyncServer
      │        TLS-PSK, framed messages                    │
      ├─ plan: phone manifest vs selection                 ├─ receives files: .partial, then rename
      ├─ sends files, deletions, DB snapshot               ├─ swaps library.sqlite (opened read-only)
      └─ merges phone events (plays, likes)    ◄─────────  └─ outbox: phone.sqlite (pending events)
                       MusicLibraryCore (shared: models, DB, search, queue, sync protocol)
```

The connection runs from the Mac to the phone. The phone listens only while its Sync screen is open, because iOS suspends background apps. The Mac does all the planning, so the phone side stays simple: it receives files and the database, and sends back its file list and its pending events.

### Storage on the phone

- **Library root:** `Documents/Music Library/`. Inside it go `Music/…`, `library.sqlite`, `Artist Images/` and `Playlists/` (optional .m3u). It's the same layout as an export, so the folder is a valid library on either side.
  - It sits in `Documents` so Finder's Files tab and the Files app can see it, which allows the manual seeding described in phase 2 and recovery.
  - Mark it `isExcludedFromBackup` so tens of GB don't go into iCloud backups.
- **`Application Support/phone.sqlite`:** data the phone owns, which replacing the snapshot never overwrites.
  - `pending_events(id TEXT PRIMARY KEY, kind, track_id, sha256, payload_json, created_at)`: plays and like/unlike, each with a UUID.
  - `sync_state(key, value)`: paired Mac, library id, last sync time.
- **`Application Support/player-state.json`:** a `PlayQueue.Snapshot`, as on the Mac.
- **The snapshot is read-only:** the phone opens `library.sqlite` with `SQLITE_OPEN_READONLY`. Views overlay pending events, so a song liked on the phone shows as liked before the next sync.

### Sync protocol (new `Sync*.swift` in Core, shared by both apps)

- **Discovery:** the Bonjour service is `_musiclib-sync._tcp`, using Network.framework (`NWListener` on the phone, `NWBrowser` on the Mac).
- **Pairing:**
  1. The phone shows a code: 10 characters from a 32-symbol alphabet (about 50 bits), valid for 2 minutes. The user types it on the Mac.
  2. The first connection uses TLS 1.3 with a PSK derived from the code (HKDF), using Network.framework's `sec_protocol_options_add_pre_shared_key`.
  3. Inside that connection, the two sides agree a random 32-byte long-term key.
  4. Later connections use TLS-PSK with that key. On the Mac it goes in the keychain under `KeychainStore.app`'s single `secrets` item (see AGENTS.md, Keychain); on the phone it goes in the phone's keychain.
- **Framing:** each message is a length-prefixed frame (`UInt32` length plus a 1-byte kind). JSON control messages are `Codable`. File data is sent as chunk frames of 1 MiB.
- **Session:**
  1. `hello`: protocol version, device name, the library id (a UUID stored on the Mac; see below), free space and app versions. If the versions are incompatible, the session refuses with a clear message.
  2. Phone to Mac: `manifest` lists every file under the root (path, size) and `events` lists the pending events.
  3. The Mac merges the events (see below) and replies `eventsAck` with the applied ids. The phone then deletes them from its outbox. Because the Mac dedupes by event id, resending is safe.
  4. The Mac plans:
     - Selection to tracks, the same way the Export List resolves items.
     - Diff against the manifest gives files to send, covers to send, artist images to send, and paths to delete.
  5. The Mac sends `delete` (paths), then each file as `fileStart` (path, size, sha256 for tracks) + chunks + `fileEnd`. The phone writes each to a hidden `.partial` and renames it, just like `LibraryExporter.copy`.
  6. The Mac sends the database snapshot last. The phone swaps it in only after every file has arrived, so the database never points at songs that aren't there yet.
  7. `done` carries a summary for both UIs.
- **Path safety:** paths are untrusted on both sides. The phone resolves every path the Mac sends with `LibraryPath.resolve(_, in: root)` before writing or deleting. The Mac does the same for paths in the phone's manifest.
- **Resume:** a sync that's cut off leaves only complete files, and the next manifest shows what arrived. No separate resume state is needed.
- **Snapshot size:** the Mac makes the snapshot with `VACUUM INTO` to a temp file, deletes the `catalog_*` tables from that copy (they're Mac-only and can be large), vacuums it again and sends it.
- **Schema check:** the phone refuses a snapshot whose `user_version` is newer than its own `Database.schemaVersion` and asks you to update the iPhone app.

### Merging phone events on the Mac

- **Plays:** insert into `plays` with the phone's `started_at`, `listened` and `counted`.
  - Dedupe with a new `plays.event_id TEXT UNIQUE` column (schema version 14).
  - Check the track by id **and** sha256. If they don't match (the track was re-imported or deleted), drop the event and count it in the summary.
  - Bump `historyVersion` so Insights refreshes.
- **Likes:** apply like/unlike events in `created_at` order with `Database.setLiked`, using `at:` = the phone's time. The last change wins. For a single user that's correct in practice.
- **Last.fm:** the Mac never scrobbles plays that came from the phone, because the phone already scrobbled them (see below). That way nothing is scrobbled twice.
- **Library id:** add a `library_meta(key, value)` table holding a UUID created once, so a phone paired with one library never mixes in another.

### Playback on iOS (`MobilePlayer` in the iOS app)

This is modeled on the Mac `Player`. It reuses `PlayQueue`, `ListenTracker`, `AudioFormat` and the snapshot save and restore. Only the output side changes:
- **Audio session:** category `.playback`, the `audio` background mode, and `MPNowPlayingInfoCenter` plus `MPRemoteCommandCenter` (lock screen, Control Center, AirPods and DAC buttons).
- **Sample-rate matching** (replaces `OutputMatcher`). When the next track's `sampleRate` differs from the session's:
  1. Pause.
  2. `setPreferredSampleRate(rate)`, then `setActive(true)`.
  3. Read back `session.sampleRate` and start.
  4. Show "FLAC 24/96 → USB DAC · 96 kHz", or "resampled to 48 kHz" when the hardware didn't follow.
  - Confirmed on a HiBy FC4: setting the preferred rate and reactivating the session (only when the rate changes) switches the DAC. `AVAudioSession.sampleRate` keeps reporting the old rate for a moment after the change, so the displayed output is read again after playback starts.
- **Gapless:** use `AVQueuePlayer` for consecutive tracks at the same rate. A rate change needs a short stop, as on the Mac.
- **Bit depth:** iOS doesn't let apps choose bit depth or take exclusive access to the device. "Bit-perfect" here means the right rate, no in-app volume (the player's volume stays at 1.0) and system volume at maximum. The app shows that hint when a USB DAC is connected.
- **Route changes:** pause when the DAC is unplugged (`routeChangeNotification`, `.oldDeviceUnavailable`). Read the DAC's name from `currentRoute.outputs` (port type `.usbAudio`).
- **Plays:** record them with the same `ListenTracker` rules as the Mac, into `pending_events`.

### Last.fm on the phone (v1)

Last.fm has to work in the first version, and syncs may be days apart, so the phone scrobbles on its own instead of handing plays to the Mac. Last.fm ignores scrobbles older than 14 days, so waiting for a sync could lose them.
- **Shared code:** `Scrobbler` is in Core, shared with the Mac app. The phone gets the same `ListenTracker` rules, now playing updates, a persisted `ScrobbleQueue` (in Application Support) with retry and backoff, and the same error handling for an invalid session or bad API key.
- **Wiring:** `MobilePlayer` calls `trackStarted` and `progress` like the Mac `Player` does. Playback in the background keeps the app running (`audio` background mode), so scrobbles go out while the screen is locked.
- **Offline:** plays wait in the queue. The phone flushes it when the app becomes active and when the network comes back (`NWPathMonitor`), as well as on the existing retry timer.
- **Account:**
  - Phase 3: a Last.fm screen in the phone's settings takes the API key and shared secret (paste them with Universal Clipboard), then connects through Last.fm's browser authorization. The page opens in Safari, the app polls `getSession`, and you come back to the app.
  - Phase 4: pairing can also send the Mac's API key, shared secret and session key over the encrypted sync connection ("Use the Mac's Last.fm account"), so nothing needs typing. A Last.fm session key works on more than one device.
  - Secrets go in the phone's keychain through `KeychainStore` (one `secrets` item, as on the Mac).
- **Testing:** `LastFMClient` and `ListenTracker` already have tests. On the device, check that now playing shows on your Last.fm profile, that a play made offline arrives after you reconnect, and that a song played on the phone isn't scrobbled again by the Mac after a sync.

### iPhone UI (v1)

A `TabView` with four tabs:
- **Library:** Artists, Albums, Songs, Playlists (including smart playlists, evaluated with `SearchIndex`), and Liked Songs. Album and artist pages show cover, tracks and format badges. Artist pages show the cached `artist_info` bio and photo, which work offline.
- **Search:** the same query language and completions (`SearchQuery`, `SearchIndex`).
- **Now Playing:** cover, scrubber, like button, the output line described above, and a queue sheet (Play Next / Add to Queue, as on the Mac).
- **Sync:** pairing code, connection state, progress (files and bytes), last sync summary, and storage used and free.
- **Settings** (from the Sync tab): Last.fm account, scrobbling and now playing switches, and pending and recent scrobbles, like the Mac's Last.fm settings.

Themes use `Themes.swift` palettes with an iOS port of `.themedRoot` and the same `.subtext` rule (AGENTS.md).

### Mac UI

- **Sync to iPhone:** a page, or a destination in the Export List, with paired devices, a per-device selection (stored like `exportList`, reusing `ExportItem`), a preview (space needed, new and removed albums, reusing `ExportPreview`'s per-album split) and Sync Now.
- **Mirror the selection:** files no longer in the selection are deleted from the phone. Unlike export, which never deletes, the phone's library folder belongs to the app. The preview shows what will be removed, and the first sync that deletes anything asks for confirmation.
- **Info.plist:** `scripts/build-app.sh` needs `NSLocalNetworkUsageDescription` and `NSBonjourServices`. macOS 15+ asks for local network access, and sync works only from the app bundle, not `swift run`.

## Repo and build changes

- **`Package.swift`:** `platforms: [.macOS(.v14), .iOS("27.0")]`. Wrap the macOS-only parts listed above in `#if os(macOS)`. The `MusicLibrary` executable target stays macOS-only.
- **iOS app:** add an Xcode project at `iOS/MusicLibraryMobile.xcodeproj`, depending on the local package (`..`) for the `MusicLibraryCore` product. SwiftPM can't build an iOS app bundle, so this is the one Xcode project in the repo. The Mac app stays SwiftPM-only.
  - Bundle id e.g. `io.github.davidlago.MusicLibraryMobile`.
  - Info.plist: `UIBackgroundModes: audio`, `NSLocalNetworkUsageDescription`, `NSBonjourServices: [_musiclib-sync._tcp]`, `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace`.
- **CI (`.github/workflows/ci.yml`):** add `xcodebuild -project iOS/MusicLibraryMobile.xcodeproj -scheme MusicLibraryMobile -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`, and a Core build for iOS (`xcodebuild -scheme MusicLibraryCore -destination 'generic/platform=iOS Simulator'`).
- **AGENTS.md:** document the iOS target, the sync protocol, phone storage and the untrusted-path rules for sync.

## Tests (Swift Testing, `swift test` on macOS)

- **Framing:** split and partial frames, oversize frames rejected, unknown kinds rejected.
- **`Codable` round-trips** for every message, and refusal on a protocol version mismatch.
- **Planner:** manifest vs selection gives sends and deletes, including covers and artist images, with unsafe manifest paths (`..`, absolute) rejected.
- **Event merge:**
  - plays inserted once even when sent twice
  - sha256 mismatch dropped
  - like/unlike order
  - phone plays never queued for Last.fm on the Mac
- **Phone receiver:**
  - `.partial` then rename
  - deletes stay inside the root
  - snapshot swapped only after files
  - newer schema refused
- **Read-only `Database` open** (no migrations) on a snapshot.
- **Loopback end-to-end:** `NWListener` on 127.0.0.1 inside the test syncs a generated mini library between two temp folders. This is local only, which keeps the rule that tests don't hit the network.
- **Manual on device:** the DAC rate switching, route changes and background audio.

## Phases

0. **Prerequisites (you):**
   - Install Xcode, then `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`.
   - Sign in with your Apple ID in Xcode (Settings → Accounts).
   - On the iPhone, turn on Developer Mode (Settings → Privacy & Security).
   - With Xcode installed, `Package.swift`'s Command Line Tools test workaround switches off by itself, and the `SDKROOT` note in AGENTS.md no longer applies.
1. **Core builds for iOS** (done): platform guards, an iOS CI build, a read-only `Database` open, and `Scrobbler` moved into Core. No behavior changes on the Mac, and every existing test still passes.
2. **iPhone app skeleton (no sync yet)** (done; tested in the simulator with three albums from the real library):
   - The app reads a library from `Documents/Music Library/`.
   - Seed it by exporting from the Mac (Export List, with the database backup on) and dragging the export into the app in Finder's Files tab.
   - Covers Library, Search and basic playback.
   - At this point you already have a working offline player on the phone.
3. **Playback done right, and Last.fm** (done; the DAC itself still to be checked on the phone): sample-rate switching (spike first), the output display, gapless at the same rate, lock screen controls, the queue sheet, saving and restoring player state, and Last.fm scrobbling with the account entered on the phone.
4. **Wi-Fi sync, Mac to phone** (done, except sending the Mac's Last.fm account, which moves to a later phase; tested with the iPhone simulator and between the Mac app and a real iPhone): pairing (including sending the Mac's Last.fm account), the protocol, the planner, mirror deletes and the Mac sync page. Seeding a big library by dragging in Finder (phase 2) and then syncing changes over Wi-Fi is the recommended path. A first sync over Wi-Fi runs at roughly 20 to 40 MB/s, so it can take hours for hundreds of GB. The phone keeps the screen awake while syncing.
5. **Two-way sync:** plays and likes back to the Mac, `plays.event_id` and the library id.
6. **Later:**
   - artist and album pages with full info
   - Music DNA and Insights on the phone
   - editing playlists on the phone
   - widgets and CarPlay
   - DSD (would need a custom decoder)

## Decisions (confirmed 2026-10-11)

1. **Signing:** free Apple ID (Personal Team) for now. Apps installed from Xcode expire after 7 days and must be reinstalled; the Apple Developer Program ($99/year) can come later.
2. **Minimum iOS:** 27. The app is just for one phone, which runs iOS 27.
3. **Mirror:** the phone mirrors the sync selection; files no longer selected are deleted (with confirmation the first time).
4. **Phone storage:** `Documents/Music Library/`, visible in Finder and Files for seeding and recovery.
