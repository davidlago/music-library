# Changelog

What's new in each release. Add user-visible changes under **Unreleased** as they land; when tagging a release, rename
that heading to the version (for example `## 1.9.0`) and start a new, empty **Unreleased**. The release workflow puts the
section for the tagged version at the top of the GitHub release notes (or **Unreleased**, if there's no section for it).
Releases before 1.8.0 are described on the [Releases page](https://github.com/davidlago/music-library/releases).

## Unreleased

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
