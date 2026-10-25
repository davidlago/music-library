# Export and backup

The **Export List** copies music to another folder (a USB music player, an SD card, a drive) in your library's own
layout, and can back up your whole library database at the same time.

## Build the list

Right-click albums, songs, artists or playlists and choose **Add to Export List** (also in album and artist page
toolbars), or **Add Entire Digital Collection** on the Export List page. Albums, artists and playlists are resolved to
songs when you export, so an artist added today includes the albums you add tomorrow.

## Choose the destination

**Choose Destination…** picks the folder or drive; it's remembered (also in **Settings ▸ General ▸ Export**). When the
drive isn't connected, the page says so.

With a destination, the page shows two lists side by side: what you're adding and what the drive already has, per album
folder, marking each album **Already there**, **All new** or **+N new** with its size. **Only changes** hides what's
already copied.

## Export

**Export to "…"** copies what's new:

- Files go to `Music/<Album Artist>/<Album> (<Year>)/` with their covers, exactly as in your library.
- Files already there are never overwritten, and nothing on the drive is deleted.
- Each copy is written to a hidden partial file and renamed when complete, so an interrupted export leaves nothing
  half-written.
- **Write playlist files (.m3u) to a Playlists folder** (on by default) adds your playlists in the export.

When it's done, **Show in Finder** and **Eject**.

## Back up the library

Turn on **Back up the library database and artist photos (replaces library.sqlite at the destination)** and the export
also writes a consistent snapshot of `library.sqlite` (what you own, playlists, history, cached info) to the destination,
and brings its `Artist Images` and the covers of the copies you own up to date. Export your entire digital collection
with this on and the drive holds a complete library: choose it in **Settings ▸ General ▸ Library Folder** on any Mac to
open it.

For a full backup without the export, quit the app and copy the library folder; see
[Getting started](getting-started.md#moving-to-another-mac).

## Exporting one playlist

**Export…** on a playlist's page copies just that playlist to a folder of its own, with an `.m3u` file.

## A first load for the iPhone

The Export List with the database option on is also the fastest way to put a big library on the iPhone: see
[iPhone app](iphone.md#a-big-first-load).
