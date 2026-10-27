# Getting started

Music Library is a Mac app (macOS 14 or later, Apple silicon and Intel) with a free companion app for iPhone and Apple
Watch. Everything lives in one library folder on your Mac; the iPhone gets a copy of it over Wi-Fi.

## Install the Mac app

1. Download `MusicLibrary-<version>-macOS.zip` from the
   [latest release](https://github.com/davidlago/music-library/releases/latest).
2. Unzip it and drag **MusicLibrary.app** to your Applications folder.
3. Open it. The app is signed and notarized by Apple, and it includes the ffmpeg, ffprobe and fpcalc it uses to read
   and write tags, rip CDs and fingerprint songs, so there's nothing else to install.

The first time a new version reads your saved keys and passwords, macOS may ask to allow access to the keychain;
choose **Always Allow**. (See [Troubleshooting](troubleshooting.md#keychain-prompts) for why.)

> Coming from a release before 1.13? Those needed **Open Anyway** in System Settings and Homebrew's ffmpeg. Neither is
> needed now; you can uninstall Homebrew's ffmpeg unless something else uses it.

## Your library folder

Your library lives in `~/Music/MusicLibrary` unless you choose another folder in **Settings ▸ General ▸ Library
Folder**. Inside it:

| What | Where |
|---|---|
| Your music | `Music/<Album Artist>/<Album> (<Year>)/<NN> - <Title>.<ext>`, each album folder with its `cover.jpg` |
| Covers of the CDs and records you own | `Music/Collection Covers` |
| Everything else: what you own, playlists, listening history, looked-up info, the downloaded library catalog | `library.sqlite` |
| Artist photos | `Artist Images` |

Files you import are copied in and tagged; your originals are never changed. Changing the folder opens (or creates) a
library there; nothing is moved.

### Moving to another Mac

Quit the app, copy the whole library folder (to an external drive, say), and on the new Mac choose it in **Settings ▸
General**. Everything comes along: your music, what you own, playlists, history and the cached info. To pair the new
Mac with your iPhone, see [iPhone app](iphone.md#pair-once).

## First steps

- **Catalog what you own.** **File ▸ Add to Physical Collection…** (⇧⌘N) adds a CD, record or download by its barcode
  or a few words; **Physical Collection ▸ Add Albums You Own…** adds albums already in your digital collection in
  bulk. See [Physical Collection](physical-collection.md).
- **Bring in music.** **File ▸ Import…** (⌘O), drop files or folders on the window, or insert a CD. See
  [Importing music](importing.md) and [Ripping CDs](ripping-cds.md).
- **Get the iPhone app.** [Dave's Music Library](https://apps.apple.com/us/app/daves-music-library/id6822005512) on the
  App Store, then pair it from **Sync**, at the top of its Listen Now tab. See [iPhone app](iphone.md).

## Settings worth filling in on day one

All optional; the app works without any of them.

| Setting | Where | Why |
|---|---|---|
| Your email | Settings ▸ General ▸ MusicBrainz | MusicBrainz asks apps to say who's making requests |
| AcoustID API key | Settings ▸ General ▸ AcoustID | Match songs by their sound when the tags don't say enough ([free key](https://acoustid.org/new-application)) |
| Last.fm | Settings ▸ Last.fm | Scrobble what you play ([free API account](https://www.last.fm/api/account/create)) |
| ZIP code and concert keys | Settings ▸ Concerts | Upcoming shows near you ([Concerts](concerts.md)) |
| Claude API or OpenRouter key | Settings ▸ Radio DJ | The [Radio DJ](radio-dj.md) |
| Your public library | Settings ▸ Local Library | Browse its CDs ([Local Library CDs](local-library.md)) |

The rest of the settings are described in [Settings](settings.md).

## Finding your way around

The sidebar starts with **Listen Now**, then your collection and the tools around it:

| Section | Items |
|---|---|
| **Collection** | Shelf, CDs, Vinyl, To Digitize (shown while something's left to digitize), Albums, Songs, Downloads |
| **Explore** | Artists, Insights, Music DNA, Concerts |
| **Acquire** | Import, any inserted CD, Digitize Vinyl, Local Library CDs, My Checkouts, your library list, Shop |
| **Devices** | iPhone, Export List |
| **Playlists** and **Smart Playlists** | Liked Songs and your own |

Once there's anything in your library or collection, the app opens on **Listen Now**: the album playing (or the one you
played last) at the top, with Play, Shuffle and Open Album, then the albums you've been playing, your week in four
numbers, what's up next in the queue, and the album's neighbors on the shelf when you own it with a label. The page
takes its color from the album's cover, as album and artist pages do from their cover and photo.

The search field at the top right searches everything (see [Search](search.md)), and the player floats at the bottom of
the window (see [Playback](playback.md)).
