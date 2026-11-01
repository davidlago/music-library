# iCloud backup and iPhone downloads: plan

Status: **P0 done** (signing groundwork, §8; the portal is set up and a local build signed with the Developer ID
profile reached the container on 2026-10-31), **P1 done** (the Mac backs up the library and covers, §5), P2–P7 to do. Nothing here bumps
`Database.schemaVersion` (14) or `SyncProtocol.version` (3): older phones and Macs keep reading every library and
snapshot this produces.

## 1. Goals and non-goals

Goals:

1. **Back up the whole library to iCloud.** That means the database (tracks, plays, likes, playlists, the physical
   collection, Discogs links, rip checks), album and collection covers, artist photos and, optionally, the music
   files. A mistaken deletion or a broken disk can be undone from it.
2. **Let the phone get music without the Mac nearby.** The phone reads the newest library from iCloud, and Download
   on a song, album or collection item fetches its files from iCloud instead of waiting for the next Wi-Fi sync.
3. **Get the phone's plays and likes to the Mac without Wi-Fi sync**, along with its Download / Remove requests.
4. **Keep everything that works today.** Wi-Fi sync stays: it's faster for the first few hundred GB and works
   without iCloud. Builds without iCloud (ad-hoc, `swift run`, Personal Team phones) work as they do now, with the
   feature hidden.

Non-goals (for now):

- Editing the collection on the phone. The Mac stays the only writer of the library.
- More than one Mac writing to the same backup.
- Streaming songs from iCloud without downloading them.
- Sharing a library with another Apple Account.

## 2. Decisions

