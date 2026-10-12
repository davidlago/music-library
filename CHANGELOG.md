# Changelog

What's new in each release. Add user-visible changes under **Unreleased** as they land; when tagging a release, rename
that heading to the version (for example `## 1.9.0`) and start a new, empty **Unreleased**. The release workflow puts the
section for the tagged version at the top of the GitHub release notes (or **Unreleased**, if there's no section for it).
Releases before 1.8.0 are described on the [Releases page](https://github.com/davidlago/music-library/releases).

## Unreleased

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
