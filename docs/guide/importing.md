# Importing music

Import brings music files into your Digital Collection: it identifies each song on MusicBrainz, tags a copy of the file
with everything it finds, and files it in your library folder. Your original files are never modified.

## Adding files

- **File ▸ Import…** (⌘O) or **Add Files…** on the Import page.
- Drop files or folders anywhere on the window.
- Insert a CD (see [Ripping CDs](ripping-cds.md)).

FLAC, MP3, M4A (AAC and ALAC), WAV and AIFF all work. Folders are searched for audio files, so you can drop a whole
download or an old music folder at once.

## Matching

Every file is matched against [MusicBrainz](https://musicbrainz.org), the open music encyclopedia, using its tags,
file name, folder and length. With an [AcoustID key](https://acoustid.org/new-application) in **Settings ▸ General ▸
AcoustID fingerprinting**, a song can also be identified by its sound (the **Fingerprint** button), which finds files
whose tags say nothing useful.

Confident matches (a score of 95 or more and a length within 5 seconds) are applied automatically and imported; turn
that off in **Settings ▸ General ▸ MusicBrainz** if you'd rather check every one. The rest wait on the **Import** page
(its badge in the sidebar counts them):

- The queue lists every file with its status. Select one to see its details and its **Matches**: candidate releases
  with title, artist, album, year, type and score.
- Edit the **Title**, **Artist** and **Album** fields and press **Search** to look again, or **Fingerprint** to ask
  AcoustID.
- Pick the right match and **Import** (⌘↩). **Apply "…" to other queued items** uses the same album for the rest of an
  album's files.
- **Import All Ready** imports everything that has a match; **Clear Finished** tidies the list.

Before importing you can also correct any field (title, artists, album, year, track and disc numbers, genre, composer,
lyricist, record label, catalog number), and under **More details & credits** everything else MusicBrainz knows.

## What gets written

Each imported song gets:

- Clean tags: titles, artists and album artist, track and disc numbers, year, genre, record label, catalog number,
  barcode and MusicBrainz IDs.
- Credits: who played what, producers, engineers, mixers, writers and arrangers. These feed album pages, search
  (`credit:`) and [Music DNA](music-dna.md).
- Cover art from the [Cover Art Archive](https://coverartarchive.org), as `cover.jpg` in the album folder and embedded in
  the file (or your own image: **Choose Image…** or drop one on the cover).
- A tidy place: `Music/<Album Artist>/<Album> (<Year>)/<NN> - <Title>.<ext>`.

Tags are written to MP3, FLAC and M4A copies; WAV and AIFF are kept as they are.

## Your collection

When the files are the digital copy of something you own, the Import page's collection bar says so.

- **These files are the digital copy of**: pick a CD or record from your Physical Collection (the list shows this
  album's items first, then everything not digitized yet). For a record, choose **Digitized from this record** for a
  needle-drop you made elsewhere; for a CD, **Ripped from this CD**, or **Came with it as a download**.
- **Bought as Songs / Whole album**: for music you bought as files. Enter what you paid per song or for all of them;
  a whole album is saved as one download in **Downloads**, with its date and price, and counts in Insights' spending.

## Fixing things later

- **Get Info** (⌘I in song lists) shows a song's full details.
- **Change Cover…** on an album page finds another cover, or takes a file, a dragged web image or the clipboard. See
  [Albums and artists](albums-and-artists.md#covers).
- `is:unmatched` and `missing:cover` in [Search](search.md) find what still needs attention.
- **Remove from Digital Collection…** (album or song menus) moves the files to the Trash. Items in your Physical
  Collection stay, marked not ripped.