| # | Question | Decision | Why |
|---|---|---|---|
| D1 | iCloud Drive or CloudKit | iCloud Drive: the app's own ubiquity container (iCloud Documents), with plain files. | The library is already a folder of files with a database snapshot, and `SyncPlan`, `LibraryExporter`, `writeSyncSnapshot` and `SyncReceiver` already work that way. CloudKit records would mean mapping the whole schema to records, and its assets are awkward for tens of GB. CloudKit is worth it only if the phone ever edits the collection. |
| D2 | Where the live library lives | It stays where it is. The container holds a **copy** that the Mac publishes. | SQLite in iCloud Drive corrupts or forks into conflicting copies when two devices touch it, and Optimize Mac Storage could remove the Mac's own music files. |
| D3 | Container | One container, `iCloud.io.github.davidlago.MusicLibrary`, on both App IDs. It's not public (`NSUbiquitousContainerIsDocumentScopePublic` false), so it doesn't appear in iCloud Drive in Finder or Files. | Users can't rename or delete files out from under the app. Restore goes through the app (§7). See §13 Q1. |
| D4 | Layout | The same layout as an export (`Music/…`, `Artist Images/…`) under one root, plus `backup.json`, `Snapshots/`, `Removed.json` and `Inbox/` (§3). | The container is then a valid library folder for restore, and the existing path rules (`SyncPlan.isManaged`, `LibraryPath.resolve`) apply as they are. |
| D5 | Which database copy | One backup snapshot per publish: a `VACUUM INTO` copy without the downloaded library catalog (`catalog_items`, `catalog_info`, `catalog_previews`: a cache that can be downloaded again and often the biggest part). Unlike the Wi-Fi snapshot, it keeps `discogs_sync`, because losing its links would make the next Discogs sync add duplicates. The phone reads the same file and ignores the Mac-only tables. | One file to write and one to trust. It's the user's own iCloud, so the Discogs instance IDs aren't leaving their devices. |
| D6 | Telling which snapshot is newest | The Mac writes `snapshot_at` (ISO 8601, the Mac's clock) into `library_meta` of each copy it makes, both Wi-Fi and iCloud ones (never into the live database). The phone applies a snapshot only when its `snapshot_at` is newer than the one it has. | Wi-Fi sync and iCloud can both deliver `library.sqlite`, so an older iCloud copy must never replace a newer one from Wi-Fi. `library_meta` is key/value, so this isn't a schema change. |
| D7 | Detecting changed files | Size **and** modification date. The copy in iCloud gets the source's modification date. | `SyncPlan` compares sizes only. A retag that fits in the tags' padding keeps the size, and a backup must not miss it. |
| D8 | Deletions | A file removed from the library moves to `Removed.json` with its date and is deleted from iCloud **30 days** later. Restore can bring it back until then. | Without a delay, a mirror deletes your backup when you make a mistake. |
| D9 | Database history | Keep the last 10 snapshots, one a day for 14 days and one a week for 8 weeks. | Snapshots are tens of MB, so the history is cheap and covers slow-burning mistakes. |
| D10 | Scope | A setting with four choices: **Off**, **Library and covers** (database, covers, artist photos: small), **Library, covers and chosen music** (plus the music files of what you pick, D15), **Everything** (plus every music file). It's off by default. Turning it on, and changing what's chosen, shows an estimate of the size. | A lossless library can need a 2 TB iCloud plan, but the database and covers alone are a real backup of the collection, and the albums you care most about (or want on the phone without the Mac) are usually a fraction of it. |
| D11 | Mac disk use | Upload each file from an APFS clone (`clonefile`, then `FileManager.setUbiquitous(_:itemAt:destinationURL:)`), then evict the container's copy (`evictUbiquitousItem`) once `ubiquitousItemIsUploaded` is true. | The music doesn't take twice the space on the Mac. |
| D12 | Phone storage | Downloaded files are **copied** into `Documents/Music Library` (through a hidden partial and a rename, as `SyncReceiver` does), then the container's copy is evicted. | `presentIDs`, playback, offline listening and Remove work as they do now. iOS may remove files in the container whenever it's low on space, which would make songs vanish. |
| D13 | Phone downloads and the Mac's selection | A download from iCloud still records a `SyncRequest`. The request reaches the Mac through `Inbox/` (§6) or the next Wi-Fi sync, and is cleared as it is today. | Wi-Fi sync makes the phone match the Mac's selection, so a download the Mac never heard about would be deleted on the next sync. |
| D14 | Trust | Everything read from the container is untrusted, as with sync: paths checked by `SyncPlan.isManaged` and resolved with `LibraryPath.resolve`, snapshots opened with `Database(snapshotAt:)` (read-only, refuses a newer schema), and Inbox files decoded strictly with size limits. | Another version of the app, a corrupted download or a bug on one device must not be able to write outside the library or crash the other. |
| D15 | Choosing music | The chosen music is a `SyncSelection` of its own (include/exclude rules over `ExportItem`s: albums, artists, playlists, songs; the last rule covering a song decides), kept in the Mac's user defaults (`iCloudBackupSelection`) apart from the iPhone's and the Export List. Artists and playlists resolve when each backup runs, so an artist's new album is backed up without picking it. An option, **Include what's on my iPhone** (on by default), adds every paired phone's resolved selection as implicit include rules (`SyncSelection.resolve(_:implicit:)`), so what the phone may download from iCloud (P5) is there; an exclude rule the user added still wins. Every song's database row, play and like is in the snapshot whatever is chosen. | It's the same model the iPhone list already uses and tests, with the same menus. A song taken off the list is a removal like any other (D8), so a mistaken click doesn't delete the backup of an album. |

## 3. Container layout

```
<container>/Music Library/
  backup.json                          what's here (below); replaced atomically
  Snapshots/2026-10-31T14-05-12Z.sqlite
  Music/<Artist>/<Album> (<Year>)/…     the chosen music (or all of it), plus every cover.jpg
  Music/Collection Covers/…
  Artist Images/…
  Removed.json                         [{path, size, removedAt}], purged after 30 days
  Inbox/<phone id>/<uuid>.json         batches from each phone (§6)
```

`backup.json` (Codable `CloudBackupManifest`, in Core):

```json
{
  "format": 1,
  "libraryID": "…",            // library_meta.library_id
  "macID": "…", "macName": "Dave's MacBook Pro",
  "appVersion": "1.30.0",
  "schemaVersion": 14,
  "scope": "chosen",           // "library", "chosen" or "everything"
  "current": "Snapshots/2026-10-31T14-05-12Z.sqlite",
  "snapshotAt": "2026-10-31T14:05:12Z",
  "tracks": 12873, "musicBytes": 412345678901
}
```

A reader refuses a `format` it doesn't know. A Mac that finds a different `libraryID` in the container asks the user
to replace that backup, keep it and stop, or turn backup off. It never mixes two libraries.

## 4. Core types (platform-neutral, `Sources/MusicLibraryCore/CloudBackup*.swift`)

- `CloudStore` protocol: the container as the rest of the code sees it.
  - `entries() -> [CloudEntry]`: path, size, modification date, `isDownloaded`, `isUploaded`, upload or download
    error.
  - `upload(from:to:modified:)`, `remove(_:)`, `download(_:) async`, `read(_:) -> URL` (a coordinated local URL),
    `evict(_:)`.
  - The implementations are `ICloudStore` (Mac and iPhone: `NSMetadataQuery` on `NSMetadataQueryUbiquitousDataScope`,
    `NSFileCoordinator`, `setUbiquitous`, `startDownloadingUbiquitousItem`, `evictUbiquitousItem`) and
    `FolderCloudStore` (a plain folder, for tests and for restoring from a copied backup).
- `CloudBackupPlan` (pure, like `SyncPlan`): from the library's tracks, collection covers, artist photos, the scope
  (with "chosen music", the selection's tracks, resolved by the caller as `SyncPlan`'s are), the store's entries,
  `Removed.json` and `now`, it works out:
  - uploads, in order: database snapshot first, then covers, artist photos and music;
  - files that move to `Removed.json`;
  - files to purge (removed more than 30 days ago);
  - untrusted entries to ignore, meaning paths that aren't managed.

  Files in the container that the library doesn't have, or that the scope no longer wants, and that `Removed.json`
  doesn't list (left by a crash, an album taken off the chosen music, or switching to a smaller scope) are added to
  `Removed.json` rather than deleted at once. A file that's wanted again is taken off the list.
- `CloudSnapshots`: names, retention (D9), and `Database.writeBackupSnapshot(to:scratch:snapshotAt:)` next to
  `writeSyncSnapshot` (both gain the `snapshot_at` stamp, D6).
- `CloudInbox`: the batch format (§6), with encoding, and decoding with limits.

## 5. Mac: publishing (`CloudBackupStore`, `AppModel.cloud`)

- **When:** two minutes after the last library change (reload, collection edit, recorded play), at most once every
  15 minutes; at launch if the last publish failed; and on **Back Up Now**. Quitting doesn't wait for uploads, since
  iCloud keeps uploading after the app quits.
- **Steps:**
  1. Write the snapshot to scratch.
  2. Upload it under its new name.
  3. Run the plan's uploads, from clones (D11).
  4. Once the snapshot is uploaded, replace `backup.json`, so `current` never names a file that isn't there.
  5. Update `Removed.json`, purge, and prune old snapshots.
  6. Evict uploaded music.
- **Status** comes from the `NSMetadataQuery`: files and bytes still to upload, the last complete backup, and errors.
  - "iCloud is full" comes from `NSUbiquitousFileErrorDomain` / `ubiquitousItemUploadingError`.
  - "Signed out of iCloud" means `ubiquityIdentityToken` is nil.
  - "Another library is backed up here" is the `libraryID` mismatch.
- **Inbox:** the same query watches `Inbox/`. Each new batch is decoded, its events go through
  `Database.applySyncEvents` (which already applies each event once and checks the library ID), and its requests
  are applied to that phone's selection. Requests count only for a paired phone; events count from any phone that
  has this library. Then the batch file is deleted and a publish is scheduled.
- **Which changes count:** `Database.changeCount`, every row written through the app's connection except the
  downloaded library catalog's (a cache the backup leaves out), checked every 30 seconds, plus files written without
  a database change (an album's new cover). Nothing waits for the collection to be built: unlike Wi-Fi sync's
  selection, a backup doesn't depend on it.
- **Upload state:** the Mac lists the container's folder with iCloud's resource values (`ubiquitousItemIsUploaded`,
  `ubiquitousItemUploadingError`). Since macOS 14, a file Optimize Mac Storage evicted keeps its name, size and date
  there, so no `NSMetadataQuery` is needed on the Mac. When iCloud hasn't uploaded the snapshot five minutes after it
  was written, `backup.json` stays on the previous one and the publish counts as unfinished, to be tried again.
- In P1, files that leave the library stay in iCloud: `Removed.json` and purging come with P2.

## 6. iPhone: reading and downloading (`PhoneCloud`, iOS app)

- **Finding the library:** while the app is active, an `NSMetadataQuery` watches `backup.json`. When it names a
  snapshot newer than the phone's (D6), the phone:
  1. downloads it;
  2. checks it with `Database(snapshotAt:)`;
  3. copies it to `Documents/Music Library/library.sqlite` through a partial and a rename;
  4. downloads and copies every cover and artist photo that's missing or different (always wanted, as with Wi-Fi);
  5. reloads.

  A phone with no library yet gets one this way, with no Mac and no pairing. The sample library goes away as it does
  when Wi-Fi sync brings one.
- **Download** (`AvailabilityBar`, Ready to Download, Download All):
  - When a song's file is in iCloud, the phone downloads it, copies it in and evicts it (D12), and records the
    `SyncRequest` (D13).
  - When it isn't in iCloud (the scope is "Library and covers", the song isn't among the chosen music, or it's still
    uploading), the request waits for the Mac as it does today, and the button says so. The request reaching the Mac
    (P6) adds the song to that phone's selection, so with Include what's on my iPhone it goes to iCloud next.
  - The phone refuses a download that doesn't fit, using the sizes from iCloud's metadata, as it refuses a Wi-Fi
    sync.
  - Progress shows per album. iCloud keeps downloading while the app is in the background, and the copy step runs
    when the app is next active (or in a `BGProcessingTask`).
- **Remove** is unchanged: it deletes the local files at once and records the request.
- **Inbox:** when the outbox or request queue changes (debounced) and on becoming active, the phone writes a batch
  to `Inbox/<phone id>/<uuid>.json`:

  ```json
  {"format": 1, "libraryID": "…", "phoneID": "…", "phoneName": "…",
   "events": [SyncEvent…], "requests": [SyncRequest…]}
  ```

  Batches are never edited after they're written: a new batch carries what's new. An event leaves the outbox when a
  snapshot's `sync_events` holds its ID, or when a Wi-Fi sync finishes as today. Requests are cleared as today, once
  a snapshot's selection covers them. The sample library never writes a batch.
- The phone's **Settings** get iCloud: Use iCloud (on when the container is reachable), the last update from iCloud,
  and downloads in progress. The Sync sheet shows the same line, so it's clear the Mac isn't needed.

## 7. Restore (Mac)

- **File ▸ Restore from iCloud…** lists the snapshots (date, tracks, collection items, plays). It offers:
  - **Restore to a new folder:** choose an empty folder; music, covers and photos are downloaded into the library
    layout, the snapshot becomes its `library.sqlite`, and the app opens it. A file listed in `Removed.json` can be
    included ("also bring back what was removed in the last 30 days").
  - **Restore the database only**, into the open library: the current `library.sqlite` is first copied next to it
    (`library-before-restore-<date>.sqlite`). Tracks whose files are missing show as missing, as they do now.
- Restore never writes into the open library's `Music/` folder.
- The same flow takes a `FolderCloudStore` pointed at a copied backup, for a backup someone copied out of the
  container by hand.

## 8. Signing and build

As built in P0 (one-time portal steps: `docs/distribution.md` ▸ iCloud):

- **Mac App ID.** iCloud needs a registered App ID and an embedded provisioning profile, and `local.musiclibrary`
  isn't one. A build made with `PROVISIONING_PROFILE=…` (`scripts/build-app.sh`, which needs `SIGN_IDENTITY`) takes its
  bundle ID from the profile (`io.github.davidlago.MusicLibrary`), embeds it as `Contents/embedded.provisionprofile`,
  and refuses a profile that doesn't allow the container or iCloud Documents. Every other build stays
  `local.musiclibrary`, with the same entitlements and Info.plist as before.
- **Settings move once.** A profile build has its own user defaults domain, so its Info.plist names the old one
  (`MusicLibraryImportsDefaultsFrom`), and `MusicLibraryApp.init` runs `DefaultsImport.runIfAsked()` before
  `AppModel` reads anything. It copies every key the new domain doesn't have, once (`importedDefaultsFrom`), and leaves
  the old domain alone, so a downgrade keeps its settings. The key is written only for profile builds, so a dev build
  with another bundle ID never picks up the real library's settings. The keychain service stays `local.musiclibrary`.
  Keychain access, Local Network and the microphone are granted per bundle ID, so macOS asks for each once more.
- **Entitlements** are generated at build time from `Resources/MusicLibrary.entitlements` plus:
  - `com.apple.application-identifier` and `com.apple.developer.team-identifier` from the profile;
  - `com.apple.developer.icloud-container-identifiers` and `com.apple.developer.ubiquity-container-identifiers` with
    `ICLOUD_CONTAINER` (default `iCloud.io.github.davidlago.MusicLibrary`);
  - `com.apple.developer.icloud-services` = `CloudDocuments`;
  - `com.apple.developer.icloud-container-environment` = `Production`, only when the profile lists it.
- **CI:** the profile is a secret, `MAC_PROVISIONING_PROFILE` (base64). A tagged build with it is an iCloud build;
  without it, it's built as before. This replaces the earlier idea of having `scripts/provisioning-profiles.swift` make
  a Developer ID profile: a Developer ID profile lasts as long as its certificate, and the App Manager API key may not
  be allowed to create one.
- **iPhone:** `iOS/MusicLibraryMobile.entitlements` (app group plus iCloud) is used only by the app target, through
  `APP_ENTITLEMENTS` in `iOS/Signing.xcconfig`. It defaults to `AppGroup.entitlements`, because Personal Teams can't
  have iCloud and the App ID needs the container first. Set it in `Local.xcconfig`, `ICLOUD=1` for
  `scripts/testflight.sh`, or the repository variable `ICLOUD` for CI's TestFlight job. CI's unsigned iOS build always
  uses the iCloud file, so it stays checked. Widgets and the watch keep `AppGroup.entitlements`.
- **At run time:** `CloudContainer` (Core) reads the identifier from the Info.plist key `MusicLibraryICloudContainer`
  (written by `build-app.sh`, and from `$(ICLOUD_CONTAINER)` on the iPhone) and finds the container off the main thread
  only when signed in to iCloud. Both apps call `CloudContainer.logAvailability()` at launch, which logs what it
  found (subsystem `local.musiclibrary`, category `iCloud`). That's the P0 check that a signed build reaches the
  container. Nothing shows in the UI yet.
- `PrivacyInfo.xcprivacy`: nothing new in P0. File timestamps and disk space are already declared; check again in P5.

## 9. Mac UI

- **Settings ▸ iCloud:**
  - the scope (D10), with the estimated size;
  - with "chosen music": Include what's on my iPhone, and a link to the iCloud page;
  - status: last backup, what's left to upload, errors;
  - Back Up Now;
  - Restore…;
  - Snapshots, a list with Reveal and Restore.
- **iCloud page** (sidebar, Devices section, shown while the scope is "chosen music"): the chosen albums, artists,
  playlists and songs, like the iPhone page, with each one's size and whether it's uploaded, the total, and what the
  iPhone option adds. Albums, artists, playlists and songs get **Add to iCloud** / **Remove from iCloud** in their
  context menus, next to Add to iPhone (`AddToExportListButton`).
- The iPhone page shows each phone's last Inbox batch next to its last Wi-Fi sync.
- The first time the scope is turned on, a sheet explains what goes to iCloud, the size, and that the Mac's music
  stays where it is.

## 10. Documentation

- A new guide page, `docs/guide/icloud.md`, indexed in `docs/guide/README.md`.
- `docs/guide/privacy.md` says what goes to iCloud, and that it is the user's own iCloud.
- The iPhone sync page says what works without the Mac.
- The README and the website's home page get a line under backups/iPhone.
- `CHANGELOG.md` under `## Unreleased`; App Store copy in `docs/app-store/README.md`.

## 11. Tests (Swift Testing, against `FolderCloudStore`; none touch real iCloud)

- `CloudBackupPlanTests`:
  - first backup, and nothing to do the second time;
  - a changed size, and a changed date with the same size (D7);
  - a removed track goes to `Removed.json`, a purge after 30 days, and a track that comes back is taken off the
    list;
  - "Library and covers" leaves out music;
  - "chosen music" uploads the selection's songs (an artist's new album included) and the phones' with Include what's
    on my iPhone, an exclude rule wins over a phone's, and a song taken off the list goes to `Removed.json`;
  - untrusted paths (`..`, absolute paths, symlinks, outside the managed folders) are ignored.
