# Changelog

What's new in each release. Add user-visible changes under **Unreleased** as they land; when tagging a release, rename
that heading to the version (for example `## 1.9.0`) and start a new, empty **Unreleased**. The release workflow puts the
section for the tagged version at the top of the GitHub release notes (or **Unreleased**, if there's no section for it).
Releases before 1.8.0 are described on the [Releases page](https://github.com/davidlago/music-library/releases).

## Unreleased

## 1.16.0

- **Try the iPhone app without a Mac.** **Explore a Sample Library** on the empty Library tab opens a sample library
  built into the app: fictional artists and albums, with songs synthesized for it and covers drawn for it, listening
  history, likes and owned albums, so every page, Insights, Music DNA, the widgets and the Apple Watch app can be tried.
  Nothing done in it goes to the Mac or Last.fm, and your own library replaces it after your first sync (or hide it from
  the Library tab or Settings).
- The website has a [privacy policy](https://davidlago.github.io/music-library/privacy.html) and a
  [support page](https://davidlago.github.io/music-library/support.html).

## 1.15.0

- **Owned albums stand out.** Albums you've marked as owned show a small disc badge in the corner of their cover in
  the album grids: Albums, artist pages and search results on the Mac, and Albums and artist pages on the iPhone.
- **Counts at a glance.** The Mac sidebar shows how many songs, albums and artists the library has. The iPhone's
  Library tab shows counts for Artists, Albums, Songs and Liked Songs, counting only what's on the iPhone when
  **On This iPhone** is chosen.

## 1.14.0

This release changes how releases are made; the Mac and iPhone apps work as in 1.13.0.

- Every release now also goes to TestFlight automatically, as the same version as the Mac app.

## 1.13.0

- **The Mac app is notarized and needs nothing else.** Releases are signed with a Developer ID certificate and notarized
  by Apple, so the app opens like any other: no more **Open Anyway** in Privacy & Security. It includes its own ffmpeg,
  ffprobe and fpcalc, so Homebrew's ffmpeg and chromaprint aren't needed anymore, and AcoustID fingerprinting works with
  just an API key. **Settings ▸ General ▸ Tools** shows "Included with the app". After updating, macOS asks once more to
  allow keychain access; choose **Always Allow**.
- **The iPhone app is on TestFlight** for invited testers; see the
  [iPhone app](https://github.com/davidlago/music-library#iphone-app) section of the README. Building it with Xcode still
  works.
- When a sync doesn't fit on the iPhone, the iPhone now stops it, before deleting or copying anything, and says how much
  space it needs; it no longer tells the Mac how much space it has free.

## 1.12.0

This release is for the iPhone app; the Mac app is unchanged, and syncing works as in 1.11.0. Rebuild the iPhone app from
Xcode to get it (see the [iPhone app](https://github.com/davidlago/music-library#iphone-app) section of the README).

- **iPhone widgets.** Listening (time listened in the past 7 or 30 days, a bar per day, your streak and top artists,
  songs and albums), Now Playing (with play/pause, previous, next and like buttons that work without opening the app),
  Recent Purchases (what you bought lately and spent this year), Rediscover (favorites you haven't played in months, with
  Play) and Library (its size, how much is on the phone, what was added last). Listening and Now Playing are on the lock
  screen too. Tapping one opens its album, Now Playing or Insights.
- **An Apple Watch app.** A remote for the iPhone's player (play/pause, skip, like, and starting Liked Songs, a shuffle or
  an album), your listening and purchases, and complications for listening time, the song playing and this year's
  purchases. It installs with the iPhone app and needs watchOS 26 or later.
  [Screenshots](https://github.com/davidlago/music-library#widgets-and-apple-watch).
- The iPhone app's icon no longer has a white frame around it.
- To use your own bundle identifier for the iPhone app, set `APP_BUNDLE_ID` (not `PRODUCT_BUNDLE_IDENTIFIER`) in
  `iOS/Local.xcconfig`; the widgets, watch app and app group are named after it.

## 1.11.0

- **Your whole library on the iPhone.** Every sync now sends the details of the entire library (every album and artist
  with their covers and photos, descriptions, ratings, credits, listening history and ownership), not just the music on
  the phone, so you can browse all of it there; what isn't on the phone is dimmed.
- **Download and remove music from the iPhone.** Tap **Download** on any album, artist or playlist (or a song) and the
  phone gets it from the Mac over Wi-Fi as soon as Music Library is open there; **Remove from iPhone** frees the space at
  once. The Mac keeps listening for its paired phones while it runs (macOS may ask once to allow incoming connections),
  and its **iPhone** page shows what was taken off the phone. The phone's Library tab shows **All Music** or only what's
  **On This iPhone**. Update both apps together: this sync works only between this version of each.
- **The Mac's album and artist pages on the iPhone.** Album pages have the description, rating, genres, your listening,
  the release's full track list, release details, credits (which open Music DNA), links and **Your Copy**, which you can
  edit on the phone. Artist pages have the photo, bio, links, concerts near you (with the Mac's concert settings), albums
  and most played songs. A song's menu has **Song Info**.
- **Music DNA and Insights on the iPhone,** with the same graph, collaborators, charts, rankings and fun facts as the Mac,
  for the Library, Listening and Owned panes.

## 1.10.0

- **What you do on the iPhone comes back to the Mac.** Like and unlike songs on the phone (in Now Playing or a song's
  menu); each sync brings those changes and the phone's listening history back to the Mac, so Liked Songs, play counts and
  Insights cover both. The phone scrobbles its own plays, so nothing is scrobbled twice. Update both apps together: this
  sync works only between this version of each.
- **Last.fm on the iPhone without typing keys.** If the Mac is connected to Last.fm and the phone isn't, the next sync
  connects the phone with the Mac's account.

## 1.9.0

- **Sync to the iPhone over Wi-Fi.** Pair the iPhone app with the Mac once (a code the phone shows, typed on the Mac),
  then choose what goes on the phone with **Add to iPhone** in any album, artist, playlist or song menu. **Sync Now** on
  the Mac's new **iPhone** page copies new and changed files, removes what you took off the list (the first sync asks
  before removing anything) and updates the phone's library, playlists and Liked Songs. Syncs are encrypted with a key
  the two exchange when pairing, and an interrupted sync leaves only complete files on the phone.
- The iPhone app has a **Sync** tab for pairing and syncing; keep it open while a sync runs.

## 1.8.0

- **iPhone app (first version).** Play part of your library offline on an iPhone (iOS 27), through a USB DAC at each
  song's own sample rate, with gapless playback between songs at the same rate, the Mac's search, playlists, Liked Songs
  and covers, lock screen controls, and Last.fm scrobbling. It's installed from Xcode for now; see
  [iPhone app](https://github.com/davidlago/music-library#iphone-app) in the README.
