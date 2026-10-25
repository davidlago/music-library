# Ripping CDs

Insert an audio CD and it appears in the sidebar under **Import**. Music Library identifies it, rips the tracks you
choose to lossless FLAC, tags and files them like any import, checks every track against AccurateRip, and links the rip
to the CD in your [Physical Collection](physical-collection.md).

## Identifying the disc

A disc is looked up on MusicBrainz by its table of contents (the exact start of every track). When several releases
share it, pick yours from **Edition** (exact matches are marked ✓). When nothing matches exactly, the page warns you
("No exact match for this disc on MusicBrainz — these releases have a similar track layout") and lets you search by
album and artist under **Not the right album?**.

## Ripping

Check the tracks you want (all of them by default) and click **Rip N Tracks**. Each track is read, encoded to FLAC,
tagged with the release's metadata, credits and cover, and imported. The track list shows each one's status as it goes:
Importing, Imported, or "In digital collection" for tracks you already have.

- **Eject CD after ripping** is in **Settings ▸ General ▸ CD ripping** (on by default). A disc with a misread track
  isn't ejected, so you can rip it again.
- **Rip to Import Queue** rips the checked tracks to FLAC without a release, for you to match on the Import page.
- **Cancel** stops after the current track.

## In your Physical Collection

The CD page's collection panel says whether this disc is already an item ("This is CD #37 in your physical collection,
not ripped yet. This rip will be linked to it.") and lets you pick another copy, add it as a new copy with the next
label, or say it isn't yours. The label, date bought and price can be filled in right there.

- By default, a CD that isn't in your collection yet is added when you rip it. Turn on **Ask whether a CD is yours when
  it's inserted** (Settings ▸ General ▸ Physical Collection) to be asked instead.
- **Catalog Without Ripping** adds the CD with its cover and ejects it (**Eject after cataloging**).
- The rip is linked as soon as its first track is imported, so a cancelled rip leaves the item not ripped.

## Checking rips with AccurateRip

[AccurateRip](https://www.accuraterip.com) keeps checksums of other people's rips of millions of CDs. Right after a
rip, each track is compared with them:

- **Accurate**: bit for bit the same as other people's rips (with how many agree).
- **Inaccurate**: other tracks on the disc matched but this one didn't, so it was misread (a scratch, a dirty disc).
- **Unknown**: the disc isn't in AccurateRip, or the track can't be checked.

The check finds your drive's read offset by itself (macOS doesn't correct it) and also recognizes other pressings of
the same CD whose audio sits a little further along.

**Rip Again** on a misread track reads it again straight from the disc, bypassing the file cache, up to five times,
combining the reads sample by sample and checking each attempt from memory. From the third read it also tries the
damaged spots' different versions in combination until one matches AccurateRip's checksums. The repaired track replaces
the library file in place, so its plays, likes and playlists stay; nothing is replaced when the new read is no better.

Albums ripped earlier can be checked from their files: **Check with AccurateRip** in an album page's **…** menu. Only
lossless 16-bit, 44.1 kHz stereo files can be checked (anything else isn't CD audio). The result shows on the album
page ("AccurateRip: all 10 tracks accurate").

## Discs MusicBrainz doesn't know

When MusicBrainz has nothing for a disc, the page uses the names macOS knows for it (the ones Finder shows, from the
disc's CD-Text or Apple's Gracenote lookup): the song titles fill the track list, and the album and artist are filled
in ("Placido Domingo Popular Favorites" becomes Popular Favorites by Plácido Domingo).

- Correct anything on the page: click a song title to change it.
- **Choose Cover…** finds covers on the Cover Art Archive, or takes a file, the clipboard, or an image dropped on the
  cover (also from a web page).
- **Rip** puts the songs straight into your digital collection with those names and that cover.
- **Submit this disc to MusicBrainz…** opens MusicBrainz so the disc is known next time.

The disc can go in your Physical Collection too, and **Catalog Without Ripping** works the same way.