- `CloudSnapshotTests`:
  - `snapshot_at` stamped in the copy and not in the live database;
  - the catalog tables are gone and `discogs_sync` is kept;
  - retention (D9) over a simulated year;
  - `backup.json` is replaced only after its snapshot is there.
- `CloudInboxTests`:
  - a round trip;
  - an event applied once across a re-sent batch and a Wi-Fi sync;
  - the wrong `libraryID` is ignored;
  - requests from an unpaired phone are ignored;
  - files that are too big, garbage, or an unknown `format` are rejected without crashing.
- `CloudRestoreTests`: restoring from a backup gives a library that opens with the same tracks, collection items
  (ids and covers), plays and likes; database-only restore keeps the copy made before it.
- Phone side, in Core (`CloudReceiver`): an older snapshot never replaces a newer one, in either order of Wi-Fi and
  iCloud; copies go through partials; bad paths are refused.
- The existing migration, downgrade and `SyncTests` suites stay as they are. Snapshots without `snapshot_at`
  (written by older Macs) count as older than any stamped one.
- By hand on two real devices:
  - airplane mode during an upload and during a download;
  - signed out of iCloud;
  - a full iCloud plan;
  - Optimize Mac Storage on;
  - a phone with no library getting one from iCloud;
  - a Wi-Fi sync right after an iCloud download (the song must stay, D13).

