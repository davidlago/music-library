# Search

The search field at the top right of the window searches your whole library: songs, albums, artists and what you own.
Plain words match titles, artists, albums, genres, composers, record labels and credits; filters narrow things down.
The same language works in the Shelf's filter, on the iPhone, in [Local Library CDs](local-library.md) and in smart
playlists.

![Search results for genre:jazz year:1950-1975: What You Own (Birth of the Cool on CD, The Big Reunion and The Köln Concert on vinyl), artists and albums, and the matching songs](../screenshots/search.png)

## Results

- **Top hits** first: the artists and albums that match best.
- **What You Own**: the CDs, records and downloads that match, in their cases and sleeves.
- **Songs**, in a table you can sort.
- **Refine** menus (Genre, Decade, Quality, Added, Owned, Missing) add a filter with one click.
- Typing a label on its own (`#142`, `cd 142`, `vinyl 12`) shows that item above the results.

As you type, the field completes filter names and values (genres, artists, labels) from your library, and corrects
typos ("Did you mean…"). **?** next to the results shows the full reference; **Play** and **Shuffle** play the songs
found; **Save as Smart Playlist** keeps the search.

## Filters

Write a filter as `key:value`. Quote values with spaces: `credit:"rudy van gelder"`.

### Text

| Filter | Matches | Example |
|---|---|---|
| `artist:` (`by:`) | Track or album artist | `artist:"miles davis"` |
| `album:` (`release:`) | Album title | `album:blue` |
| `title:` (`song:`) | Song title | `title:love` |
| `genre:` (`style:`) | Genre tag | `genre:jazz` |
| `mbgenre:` (`tag:`) | MusicBrainz community genres (broad and noisy) | `mbgenre:"hard bop"` |
| `composer:` (`writer:`) | Composer, writer or lyricist | `composer:ellington` |
| `credit:` (`person:`, `producer:`, `performer:`) | Anyone credited: players, producers, engineers… | `credit:"teo macero"` |
| `label:` | Record label | `label:"blue note"` |
| `albumartist:` (`aa:`) | Album artist only | `albumartist:"various artists"` |
| `country:` | Release country code | `country:gb` |
| `work:` | Musical work | `work:"so what"` |
| `format:` (`codec:`) | File format or codec | `format:flac` |

### Numbers and ranges

Numbers take a value, a range (`1990-1999`) or a comparison (`>`, `>=`, `<`, `<=`).

| Filter | Matches | Example |
|---|---|---|
| `year:` | Release year | `year:1990-1999` |
| `decade:` | Release decade | `decade:60s` |
| `time:` | Track length (m, s or m:ss) | `time:>10m` |
| `added:` | Added within a span (d, w, m, y) or in a year | `added:30d`, `added:>1y`, `added:2025` |
| `rate:` | Sample rate in kHz | `rate:>=96` |
| `bits:` | Bit depth | `bits:24` |
| `bitrate:` | Bitrate in kbps | `bitrate:<256` |
| `track:`, `disc:` | Track or disc number | `disc:2` |

### Flags and gaps

| Filter | Values |
|---|---|
| `is:` | `lossless`, `lossy`, `hires`, `compilation`, `live`, `matched`, `unmatched` |
| `missing:` (`no:`) | `year`, `genre`, `composer`, `album`, `artist`, `label`, `mbid`, `credits`, `cover` |
| `has:` | The same values, the opposite way: `has:credits` |

### Logic

| Write | To |
|---|---|
| `-live`, `-is:compilation` | Exclude |
| `"exact phrase"` | Match words together |
| `a OR b` | Match either |

Everything else is combined: `genre:jazz decade:50s -is:live` is jazz from the fifties that isn't live.

## Collection keys

These filter by what you own. They work in search boxes, on the Shelf and Downloads, and in smart playlists; on songs,
they keep the songs of the matching albums (`own:vinyl genre:jazz` lists the songs of your jazz records).

| Filter | Values and examples |
|---|---|
| `own:` (`medium:`) | `cd`, `vinyl` (or `lp`, `record`), `download`, `physical`, `any`; `own:none` = albums in your digital collection you don't own |
| `ripped:` | `yes`, `no`, `partial`, `missing` (the music was removed), `other` (from another copy) |
| `sticker:` | `sticker:12` (either series), `sticker:cd100-199`, `sticker:vinyl>=50`, `sticker:none` |
| `#12`, `cd#12`, `vinyl#12` | A label number, in a search box |
| `bought:` | `bought:2024`, `bought:90d` (in the last 90 days) |
| `paid:` | `paid:>20`, `paid:none` |
| `copies:` | `copies:>1` (albums you own more than once) |
| `barcode:`, `catno:` | `barcode:886976389413`, `catno:"cl 1355"` |

`label:` always means the record label in the tags; label numbers are `sticker:`.

## Smart playlists

**Save as Smart Playlist** (or **+** next to Smart Playlists in the sidebar) keeps a search as a playlist that updates
itself as your library changes: `added:30d` for what's new, `is:hires -is:live`, `credit:"jeff lynne"`, `own:vinyl
ripped:yes`. **Edit…** in its context menu changes the query. Smart playlists sync to the iPhone like any playlist.

(iPhone app versions before 1.21 show a smart playlist that uses collection keys as empty.)

## Examples

| Search | Finds |
|---|---|
| `genre:jazz year:1955-1965 is:hires` | Hi-res jazz from the golden decade |
| `credit:"rudy van gelder"` | Everything he engineered |
| `added:30d -is:live` | Studio recordings added this month |
| `missing:cover` | Albums that still need a cover |
| `own:cd ripped:no bought:2024` | CDs bought in 2024 you haven't ripped |
| `own:none decade:80s` | Eighties albums in your files you don't own on any medium |
| `sticker:cd100-199` | Your CDs labeled 100 to 199 |
| `time:>10m is:lossless` | Long tracks in lossless formats |
