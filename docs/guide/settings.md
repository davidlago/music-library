# Settings

Music Library ▸ Settings… (⌘,) has seven tabs. Keys, passwords and secrets are kept in your keychain, never in
preferences.

## General

| Setting | What it does |
|---|---|
| **Library Folder** | Where your library lives (`~/Music/MusicLibrary` by default). Changing it opens or creates a library there; nothing is moved. |
| **Export ▸ Destination** | Where the [Export List](export-and-backup.md) copies to. |
| **MusicBrainz ▸ Contact email** | Sent with MusicBrainz requests, as their etiquette asks. |
| **Auto-match confident results** | Import matches with a score of 95 or more and a length within 5 seconds without asking (on). |
| **AcoustID fingerprinting** | Your AcoustID API key, to identify songs by their sound ([get one](https://acoustid.org/new-application)). |
| **Artist & album info** | Download photos, bios, album descriptions and links automatically (on). **Update All Now** fetches it for everything. |
| **CD ripping ▸ Eject CD after ripping** | On by default. |
| **Physical Collection** | **Ask whether a CD is yours when it's inserted** (off: a CD you rip is added unless you say otherwise) and **Eject after cataloging** (on). |
| **Tools** | Where ffmpeg, ffprobe and fpcalc were found (they're included in the app). |

## Playback

**Match output device sample rate to the song** (on) and **Match output bit depth** (on). They change your output
device's format for all apps while playing, and restore it when you quit or turn them off; devices with a fixed rate
(Bluetooth, AirPlay) aren't affected. See [Playback](playback.md#bit-perfect-output).

## Appearance

**System** (the default) follows your Mac's light or dark setting. **Light** and **Dark** keep the app in one mode,
whatever the Mac uses. The same choice is in **View ▸ Appearance**, and the iPhone app has its own in its Settings.

> Versions before 1.28 had color themes. They're gone: a theme you had picked became its mode the first time you opened
> this version. Themes that came in light and dark became **System**, and the others became **Light** or **Dark**.

## Last.fm

Your Last.fm API key and shared secret, **Connect…**, **Scrobble songs I play** (on), **Show what's playing now on my
profile** (on), what's waiting to be sent, and your recent scrobbles. See [Playback](playback.md#lastfm).

## Concerts

Your ZIP or postal code and distance, your Ticketmaster Consumer Key and JamBase API key, and **Show upcoming concerts on
artist pages** (on). See [Concerts](concerts.md).

## Discogs

Your Discogs personal access token (**Connect**), the account it's connected to, and the folder **Sync to Discogs**
adds new copies to. See [Physical Collection](physical-collection.md#sync-to-discogs).

## iCloud

What to back up to your iCloud (**Off**, **Library and covers**, **Library, covers and chosen music** or
**Everything**) with the size of each, **Include what's on my iPhone**, the backup's status with **Back Up Now** (and **Delete Now…** for music waiting to be
deleted), and **Restore from iCloud…**. Only in versions with iCloud. See [iCloud backup](icloud.md).

## Radio DJ

Your Claude API and OpenRouter keys (**Check** tests each), the model (**Choose Model…**, with prices), the **DJ's name** and **Your name**, and what the DJ has cost: this month, all
time, segments and web searches, per device. See [Radio DJ](radio-dj.md).

## Local Library

The catalog's website, your local library, your library account and list, the downloaded catalogs (**Add a
Library…**, **Update Now**, **Look Up Missing Album Details**), and **Look up track lists, covers and info on
MusicBrainz as CDs load** (on). See [Local Library CDs](local-library.md).

## Keyboard shortcuts

| Shortcut | Does |
|---|---|
| ⇧⌘N | Add to Physical Collection… |
| ⌘O | Import… |
| ⌘L | Find by Label… |
| ⌥⌘U | Show or hide the queue |
| Space | Play or pause |
| ⌘I | Get Info for the selected song |
| ⌘[ and ⌘] | Previous and Next on Shelf, on an item page |
| ⌘↩ | Import the selected file (Import page); Add (Add to Physical Collection) |
| ⌥⌘↩ | Add & Next (Add to Physical Collection) |
| ↑ ↓, ⇥, ↩ | Step along the shelf, switch series, open (Find by Label) |
| Delete | Remove the selected songs (playlists, the queue, the Export List, the iPhone list) |
| Esc | Close Now Playing, sheets and panels |
| ⌘, | Settings |