## 12. Phases

1. **P0, signing groundwork (done):** profile builds, entitlements, `build-app.sh` and CI, the iPhone entitlements
   split, the defaults import, `CloudContainer`. The feature is still hidden. Still to check once the portal is set
   up: that a signed build reaches the container on both devices (`docs/distribution.md` ▸ iCloud).
2. **P1, Mac backup of the library and covers (done):** the snapshot stamp (Wi-Fi snapshots too), `CloudStore`,
   `CloudBackupPlan`, snapshots and `backup.json`, Settings ▸ iCloud, status.
3. **P2, Mac backup of music:** the chosen music (D15: the selection, the iCloud page, Add to iCloud, Include
   what's on my iPhone) and Everything; music files from clones, eviction, `Removed.json`, purge.
4. **P3, Restore:** to a new folder, and the database only.
5. **P4, phone reads from iCloud:** snapshot and covers, no pairing needed.
6. **P5, phone downloads from iCloud:** Download, Download All, free-space check, background copy step.
7. **P6, Inbox:** the phone's events and requests, applied by the Mac.
8. **P7, docs and polish:** guide, privacy, README and site, CHANGELOG, App Store copy, screenshots. Settings ▸
   iCloud shows only in iCloud builds, and releases aren't until `MAC_PROVISIONING_PROFILE` is set, so the CHANGELOG
   entry and guide page for the Mac backup go in the release that first sets it, at the latest.

P1 to P3 are useful on their own as a Mac backup. P4 and P5 need P1 (and P2 for music). P6 can follow P4 or come
in parallel with P5.

## 13. Open questions

- **Q1, container visibility:** should the backup show in iCloud Drive (Finder, Files) so it can be inspected and
  copied by hand? It's hidden in this plan (D3), and restore covers the need.
- **Q2, bundle ID (decided in P0):** profile builds are `io.github.davidlago.MusicLibrary`, with the settings import
  above. Before the first release with it, test with a copy of a real library: the import, the keychain prompt, Local
  Network and the microphone. The Application Support and Caches folders are named `MusicLibrary`, so the new bundle
  ID doesn't affect them.
- **Q3, selection on the phone:** once downloads come from iCloud, should the phone own its "On This iPhone" choice
  outright, with Wi-Fi sync following the phone instead of the Mac's selection? That would be a protocol change
  (version 4), out of scope here.
- **Q4, several Macs:** a second Mac sees the `libraryID` mismatch and is asked. Is that enough, or should the
  container hold one folder per library?
