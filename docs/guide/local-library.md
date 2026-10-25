# Local Library CDs

Public libraries lend CDs, and your next favorite album might be on their shelf. **Local Library CDs** downloads the
music CD catalog of your public library network, matches every CD on MusicBrainz, and lets you search it like your
own music: what's on the shelf right now, what you already own, and what you haven't heard.

It works with library catalogs run on [Aspen Discovery](https://aspendiscovery.org), like the
[Minuteman Library Network](https://www.minlib.net) in Massachusetts (the default).

![Local Library CDs: the downloaded catalog searched for genre:jazz, with genre and decade chips, covers and On Shelf at Natick](../screenshots/library-cds.png)

## Set it up

Open **Settings ▸ Local Library**:

- **Website**: your catalog's address (`https://natick.minlib.net` by default).
- **My local library**: your branch, selected when browsing, listed first in availability and offered for "Available
  now at".
- **Account** (optional): your library card number or username and PIN or password, to see your checkouts and to add
  CDs to one of your library lists (**List for Music Library**). The password is kept in your keychain and sent only to
  the catalog's website.
- **Downloaded catalogs**: the libraries whose CDs are downloaded. Your library is added the first time you open Local
  Library CDs; **Add a Library…** adds more.
- **Album details**: **Look up track lists, covers and info on MusicBrainz as CDs load** (on by default).

## The download

The first time you open **Local Library CDs**, every CD your library owns is downloaded page by page, about a quarter of
an hour for a couple of thousand. Then each CD is looked up on MusicBrainz in the background by its barcode (or title
and artist), a few seconds each, the first time only. The catalog's website and MusicBrainz both ask apps to go easy, so
the app takes its time, waits when the site asks for a break, and resumes an interrupted download where it stopped.

The download is refreshed when it's more than 12 hours old (at launch and when you open the page), for new titles and
current availability. **Update Now** and **Look Up Missing Album Details** are in Settings.

## Browsing and searching

Filter by library, availability (On the shelf, Available now at…) and ownership (In Digital Collection or Not), sort by best
match, recently added, artist, title, newest or oldest release, or rating, and search with the same language as your music, plus catalog meanings:

| Filter | Means |
|---|---|
| `title:"so what"` | A song on the CD |
| `time:>60m`, `disc:2` | Album length, number of discs |
| `added:30d` | New in the catalog (since your first download) |
| `is:owned`, `-is:owned` | Already in your digital collection, or not |
| `own:any`, `own:vinyl`, `own:none` | Owned by you (on CD, vinyl or as a download), or not |
| `is:available`, `is:out` | On the shelf at your library right now, or not |
| `is:onlist` | On the library list you chose in Settings |
| `library:acton`, `rating:>=4` | Owned by a library; MusicBrainz community rating |

`is:owned` is about your digital collection, `own:` about what you own: a CD you own but haven't ripped is
`own:cd -is:owned`. Try `genre:jazz decade:60s -is:owned is:available`.

**Search the Whole Network Live** (in the library menu) searches every library on the catalog's website instead of the
download.

## A CD's page

![A local library CD's page for Black Radio III: cover and details from MusicBrainz, Play Previews, its track list, and where to find it across the network](../screenshots/library-cd.png)

- The cover, track list, year, record label, genres, rating and description from MusicBrainz.
- Whether it's in your digital collection or your physical collection, even when the catalog spells it differently, and
  **I Own This…** to add it to your Physical Collection.
- **Where to Find It**: every library that owns it, with the call number and how many copies are in.
- **Play Previews**: 30-second previews of its songs from Apple Music, one at a time or all in a row, with no account.
- **Open in Catalog**, and **Add to** your library list (named after it) when you've chosen one in Settings.

## Your account

With an account in Settings, **My Checkouts** lists what you have checked out (and which CDs you haven't ripped yet),
and your list (named in the sidebar) shows the CDs you saved for your next visit.
