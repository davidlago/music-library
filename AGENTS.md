# Music Library – agent notes

Native macOS music library app (SwiftUI) built with SwiftPM only; no Xcode project, no third-party dependencies. Works with Xcode or just the Command Line Tools. MIT licensed.

- `Sources/MusicLibraryCore`: all non-UI logic (SQLite, tags via ffprobe/ffmpeg, organizer, MusicBrainz/AcoustID/CoverArt clients, import, export, search, stats).
  - Search: `Search.swift` parses the query language (`SearchQuery`, filter keys in `SearchFilterKey.all`); `SearchIndex.swift` is an immutable in-memory index (matching, ranking, completions, spelling correction). The app rebuilds it off the main thread on every library reload; smart playlists are saved query strings evaluated against it.
  - `Themes.swift`: theme palettes (8 base colors each; card, separator and chart ramps are derived). `ThemeTests` enforce contrast for every palette, so new themes must pass them. The app applies a theme with `.themedRoot(_:)`; use `.subtext` instead of `.secondary` for secondary text (`Text` ignores custom hierarchical styles).
  - `LastFM.swift`: signed Last.fm client (injectable transport for tests), `ListenTracker` (scrobble rules), `ScrobbleQueue` (persisted to Application Support). `Scrobbler` in the app connects them to the player.
  - `ArtistInfo.swift`: artist info from MusicBrainz (url-rels, genres), Wikidata, Wikipedia summaries and Last.fm; pure parsers and `ArtistInfo.assemble` are tested with real fixtures, `InfoFetcher` does the network calls (artists and albums). `ArtistResolver` picks the MusicBrainz artist (multi-artist credits need a confident name match). The app's `ArtistInfoStore` caches it in the `artist_info` table and `<root>/Artist Images`.
  - `AlbumInfo.swift`: album info from the MusicBrainz release group (rating, filtered genres, review links), the matched release's track list, Wikipedia and Last.fm; `AlbumTracklist.merge` lines the release up with the library's tracks. Cached in `album_info` by `AlbumInfoStore` (opening an album fetches it first).
  - `MusicDNA.swift`: `CollaborationGraph`, people from credits/tags/track artists (merged by MusicBrainz ID, then normalized name; non-musical release credits like photography are skipped) linked by shared tracks, plus the capped breadth-first neighborhood and radial layout shown on the Music DNA page. Rebuilt with the search index. In the UI, show people's names with `PersonLink`/`PersonLinks`/`PeopleRow` (pass `model.showMusicDNA` as `open`) so they open Music DNA.
  - `PlayQueue.swift`: the Spotify-style play queue (the list playback started from, plus songs queued with Play Next / Add to Queue, which always play next). `Player` wraps it; `QueueView` shows it in the window's inspector.
  - Listening history: the `plays` table (one row per listen, `counted` = met the scrobble rule), recorded by `AppModel` from player events.
  - `LibraryExport.swift`: `LibraryExporter` copies tracks to another folder using the library's layout (data only, via a hidden partial file and a rename; it never overwrites or deletes), writes `Playlists/*.m3u`, and can replace `<dest>/library.sqlite` with a `VACUUM INTO` snapshot (bringing `Artist Images` up to date with it). `ExportPreview` scans a destination's `Music` folder and merges it with the plan, per album folder, for the Export List's split view. The app's Export List (`ExportItem`, `ExportViews.swift`) collects albums, songs, artists and playlists and resolves them to tracks at export time; the destination is a setting (`AppModel.exportDestination`). `PlaylistExporter` (in `Import.swift`) is the older one-folder-per-playlist export.
  - `Stats.swift`: `LibraryStats`, everything shown in Insights, computed in one pass with data-driven list sizes and bucket granularity.
- `Sources/MusicLibrary`: SwiftUI app (`AppModel`, `Player`, `ImportController`, views).
- `Tests/MusicLibraryCoreTests`: Swift Testing suites; fixtures in `Fixtures/`.

## Environment (Command Line Tools only; not needed with Xcode)
SwiftUI's `@State`/`@Environment` macro plugin is not shipped with the CLT, so the default macOS 27 SDK cannot compile the app target. Use the macOS 26 SDK:

    export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk

`scripts/build-app.sh` does this automatically. Without Xcode, `Package.swift` adds the CLT swift-testing macro plugin path to the test target. ffmpeg/ffprobe are found in /opt/homebrew/bin, /usr/local/bin or `PATH` (fpcalc optional).

## Commands
- Build: `swift build`
- Test: `swift test` (needs ffmpeg; generates audio with `ffmpeg -f lavfi`)
- Live network tests (MusicBrainz, Cover Art Archive): `MUSICLIB_LIVE_TESTS=1 swift test --filter LiveTests`
- Build app bundle: `scripts/build-app.sh` -> `build/MusicLibrary.app` (ad-hoc signed; `VERSION=…`, `BUILD=…`, `UNIVERSAL=1` for arm64 + x86_64, which needs Xcode)
- Regenerate the app icon (`Resources/AppIcon.icns`, `AppIcon-1024.png`): `swift scripts/make-icon.swift` (needs the `SDKROOT` above).
- Run: `open build/MusicLibrary.app` or `swift run MusicLibrary`

## CI and releases
- `.github/workflows/ci.yml` builds, runs the tests and builds a universal app on every push and pull request (macOS runner, newest stable Xcode, ffmpeg from Homebrew).
- Pushing a tag `vX.Y.Z` also publishes a GitHub release with `MusicLibrary-X.Y.Z-macOS.zip` (ad-hoc signed, not notarized) and its SHA-256.
- README screenshots live in `docs/screenshots/` (1600 px wide, taken from a real library window).

## Conventions
- UI layout: the player bar sits below the `NavigationSplitView`, not inside the detail column (views pushed on a `NavigationStack` draw over siblings in their column on macOS). Pages push `AlbumSummary`/`ArtistSummary` onto the single root stack via `NavigationLink(value:)`; don't nest another `NavigationStack`.
- Views inside `Table` cells must not read `@Environment(AppModel.self)`: cells don't always receive it and the app crashes while scrolling. Pass the model, an object from it, or an action from the parent instead.
- Library layout: `<root>/Music/<AlbumArtist|Artist>/<Album> (<Year>)/<NN> - <Title>.<ext>`, DB at `<root>/library.sqlite`, track paths stored relative to root.
- Source files are never modified; tags are written only to the library copy (mp3, flac, m4a).
- MusicBrainz requests are rate limited (>=1.1 s) and identify the app with `AppInfo.userAgent`; tests must not hit the network unless `MUSICLIB_LIVE_TESTS=1`.
