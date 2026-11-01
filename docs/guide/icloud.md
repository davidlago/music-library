# iCloud backup

Music Library can back up your library to your own iCloud: the library database, the covers and artist photos, and, if
you choose, your music. Your iPhone can then get the library and your music from there, so it stays up to date and can
download songs when your Mac isn't nearby.

You need Music Library for Mac and the iPhone app from the releases that include iCloud, both signed in to the same
Apple Account in iCloud, and room on your iCloud plan for what you back up. Builds you make yourself need iCloud set up
for signing; see [Building from source](building-from-source.md).

## Turn it on

In the Mac app, open **Settings ▸ iCloud** and choose what to back up:

| Choice | What goes to iCloud |
|---|---|
| **Off** | Nothing (the default). |
| **Library and covers** | The library database (your songs' details, plays, likes, playlists and your physical collection), album and collection covers, and artist photos. Usually tens of MB. |
| **Library, covers and chosen music** | The same, plus the music you choose. |
| **Everything** | The same, plus every song's file. Check that your iCloud plan has room. |

The tab shows the size each choice comes to, and the app asks before backing up for the first time or backing up more
music than before.

## Choose the music

With **Library, covers and chosen music**, use **Add to iCloud** in the menu of any album, artist, playlist or song (it
sits next to **Add to iPhone**). Once something is in, the menu offers **Remove from iCloud**. An artist or playlist
keeps up to date: an album you add later by that artist is backed up too.

Switching from **Everything** to chosen music starts the list with your **Entire Digital Collection**, so nothing
already in iCloud is let go: take out what you don't want with **Remove from iCloud**, or delete that rule on the iCloud
page and add albums one by one.

The **iCloud** page, under **Devices** in the sidebar, lists what you chose and what you kept out, how many songs and how
much space they come to, and the backup's status, with **Back Up Now**.

**Include what's on my iPhone** (off by default) also backs up the music picked for your paired iPhones, so the phone
can download it from iCloud when the Mac isn't around. Settings shows what that list comes to first: with **Owned Music
on iPhone** turned on it can be most of your library.

## When it backs up

The backup runs by itself two minutes after your library changes, at most every 15 minutes, and whenever you click
**Back Up Now** (in **Settings ▸ iCloud** and on the iCloud page). The status shows the last backup, what's still
uploading, and any problem, such as iCloud being full or being signed out.

A first backup of a lot of music takes a while. It goes on in the background, half an hour at a time, and the status
shows how many files are still to go. Your music doesn't take twice the space on the Mac: each song is copied without
using extra space on the same disk, and the copy waiting for iCloud is cleared as soon as it's uploaded. Your library's
own files are never touched.

## What's kept

- **The database** is kept in several copies: the last 10, one a day for two weeks and one a week for two months. Each is
  a few MB, so the history costs little.
- **Music, covers and photos** are kept once each and replaced when they change. There's no history of the music
  itself.
- **Music you take out of the backup** (or remove from the library) stays in iCloud for 30 days, then it's deleted.
  Choosing it again before then keeps it. The status shows what's **Waiting to be deleted**; to free that iCloud space
  sooner, click **Delete Now…** next to it (in **Settings ▸ iCloud** or on the iCloud page). That can't be undone from
  the backup.

## Offload music from the Mac

With **Everything** backed up (or chosen music covering what you'd offload), iCloud can hold your music and the Mac keep
only what you play. An offloaded song stays in your library, with its plays, likes, playlists and copies in your
collection; only its file leaves the Mac, and only once the backup holds the same file. Its cover gets a badge in the
corner, a cloud struck through like the one for music not digitized yet (on albums, and on CDs and records whose music
it is), songs show the same cloud next to their title, and the album page says which songs are in iCloud only.

- **By hand:** **Offload from This Mac** in the menu of an album, artist, playlist or song. **Download to This Mac**
  brings it back for good.
- **Automatically:** **Settings ▸ iCloud ▸ Offload music not played in** (Off, 1 month, 3 months, 6 months or 1 year).
  After a backup, at most once a day, albums whose songs weren't played, added or downloaded back in that time leave
  the Mac. **Offload Now…** runs it at once and first shows what it frees. Mark albums, artists, playlists or songs
  **Keep on This Mac** to keep them here whatever the setting; what's playing or queued always stays.
- **Playing an offloaded song** downloads it first (the player says **Downloading from iCloud…**), and the next song in
  the queue is fetched ahead. One that can't be downloaded (offline, say) is skipped. Exporting, writing a new cover
  into the files and checking a rip download the songs first too.
- **Insights** splits the size of your music into what's on this Mac and what's in iCloud only.

Once a song is offloaded, **its only copy is in iCloud**, so a few rules keep it safe:

- Offloaded songs stay in the backup whatever it's set to back up; they're never waiting to be deleted, and **Delete
  Now…** doesn't touch them.
- Backing up less (or turning backup off) while songs are offloaded asks whether to download them to this Mac first or
  keep them in iCloud.
- **Replace It…** (another library's backup) isn't offered while songs are offloaded, and restoring the database keeps
  them offloaded.
- Removing an offloaded song from the library deletes its iCloud copy 30 days later, like any song taken out of the
  backup; the confirmation says it's the only copy.
- Export your music to a drive now and then (**Export List**) to keep a second copy.
- Versions before 1.31.0 don't know about offloaded songs: they'd see the files missing and let them go from iCloud 30
  days later. Before going back to an older version, bring them back with **Settings ▸ iCloud ▸ Download All to This
  Mac**.

The iPhone gets offloaded songs straight from iCloud: a Wi-Fi sync sends what's on the Mac, and the phone downloads
the rest of what it should have from iCloud right after.

## A new Mac

On a Mac whose library is empty, the **Songs** page (and **Settings ▸ iCloud**) offers **Set Up from iCloud…** when
iCloud holds a library. **Move to This Mac** brings down the database, covers and artist photos; every song starts
offloaded and downloads when you play it (or with **Download to This Mac** on what you choose). The new Mac backs the
library up from then on. At its next backup, the old Mac says the backup moved and offers **Back Up from Here
Instead…** or **Stop Backing Up**, so the two never overwrite each other.

## Restore

**File ▸ Restore from iCloud…** (also in **Settings ▸ iCloud**) lists the database copies, newest first, with how many
songs, CDs and records, plays and likes each holds. Pick one, then:

- **Restore to New Folder…** puts the library as it was then into an empty folder you choose: the database, and the
  songs, covers and photos it names that the backup holds (songs that weren't backed up show as missing). Your current
  library isn't touched. When it's done, **Open Restored Library** switches to it.
- **Restore Database Only…** puts that copy's database in place of the open library's, keeping your music files. The
  database from before is kept in the library folder as `library-before-restore-…sqlite`, so you can go back.

**Use a Backup Folder…** restores from a copy of the backup made by hand, for example on another disk.

## On the iPhone

**Settings ▸ iCloud ▸ Use iCloud** is on by default. While the app is open, it checks your Mac's backup when you open
it and every couple of minutes:

- **Your library comes from iCloud.** The database, covers and artist photos stay up to date without the Mac nearby,
  and an iPhone with no library yet gets one without pairing: its first screen says it's looking in iCloud and shows
  the covers arriving. A newer copy from a Wi-Fi sync is never replaced by an
  older one from iCloud. Settings shows when the library was last updated from iCloud and which backup it came from,
  with **Check Now**.
- **Download picks the way.** With your Mac on the same Wi-Fi and Music Library open, Download works as it always has.
  Otherwise the songs come from your Mac's iCloud backup, if they're in it ("Downloading from iCloud"). Songs that
  aren't say **Not in iCloud yet** and download from the Mac when it's around. Downloaded songs play offline, and each
  takes its space on the phone once.
- **Your plays, likes and requests go back.** A few seconds after you like a song, play one or tap Download or Remove,
  the phone sends it to your Mac through iCloud. The Mac picks it up within a minute while Music Library is open, and
  its **iPhone** page shows when each phone last sent something this way.

The keys and settings your Mac hands over (the Radio DJ's key, Last.fm and concerts) still come over a Wi-Fi sync only;
they never go to iCloud.

## Where the backup is

The backup lives in Music Library's own private folder in your iCloud. It doesn't show in iCloud Drive (in Finder, the
Files app or on iCloud.com), so nothing in it can be moved or deleted by hand. You can see the space it takes in
**System Settings ▸ your name ▸ iCloud** on the Mac (or **Settings ▸ your name ▸ iCloud** on the iPhone). Turning the
backup off stops it; deleting Music Library's data there removes it.

One iCloud holds one library's backup. If another Mac (or another library folder) tries to back up there, its settings
say so and offer **Replace It…** or **Turn Off Backup**.

The backup is yours: it's stored by Apple in your iCloud, and the developer can't see it. With Advanced Data Protection
turned on in your iCloud settings, it's end-to-end encrypted. See [Privacy](privacy.md).
