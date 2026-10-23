# Changelog

What's new in each release. Add user-visible changes under **Unreleased** as they land; when tagging a release, rename
that heading to the version (for example `## 1.9.0`) and start a new, empty **Unreleased**. The release workflow puts the
section for the tagged version at the top of the GitHub release notes (or **Unreleased**, if there's no section for it).
Releases before 1.8.0 are described on the [Releases page](https://github.com/davidlago/music-library/releases).

## Unreleased

## 1.23.2

- On the Mac, the app no longer crashes on macOS 27 when it opens with the queue showing, or when you show the queue.
  The queue is now a fixed-width pane at the right of the window.

## 1.23.1

- On the Mac, seeking in a FLAC file (by dragging the scrubber, or by resuming a song where you left off) now lands
  where the clock says. Before, songs such as digitized records could play on past their length.
- **Digitize Vinyl** no longer cuts a recording into tracks for you. **Detect Tracks** is gone, along with the cuts it
  made when you stopped recording: it could split a long track at a soft passage. You make the cuts yourself with
  **Split at Playhead** and by dragging their edges, also while you record: click the waveform where a song starts and
  split there (the last track grows with the recording), and pick each track's song as you go.

## 1.23.0

- **Digitize your records.** A new **Digitize Vinyl** page under Import records a record you own (add it to your
  Physical Collection first; the page points you there) from the input you choose, at the sample rate and bit depth
  you choose (up to 24-bit / 192 kHz), with a level meter. **Listen** plays the input through your speakers or
  headphones while you check levels or record, without changing what's recorded. Record continuously, pausing to turn
  the record over, then cut the recording into tracks on its waveform: **Detect Tracks** finds the songs from the gaps
  and names them from the record's MusicBrainz track list, and you can listen from any point, drag a track's start and
  end, split and delete. **Save** adds them to your digital collection as lossless FLAC, tagged and filed like a ripped
  CD, and marks the record digitized. You can save a few tracks at a time; the recording is kept, even after quitting,
  until you discard it. A record's page has **Digitize…** (or **Digitize the Rest…**), and its … menu and the Shelf's
  context menu have **Digitize This Record…**. The first recording asks for permission to use the microphone (the
  input).
- **The iPhone app now runs on iOS 26**, not only iOS 27.

## 1.22.0

- **CDs MusicBrainz doesn't know can be ripped as you name them.** When macOS has names for a disc (the ones Finder
  shows, from its CD-Text or Gracenote), its page lists the song titles instead of "Track 1, Track 2…" and fills in
  the album and artist (a disc named "Placido Domingo Popular Favorites" becomes Popular Favorites by Plácido Domingo,
  using the artists in your collections or MusicBrainz). Fix any of them on the page (click a song title to change
  it), pick a cover with **Choose Cover…** (covers found on the Cover Art Archive, a file, the clipboard, or an image
  dropped on it, also from a web page), and **Rip** puts the songs straight into your digital collection with those
  names and that cover. The disc can also go in your physical collection: its page asks whether it's yours, with its
  label, purchase date and price, and **Catalog Without Ripping** works. **Rip to Import Queue** is still there, and
  now names and tags each file with its title.
- **A new look for Listening in Insights**, on the Mac and the iPhone, inspired by Last.fm's listening reports. A
  banner shows the period's plays over a blurred photo of your top artist, with each day's plays next to the same span
  before and how much more or less you listened. **Top Charts** puts your #1 artist, album and song up big with their
  photo or cover (each panel takes its color from the picture), followed by the next four, ranked by plays or time.
  **New to You** shows how many of the artists, albums and songs you played were new, with the top one of each. A
  **Listening Clock** dial shows your busiest hour and day, **Music by Decade** your favorite decade's top album, and
  **Quick Facts** compare listening time, plays a day, your most active day and days with music with the span
  before. Artists and albums open their pages.

## 1.21.0

- **Clearer names: Digital Collection, Physical Collection and Local Library.** What used to be "Library" is now your
  **Digital Collection**: your music files (Songs and Albums), including the albums you bought as downloads.
  Your **Physical Collection** is the CDs and records you own: **Shelf**, **CDs**, **Vinyl** and **To Digitize**.
  **Downloads** moved to the digital side (the Mac sidebar's Digital Collection section and the iPhone's Digital tab),
  and the Shelf now holds only CDs and records; downloads still show in Your Copies on album pages and in the spending
  of Insights. The public library catalog is now **Local Library CDs**, in the sidebar's **Local Library** section and
  **Settings ▸ Local Library**. In Insights, the panes are **Owned** (CDs, records and downloads), **Digital
  Collection** and **Listening**. On the iPhone, the tabs are **Physical** and **Digital** (with Insights, Sync and
  Search).
- **Explore: Artists from both collections.** On the Mac, **Artists** moved to the sidebar's **Explore** section, with
  **Insights**, **Music DNA** and **Concerts**, and now lists the artists of both collections: someone you only own on
  CD or vinyl is there too ("2 albums you own"), and their page shows what's in your physical collection. On the
  iPhone, **Insights** opens with an **Explore** section: **Artists** (everyone in both collections) and **Music DNA**.
- **Music DNA across both collections.** CDs and records with no digital copy add their songs to Music DNA from their
  MusicBrainz credits (now kept with each album's info), so a player you only have on vinyl links to the same people
  as your music files; their songs are listed by the copy they're on.
- **Covers reach the digital album.** A new cover for a CD or record whose music is in your digital collection can go
  to that album too (its `cover.jpg` and, optionally, the art embedded in its files, as on the album page), and a cover
  changed on an album page reaches the copies its songs came from.
- **Your Physical Collection: CDs and vinyl.** Music Library now catalogs every CD and record you own, whether or not
  it's in your digital collection: CDs you've ripped and ones you haven't, and records (usually never digitized), plus
  the albums you bought as downloads. A new **Physical Collection** section at the top of the Mac sidebar (**Shelf**,
  **CDs**, **Vinyl** and **To Digitize**) shows them as jewel cases and record sleeves or as a list, sorted by label,
  artist, title, year, purchase or date added, and the app opens there once you own a CD or record; downloads are
  under **Downloads** in the Digital Collection section. Each item has its own page: the edition, your copy's details
  (edited in place), its digital copy (ripped, partly ripped, not ripped yet, from another copy or no longer in your
  digital collection, with **Rip Now**, **Import a Transfer…** or **Link Digital Copy…**), the track list (a record's
  with its sides), other copies of the album, and **Previous/Next on Shelf** (⌘[ and ⌘]). See [Your physical
  collection](https://github.com/davidlago/music-library#your-physical-collection).
- **Label numbers per medium.** CDs and vinyl each have their own label series, both starting at 1: the number is on a
  white strip across the top of the jewel case's hinge or down the same edge of the record's sleeve, showing just the
  number: the case or sleeve under it tells CD #12 from Vinyl #12, and labels in text are always written with their
  series. Hover a cover's sticker or badge on the Mac, or press and hold it on the iPhone, for what it means. The
  next number is suggested, a number already used in the same series is refused (with the next and the first free
  numbers offered), and **Label Check** lists free numbers and duplicates.
- **Find by Label** (⌘L on the Mac, the Physical tab on the iPhone, the Physical page on the Apple Watch, and Siri:
  "Find CD 12 in Music Library") tells you what's at a label and what sits on either side of it on the shelf. The
  watch finds labels even away from the iPhone, and gets its index of your labels as soon as you open it with the
  iPhone nearby (a large collection's still comes as a file transfer, which can take longer), so Find works right
  away.
- **Adding to your physical collection.** **Add to Physical Collection…** (⇧⌘N) finds the edition on MusicBrainz by
  the barcode on the case (a USB barcode scanner works), a few words of the album and artist, or the catalog number,
  for a CD, a record or a download, with **Add & Next** for a stack of them; anything MusicBrainz doesn't list can be
  entered by hand. Albums in your digital collection can be added from their page (**Your Copies ▸ Add a Copy**), the
  Albums grid, or in bulk with **Physical Collection ▸ Add Albums You Own…**.
- **Unripped CDs and Catalog Without Ripping.** Inserting a CD says which item in your physical collection it is, or
  adds it with the next label (Settings ▸ Physical Collection can make it ask instead); the rip is linked to it when
  its first track is imported. **Catalog Without Ripping** adds the CD with its cover and ejects it. The Import page
  can mark files as the digital copy of a record (a needle-drop) or CD, and save songs you bought as one album
  download. Removing an album from your digital collection keeps its items, with their covers, marked not ripped.
- **Search what you own.** New search keys: `own:` (cd, vinyl, download, physical, any, none), `ripped:` (yes, no,
  partial, missing, other), `sticker:` (label numbers, like `sticker:cd100-199`), `bought:`, `paid:`, `copies:`,
  `barcode:` and `catno:`, plus `#12`, `cd#12` and `vinyl#12` in search boxes. Typing a label shows the item above the
  results, and a **What You Own** strip lists the matching items. In Local Library CDs, `own:` means you own it (on
  CD, vinyl or as a download), while `is:owned` keeps meaning in your digital collection.
- **The Owned pane in Insights** (on the Mac and the iPhone) now covers everything you own: how much is digitized,
  your label series with free numbers and duplicates, how you own your music by medium, spending by medium over time,
  cost per play and per hour, best value, what's still in the wrapper, artists, genres, decades, and record labels and
  countries.
- **Your Copies on album pages.** Album pages list every copy you own, with what the album has cost you per play, and
  their covers show the CD's case, the record's sleeve or the download badge. The Albums grid's Owned switch is now a
  **Owned** menu (All Albums, Albums You Own, Albums You Don't Own). Local Library CDs and Shop for CDs say when a CD
  is already in your physical collection ("In your physical collection: CD #142") and have **I Own This**.
- **The physical collection on the iPhone.** A new first tab, **Physical**, has Find by Label, your CDs, vinyl and
  what's left to digitize, item pages, and **Ready to Download** (with **Download All**) for digitized items whose
  songs aren't on the phone; your downloads are in the **Digital** tab. Items with no digital copy aren't dimmed and
  have no Download button. Everything you own and its covers always go to the phone, read-only (it's edited on the
  Mac), and the Mac's iPhone page has **Owned Music on iPhone**, per phone, to also put the digital copies of your
  CDs, your records or everything you own that's digitized on it.
- **The Physical Collection widget** (Recent Purchases before; widgets you placed keep working) shows the latest CD or
  record you added in its case or sleeve, how many CDs and records you have and how many CDs are left to rip, and your
  next labels, also on the lock screen and the watch face. The watch's **Physical** page replaces Purchases, with
  your counts ("34 CDs · 5 records"), what you added lately and Find.
- **"Record label"** is now the name of the company everywhere ("Label" was confusing next to label numbers); the
  `label:` search key keeps its meaning.
- **Upgrading keeps everything you filed.** The first time this version opens your library, every album you'd marked
  as owned becomes an item you own with its label number, purchase date and price (a CD on the Shelf, or a download),
  and albums you bought songs from show as downloads. Nothing in the library is removed or changed, and libraries made
  by every version since 1.14 are tested to migrate this way.
- **Albums marked as owned before 1.19 read as CDs.** Those versions didn't record whether you owned the CD or a
  download, so they come over as CDs; if one was a download, change its medium on the item's page.
- **iPhones with an older version** (1.14–1.20) keep showing the CDs and downloads of the albums in your digital
  collection (with CD labels from 1.18), but not your records, items with no music in your digital collection, or
  second copies; smart playlists that use the new search keys show empty there (or unfiltered, with a negated key like
  `-own:vinyl`). Update the iPhone app to see everything you own.
- **Going back to an older Mac version.** If you open the library with an older version after this one, what you
  change there to CDs and downloads is picked up when you open it with this version again, but deleting an album's
  copy there has to be done again here. That version doesn't see the label number of a second CD of the same album, so
  it can suggest or accept a number that's taken: **Label Check** finds the duplicate after updating again. An older
  Mac syncing a phone removes the items' own covers from it until the next sync from this version.

## 1.20.0

- **Shop for CDs.** A new **Shop for CDs** page in the sidebar finds the exact CD on MusicBrainz, by a few words of the album
  and artist, by an artist alone (to browse their albums), or by the barcode or catalog number on the case, and lists
  its CD editions (year, country, label, catalog number,
  barcode). Pick one, or any CD edition of the album, and the app gathers new and used copies that ship to the US from
  Discogs, eBay, CDandLP and Alibris: price, shipping, condition, seller and where it ships from, with a total in
  dollars, listed as this edition, other editions or possible matches. Links search Amazon, Walmart, Half Price Books and
  Barnes & Noble too. A CD MusicBrainz doesn't list yet (new, local or rare releases) can be searched for on the
  stores by name. Nothing needs an account or a sign-in. Album pages have **Shop for This CD** in their … menu.

## 1.19.0

- **Sort albums and songs on the iPhone.** The Albums grid has the Mac's orders (Date Added, Title, Artist, Release
  Year, Most Played, Recently Played) in its menu, with the same line under each album saying when it was added or
  played. Songs can be sorted by title, artist, album, composer, year, time, format or date added, either way round.
- **Label stickers on the hinge.** On the Mac and the iPhone, an album's label number now sits on a tall sticker across
  the top of the jewel case's hinge, where it goes on the real case, reading from bottom to top; covers shown without
  their case have it in the top-left corner.
- **CDs, downloads and borrowed CDs look different.** An album you own is now either a CD or a download (**Your Copy ›
  Format** on its page in the Mac app). A CD you bought has its label on the jewel case; one you borrowed (any album
  you don't own) has a round badge with two arrows, and a download a round dollar-sign badge, on the Mac and the
  iPhone.
- **Prices for imported songs.** The Import page has **Paid** and **Bought** fields for each song (still editable once
  it's imported), and a field for what you paid for all the songs in the list (a whole album, say), split evenly
  across them as you type; changing a song's price changes the total. An album you bought songs from counts as a
  download you own, even if only some of its songs: its page shows it owned since the first song, for their total, and
  so does Insights. **Import** is now ⌘Return, so Return in a text field doesn't import.
- **How you own your music, in Insights.** The Owned pane, on the Mac and the iPhone, shows your albums as CDs,
  downloads and borrowed, with what each cost, how many CDs are labeled and how many downloads are only some of an
  album's songs; **Your Albums** marks the downloads.
- **Newest first on the iPhone page.** The Mac app's iPhone list shows what you added most recently at the top.
- **Removed CDs leave the iPhone page.** Albums, artists and songs that are no longer in the Mac's library drop off its
  iPhone list, so a CD removed on the iPhone no longer lingers there with no songs when it had left the library first.

## 1.18.0

- **Label numbers for your CDs.** When you say you own an album in the Mac app (on its page, or when ripping a CD),
  give it the number on the sticker you put on the case, so you can find it on the shelf later. The next number in
  your series is filled in for you, a number already used on another album is pointed out, and
  **Insights › Owned › Your Albums** lists them **By Label**.
- **Covers in jewel cases.** Album pages and the Albums grid, on the Mac and the iPhone, show each cover as a CD in
  its jewel case: the ribbed hinge, the black tray, the tabs and the shine on the clear lid.
- **Show only the CDs you own.** The Albums page has an **All Albums / Owned** switch on the Mac, and a filter
  menu on the iPhone.
- **Label stickers instead of the Owned badge.** The little disc on owned albums' covers is gone; an album with a
  label number shows it on a small white sticker in the corner instead.
- **Your Copy is read-only on the iPhone.** The album page shows the label number, purchase date and price, so you can
  find the CD at home, but ownership is now edited only in the Mac app.
- **Faster AccurateRip checks of an album.** Checking an album from its page stops as soon as one CD's listing
  matches every track, no longer keeps the whole album's audio in memory, and shows which track it's on (and which
  pressing, when several could be the CD you ripped), with **Cancel**. An album whose tracks all passed already isn't
  checked again: the menu says **AccurateRip: All Tracks Accurate**.

## 1.17.0

- **The iPhone app is on the App Store**, free, as
  [Dave's Music Library](https://apps.apple.com/us/app/daves-music-library/id6822005512). The README and the
  [website](https://davidlago.github.io/music-library/) link to it.
- **Check rips with AccurateRip.** After ripping a CD, every track is compared with other people's rips of the same CD
  in [AccurateRip](https://www.accuraterip.com). A track that isn't bit for bit the same as theirs was misread: a
  scratch or smudge the drive didn't report, which you'd otherwise only notice as a skip or glitch while listening.
  It's marked **Misread** on the CD page and with a red mark on the album page (hover over it for what it means), and
  the disc isn't ejected while a track is misread. Pressings with the audio slightly earlier or later than the one in
  AccurateRip are recognized too.
- **Rip Again** fixes a misread track while the disc is in: it reads the track up to 5 times and combines the reads
  sample by sample, and when the majority still gets a damaged spot wrong, it tries the versions of each spot the reads
  gave until AccurateRip confirms one. The file is replaced only once AccurateRip confirms it, keeping the song's plays,
  likes and playlists, and Rip Again can be tried again. Ripping a track that's already in the library from the CD page
  works the same way, instead of adding a second copy.
- **Check albums you ripped before**, without the disc: **Check with AccurateRip** in the **…** menu of an album page
  finds the CD they were ripped from among the ones MusicBrainz lists for the album.
- **Remove songs and albums from the library anywhere.** **Remove from Library…** is now in the context menu of songs
  on album and artist pages and in playlists, of albums in the Albums grid, search results and artist pages, and in the
  **…** menu on an album page, not only in song lists. The files go to the Trash (with album and artist folders left
  with nothing but a cover), so a defective song or album can be ripped again. A removed song also leaves the play
  queue; if it was playing, the next song plays.
- **iPhone: Play starts the first time.** Playing an album or song at a different sample rate from the last one no
  longer stops right away until Play is tapped again: switching the output's rate was taken for an interruption.

## 1.16.0

- **Try the iPhone app without a Mac.** **Explore a Sample Library** on the empty Library tab opens a sample library
  built into the app: fictional artists and albums, with songs synthesized for it and covers drawn for it, listening
  history, likes and owned albums, so every page, Insights, Music DNA, the widgets and the Apple Watch app can be tried.
  Nothing done in it goes to the Mac or Last.fm, and your own library replaces it after your first sync (or hide it from
  the Library tab or Settings).
- The website has a [privacy policy](https://davidlago.github.io/music-library/privacy.html) and a
  [support page](https://davidlago.github.io/music-library/support.html).

## 1.15.0

- **Owned albums stand out.** Albums you've marked as owned show a small disc badge in the corner of their cover in
  the album grids: Albums, artist pages and search results on the Mac, and Albums and artist pages on the iPhone.
- **Counts at a glance.** The Mac sidebar shows how many songs, albums and artists the library has. The iPhone's
  Library tab shows counts for Artists, Albums, Songs and Liked Songs, counting only what's on the iPhone when
  **On This iPhone** is chosen.

## 1.14.0

This release changes how releases are made; the Mac and iPhone apps work as in 1.13.0.

- Every release now also goes to TestFlight automatically, as the same version as the Mac app.

## 1.13.0

- **The Mac app is notarized and needs nothing else.** Releases are signed with a Developer ID certificate and notarized
  by Apple, so the app opens like any other: no more **Open Anyway** in Privacy & Security. It includes its own ffmpeg,
  ffprobe and fpcalc, so Homebrew's ffmpeg and chromaprint aren't needed anymore, and AcoustID fingerprinting works with
  just an API key. **Settings ▸ General ▸ Tools** shows "Included with the app". After updating, macOS asks once more to
  allow keychain access; choose **Always Allow**.
- **The iPhone app is on TestFlight** for invited testers; see the
  [iPhone app](https://github.com/davidlago/music-library#iphone-app) section of the README. Building it with Xcode still
  works.
- When a sync doesn't fit on the iPhone, the iPhone now stops it, before deleting or copying anything, and says how much
  space it needs; it no longer tells the Mac how much space it has free.

## 1.12.0

This release is for the iPhone app; the Mac app is unchanged, and syncing works as in 1.11.0. Rebuild the iPhone app from
Xcode to get it (see the [iPhone app](https://github.com/davidlago/music-library#iphone-app) section of the README).

- **iPhone widgets.** Listening (time listened in the past 7 or 30 days, a bar per day, your streak and top artists,
  songs and albums), Now Playing (with play/pause, previous, next and like buttons that work without opening the app),
  Recent Purchases (what you bought lately and spent this year), Rediscover (favorites you haven't played in months, with
  Play) and Library (its size, how much is on the phone, what was added last). Listening and Now Playing are on the lock
  screen too. Tapping one opens its album, Now Playing or Insights.
- **An Apple Watch app.** A remote for the iPhone's player (play/pause, skip, like, and starting Liked Songs, a shuffle or
  an album), your listening and purchases, and complications for listening time, the song playing and this year's
  purchases. It installs with the iPhone app and needs watchOS 26 or later.
  [Screenshots](https://github.com/davidlago/music-library#widgets-and-apple-watch).
- The iPhone app's icon no longer has a white frame around it.
- To use your own bundle identifier for the iPhone app, set `APP_BUNDLE_ID` (not `PRODUCT_BUNDLE_IDENTIFIER`) in
  `iOS/Local.xcconfig`; the widgets, watch app and app group are named after it.

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
