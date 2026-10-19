# Physical collection redesign

Status: **implemented**, for release 1.21 (P0–P5 on the `claude/physical-collection` branch: Core, Mac, iPhone, watch
and widgets, docs, and the cleanup that removed the deprecated ownership APIs). Nothing bumps `Database.schemaVersion`
(14), `SyncProtocol.version` (3), `Glance.currentVersion` (1) or `GlanceShelf.currentVersion` (1). The sections below
are the plan as written, kept as the design record; where the implementation differs, §14 says how. The screenshots of
§11 are still to be taken from a real library window.

## 1. Goals

1. **Catalog what you own.** The main job of the app is cataloging the music you own: CDs (ripped or not), vinyl
   (usually not digitized) and album downloads. Each one can exist without any tracks in the library.
2. **Stickers per medium.** Every physical item can carry a label number. CDs and vinyl each have their own series,
   and both start at 1. CD #12 and Vinyl #12 are different items, and nothing on screen lets you mix them up.
3. **Browse, search, find and count.** You can browse the physical collection, search it, and see stats about it on
   the Mac, the iPhone, the watch and in widgets. "Find by label" tells you what CD #12 is and where it sits on the
   shelf, so you can go and grab it.
4. **Keep the digital side working.** The digitized versions (rips, needle-drops, downloads) stay in the Mac library.
   They link to the items they came from and sync to the phone as they do today. A per-phone setting can also put
   "everything digitized in my collection" on the phone.
5. **Nothing breaks for older versions.** Older phones (1.14–1.20), older watches, older Macs (after a downgrade),
   exports and saved smart playlists all keep working and keep showing correct data.

## 2. Decisions

Each decision has one answer and a short reason.

| # | Question | Decision | Why |
|---|---|---|---|
| D1 | Where items live | A new `collection_items` table, created on open, one row per thing you own. | `album_ownership` holds one row per album key and is read by name on old phones. |
| D2 | Identity | The item's `id` (a lowercased UUID). Rows migrated from `album_ownership` get the deterministic id `own-<FNV-1a-64 hex of the album key>`. Song-derived downloads get `songs-<hex>` and are never stored. | The Mac migration and a phone reading an older snapshot then produce the same ids, so routes and widget links stay valid. |
| D3 | Link to the music | One `album_key` per item, the `SearchIndex.albumKey` that its digital copy has or would have, plus `digital_source` (`rip`, `download`, `same`, or NULL meaning never linked). Digitization is always derived, never stored. | Covers several copies of one album and can tell "ripped from this copy" apart from "the same music came from elsewhere", without a many-to-many table. |
| D4 | When a rip links | `digital_source = rip` is set when the first ripped track is imported, not when ripping starts. | A cancelled rip leaves the item correctly marked "Not ripped". |
| D5 | Label series | Two fixed series, `cd` and `vinyl`, each 1…9,999,999. The next number is the highest in that series + 1. | This is what was asked for. Configurable prefixes add parsing surface for little gain. |
| D6 | How labels show | Text always includes the series: **"CD #12"** and **"Vinyl #12"** (VoiceOver: "CD label 12"). The physical sticker differs by series: CDs keep today's white strip across the jewel-case hinge; vinyl gets a round yellow dot on the sleeve's top-left. The UI word is **label**; the company is renamed **Record label** everywhere. In code the number is a `Sticker`, so `label:` keeps its search meaning. | Prevents CD #12 / Vinyl #12 confusion by text, shape and colour. |
| D7 | Duplicate labels | Saving a number already used by another item in the same series is refused, with "Use #58 (next)" and "Use #31 (first free)" offered. Duplicates that already exist (legacy data) can still be saved for other fields, and they're listed in Label Check. No UNIQUE index. | Existing `album_ownership` data may already hold duplicates, and a unique index would make `migrate()` throw. |
| D8 | Old readers | `album_ownership` becomes a projection the Mac writes. It holds only CDs and downloads, one row per album key, with the primary copy's own date, price and CD label. `format` is only ever NULL or `'digital'`; `label_number` only ever holds CD numbers. Vinyl and song-derived downloads are never projected. | 1.14–1.20 phones and older Macs then see true (if incomplete) data. A vinyl-only album reads as not owned, never as a fake CD. |
| D9 | Edits from older apps | Reconcile runs on every Mac open and in memory on the phone. A row that isn't what the projection wrote for its primary item (whatever its time) is copied into that item, as far as its writer knew the columns: `album_ownership` is remade once with defaults no app writes, so a column an older app left out can be told from one it cleared. A missing row never deletes an item. | Survives downgrade/upgrade cycles without silent data loss: a label cleared or a download made a CD on 1.18–1.20 stays so, and clocks that differ don't matter. |
| D10 | Legacy phone events (pre-1.18 `.purchase`) | Date and price only, newest wins, applied to the primary CD/download copy. A nil event deletes only an unlabeled primary copy. Vinyl is never touched. | A label is a fact only the Mac records. |
| D11 | Covers for trackless items | `Music/Collection Covers/<item id>-<8 hex>.jpg`, with a new name on each change. NULL means "use the linked album's `cover.jpg`". | Under `Music/`, so current phones' `SyncReceiver` accepts it with no protocol change. Each copy has its own file, and retagging can't leave it stale. |
| D12 | Removing an album from the library | Linked items with no cover of their own first adopt the album's `cover.jpg` (copied into Collection Covers). Their `digital_source` is cleared, so they read "Not ripped". | `LibraryPath.emptiedFolders` trashes folders that hold only `cover.jpg`. |
| D13 | Search keys | New keys under new names (`own:`, `ripped:`, `sticker:`, `bought:`, `paid:`, `copies:`, `barcode:`, `catno:`) plus `#12`/`cd#12`/`vinyl#12` shorthand. Nothing is added to `is:`, `missing:` or `has:`. Bare numbers stay text; label hits are shown alongside the results. | On old readers an unknown key reads as text and matches nothing, whereas an unknown `is:` value is dropped as an issue, and an empty query returns every track. |
| D14 | Unknown media (written by a newer Mac) | Read as `CollectionMedium.other(raw)`: shown with a generic glyph, no series, read-only, never projected. | Degrades instead of disappearing or turning into a CD. |
| D15 | Phone editing | None. The phone stays read-only. No new `SyncEvent` kinds. | Keeps the "edited on the Mac only" contract and keeps old Macs safe. |
| D16 | Glance compatibility | `Glance.Owned` keeps its exact meaning: `ownedCount`, `libraryAlbumCount` and `recent` cover library albums with tracks only, one entry per album key. The spend and "bought" totals cover the whole collection. New data goes in an optional `Glance.collection`. | Older watches and widgets never show a vinyl as "Download it there", and never show more than 100 % of the library as owned. |
| D17 | Find by label on the watch | A `shelf.json` index (at most 2 MB) sent with `WCSession.transferFile`, stored under a fixed name. Covers are fetched lazily and kept in a bounded cache. | The application context is limited to about 64 KB. |
| D18 | Collection on the phone | Every item and every item cover always reach the phone (in the snapshot). Digital copies follow the selection, plus a per-phone **Collection on iPhone** scope (Off / Digitized CDs / Digitized vinyl / Everything digitized). The scope is applied as implicit include rules placed before the user's rules. | Excludes such as Remove from iPhone still win, and new rips join on the next sync. |
| D19 | Front door | The Mac sidebar opens on **Collection ▸ Shelf**, and the iPhone opens on a new first tab, **Collection**, whenever the collection isn't empty. | This is the app's main purpose. |
| D20 | Song-derived downloads | A derived download (from `TrackPurchase`s) can sit beside a CD or vinyl item of the same album. It is read-only and offers "Make It an Album Download". | Both represent real money spent. |
| D21 | Tracklists for trackless items | Taken from `album_info` (keyed by album key), fetched with the item's own release IDs. `TracklistEntry` gains `position` ("A1"), so vinyl sides show. | Already cached and synced; no new table. |
| D22 | Shopping and Library CDs | Both stay CD-only. They gain display-only "In your collection: CD #12" badges and an **I Own This** button. | Keeps request volume and scope down. |

## 3. Data model and storage

### 3.1 Table `collection_items`

`Database.createCollectionTable()` creates it in `migrate()` right after `createTrackPurchasesTable()` and the
`format` ALTER, following the precedent of `rip_checks` and `track_purchases`. `user_version` stays 14.
`writeSyncSnapshot` keeps the table (it strips only the `catalog_*` tables), and `LibraryExporter.backUp` copies it.

```sql
CREATE TABLE IF NOT EXISTS collection_items(
  id TEXT PRIMARY KEY,           -- lowercased UUID, "own-<16 hex>" (migrated) ; never "songs-…"
  medium TEXT NOT NULL,          -- 'cd' | 'vinyl' | 'download' (other values: written by a newer version)
  sticker INTEGER,               -- label number within the medium's series; NULL for downloads / unlabeled
  album TEXT NOT NULL,
  artist TEXT NOT NULL,
  album_key TEXT NOT NULL,       -- SearchIndex.albumKey the digital copy has (or a rip would get)
  year INTEGER,
  mb_release_id TEXT,
  mb_release_group_id TEXT,
  barcode TEXT,
  catalog_number TEXT,
  record_label TEXT,
  country TEXT,
  format_detail TEXT,            -- MusicBrainz media text: "CD", "2×CD", "12\" Vinyl", "2×12\" Vinyl"
  disc_count INTEGER,
  track_count INTEGER,           -- tracks on the release, for "partly ripped"
  purchased_on TEXT,             -- PurchaseDay "yyyy-MM-dd"
  price TEXT,                    -- POSIX decimal text (AlbumPurchase.priceText)
  notes TEXT,
  cover_file TEXT,               -- file name in Music/Collection Covers, or NULL = the linked album's cover.jpg
  digital_source TEXT,           -- 'rip' | 'download' | 'same' | NULL (never linked)
  created_at REAL NOT NULL,
  updated_at REAL NOT NULL);
CREATE INDEX IF NOT EXISTS collection_items_album   ON collection_items(album_key);
CREATE INDEX IF NOT EXISTS collection_items_sticker ON collection_items(medium, sticker);
CREATE INDEX IF NOT EXISTS collection_items_release ON collection_items(mb_release_id);
```

There is deliberately **no UNIQUE index** on `(medium, sticker)` (see D7).

**Reading.** `Database.collectionItems()` builds its SELECT from `columns(of: "collection_items")`, using NULL for any
column that is missing, so later additions stay readable. Rows are untrusted, because they may come from a synced or
exported copy. Each column is checked as follows; a failed check either drops the row (and counts it in
`unreadable`) or reads the value as NULL:

| Column | Rule |
|---|---|
| `id` | 1–64 characters from `[a-z0-9-]` (lowercased on read), else the row is dropped |
| `medium` | `CollectionMedium(rawValue:)`; nil (empty or not `[a-z0-9-]{1,24}`) drops the row |
| `sticker` | kept only when the medium has a series and the value is in 1…9,999,999 |
| `album`, `artist` | trimmed, at most 1,000 characters; an empty album *and* artist drops the row |
| `album_key` | empty → recomputed with `SearchIndex.albumKey(album:artist:)` |
| `year` | 1000…9999 |
| `mb_release_id`, `mb_release_group_id` | `MBID.validated` |
| `barcode` | digits only, 6–20 characters |
| `catalog_number`, `record_label`, `country`, `format_detail` | at most 200 characters |
| `disc_count` / `track_count` | 1…99 / 1…999 |
| `purchased_on` | `PurchaseDay(string:)` |
| `price` | `AlbumPurchase.price(text:)` |
| `notes` | at most 10,000 characters |
| `cover_file` | `CollectionCovers.isFileName` |
| `digital_source` | `DigitalSource(rawValue:)` |
| `created_at`, `updated_at` | finite, else 0 |

When the table doesn't exist (a snapshot or export from an older Mac), `collectionItems()` returns
`CollectionLegacy.reconcile(items: [], legacy: legacyOwnershipRows()).items`, which is the same synthesis and the same
deterministic ids the Mac migration produces.

### 3.2 Core types (all `Sendable`, platform-neutral)

New file `Sources/MusicLibraryCore/Collection.swift`:

```swift
public enum CollectionMedium: Hashable, Sendable, Comparable {
    case cd, vinyl, download
    case other(String)                         // written by a newer version: read-only here
    public init?(rawValue: String)              // trimmed+lowercased; "cd"/"vinyl"/"download", else [a-z0-9-]{1,24} → .other
    public init?(musicBrainzFormats: [String])  // any "Vinyl"/"12\""/"10\""/"7\"" → .vinyl; "CD","SACD","Hybrid SACD","HDCD",
                                                // "SHM-CD","Blu-spec CD","Enhanced CD","CD-R" → .cd; "Digital Media" → .download
    public var rawValue: String
    public var isPhysical: Bool                 // cd, vinyl, other
    public var series: StickerSeries?           // cd → .cd, vinyl → .vinyl, else nil
    public var name: String                     // "CD", "Vinyl", "Download", "Other"
    public static let known: [CollectionMedium] // [.cd, .vinyl, .download]
}

public enum StickerSeries: String, CaseIterable, Hashable, Comparable, Sendable {
    case cd, vinyl
    public var name: String                     // "CD", "Vinyl"
    public var medium: CollectionMedium
}

/// A label number on a physical item. Never shown without its series.
public struct Sticker: Hashable, Comparable, Sendable {
    public var series: StickerSeries
    public var number: Int
    public static let maxNumber = AlbumPurchase.maxLabelNumber          // 9_999_999
    public init?(series: StickerSeries, number: Int)
    public var text: String                     // "CD #12", "Vinyl #12"
    public var spoken: String                   // "CD label 12", "Vinyl label 12"
    public var token: String                    // "sticker:cd12", "sticker:vinyl12"
    /// "12", "#12" → (nil, 12); "cd12", "cd 12", "CD #12", "cd#12" → (.cd, 12);
    /// "vinyl 12", "vinyl#12", "v12", "lp12", "lp #12", "record 12" → (.vinyl, 12). Anything else → nil.
    public static func parse(_ text: String) -> (series: StickerSeries?, number: Int)?
}

public enum DigitalSource: String, CaseIterable, Sendable {
    case rip        // made from this copy (CD rip, vinyl needle-drop)
    case download   // this purchase is, or came with, the files
    case same       // the same music is in the library, from elsewhere (e.g. the CD of the record you own)
}

public struct CollectionItem: Identifiable, Hashable, Sendable {
    public enum Origin: Hashable, Sendable { case stored, songs }     // songs = derived from TrackPurchases; not stored
    public var id: String
    /// Changing to a medium of another series (or none) clears `stickerNumber`.
    public var medium: CollectionMedium
    public var stickerNumber: Int?
    public var album: String
    public var artist: String
    public var albumKey: String
    public var year: Int?
    public var releaseID: String?
    public var releaseGroupID: String?
    public var barcode: String?
    public var catalogNumber: String?
    public var recordLabel: String?
    public var country: String?
    public var formatDetail: String?
    public var discCount: Int?
    public var trackCount: Int?
    public var purchasedOn: PurchaseDay?
    public var price: Decimal?
    public var notes: String?
    public var coverFile: String?
    public var digitalSource: DigitalSource?
    public var createdAt: Date
    public var updatedAt: Date
    public var origin: Origin
    public var sticker: Sticker? { get }
    public var isEditable: Bool { get }          // origin == .stored && medium is .cd/.vinyl/.download
    public init(id: String = CollectionItem.newID(), medium: CollectionMedium, album: String, artist: String,
                albumKey: String? = nil, now: Date = Date())
    public static func newID() -> String                         // UUID().uuidString.lowercased()
    public static func legacyID(albumKey: String) -> String      // "own-" + 16 hex (FNV-1a 64)
    public static func songsID(albumKey: String) -> String       // "songs-" + 16 hex
}

public enum DigitalState: Hashable, Sendable {
    case none                               // never linked, no tracks under its album key
    case digitized(tracks: Int)             // tracks present, source rip/download (or CD/download with source nil)
    case partial(have: Int, of: Int)        // digitized, but fewer tracks than trackCount
    case otherCopy(tracks: Int, from: String?)   // source .same (or vinyl/other with source nil): music is in the
                                            // library; `from` = id of a copy on the key whose source is rip/download
    case missing                            // was linked (source set) but the key has no tracks now
    public var hasMusic: Bool               // digitized, partial, otherCopy
    public var needsDigitizing: Bool        // .none or .missing (callers check isPhysical)
}

/// How a cover shows what you own. Replaces OwnershipMark (kept, deprecated, until cleanup).
public enum CopyMark: Hashable, Sendable {
    case notInCollection                                    // "Borrowed" badge (arrow.left.arrow.right)
    case cd(number: Int?, digitized: Bool, more: Int)
    case vinyl(number: Int?, digitized: Bool, more: Int)
    case download(partial: Bool, more: Int)
    case other(more: Int)
    public var sticker: Sticker? { get }
}

public enum CollectionScope: String, CaseIterable, Hashable, Sendable {
    case all, cds, vinyl, downloads, toDigitize
    public var title: String     // "Shelf", "CDs", "Vinyl", "Downloads", "To Digitize"
    public var query: String     // "", "own:cd", "own:vinyl", "own:download", "own:physical ripped:no"
}

public struct CollectionItemRoute: Hashable, Sendable { public var id: String; public init(id: String) }

public enum CollectionSyncScope: String, CaseIterable, Codable, Sendable {   // Mac-side setting only, never on the wire
    case off, cds, vinyl, all
    public var title: String     // "Off", "Digitized CDs", "Digitized vinyl", "Everything digitized in my collection"
}

/// Every item plus the lookups the UI needs. Immutable; built off the main thread on each library reload (Mac)
/// and in LibrarySnapshot (phone).
public struct MusicCollection: Sendable {
    public static let empty: MusicCollection
    public init(items: [CollectionItem], songPurchases: [Int64: TrackPurchase], tracks: [Track], unreadable: Int = 0)
    public let items: [CollectionItem]                    // stored + derived, in CollectionSort.sticker order
    public let unreadable: Int                            // rows dropped on read ("update the app")
    public func item(id: String) -> CollectionItem?
    public func copies(albumKey: String) -> [CollectionItem]    // CDs (by number), vinyl, other, downloads, derived
    public func items(artist: String) -> [CollectionItem]       // case-insensitive
    public func items(at sticker: Sticker) -> [CollectionItem]  // >1 = duplicate
    public func items(number: Int) -> [CollectionItem]          // both series
    public func neighbors(of sticker: Sticker) -> (previous: CollectionItem?, next: CollectionItem?)
    public func digitalState(_ item: CollectionItem) -> DigitalState
    public func libraryTracks(_ item: CollectionItem) -> [Track]   // tracks under item.albumKey, album order
    public func nextNumber(in series: StickerSeries, pending: [Int] = []) -> Int
    public func firstGap(in series: StickerSeries) -> Int?
    public func gaps(in series: StickerSeries) -> [ClosedRange<Int>]
    public func duplicates(in series: StickerSeries) -> [Int: [CollectionItem]]
    public func taken(_ sticker: Sticker, excluding id: String?) -> CollectionItem?
    public func mark(albumKey: String) -> CopyMark
    public func mark(item: CollectionItem) -> CopyMark
    public func matches(releaseID: String?, releaseGroupID: String?, albumKey: String?, barcode: String?,
                        medium: CollectionMedium?) -> [CollectionItem]   // stored items; undigitized first
    public func syncItems(_ scope: CollectionSyncScope) -> [ExportItem]  // .album(album:artist:) of linked keys
    public func count(_ scope: CollectionScope) -> Int
    public func items(in scope: CollectionScope) -> [CollectionItem]
    public var artists: [String]                          // every item artist, incl. trackless
    public func coverPath(_ item: CollectionItem) -> String?   // "Music/Collection Covers/<file>" or the linked album's cover.jpg path
    public var legacyPurchases: [String: AlbumPurchase]   // shim for untouched call sites (deprecated in its doc
                                                          // comment, not with @available, so nothing warns)
}

public enum CollectionSort: String, CaseIterable, Sendable {   // in LibrarySort.swift
    case sticker, artist, title, year, bought, price, added
    public var title: String
    public func sorted(_ items: [CollectionItem]) -> [CollectionItem]
}
```

`CollectionSort.sticker` puts CDs before vinyl, then sorts by number; unlabeled items come last, then by artist and
title. `bought` is newest first with undated items last. Ties keep library order. Empty values always sort last.

**`DigitalState` derivation.** Let `n` be the number of tracks under `albumKey`:

| `n` | `digitalSource` | Medium | State |
|---|---|---|---|
| > 0 | `rip` or `download` | any | `.digitized(n)`, or `.partial(n, trackCount)` when `trackCount > n` |
| > 0 | `same` | any | `.otherCopy(n, from:)` |
| > 0 | nil | cd, download | treated as digitized |
| > 0 | nil | vinyl, other | `.otherCopy` |
| 0 | set | any | `.missing` |
| 0 | nil | any | `.none` |

The Mac's linker persists the source it infers (§4.6), so the nil cases are transitional.

**Derived downloads.** For each album key that has `TrackPurchase` songs and no stored `.download` item, `MusicCollection`
adds one item:

- `id`: `songsID(albumKey:)`; `origin`: `.songs`; `digitalSource`: `.download`
- price: the sum of the song prices (nil when none has one); day: the earliest song's
- `trackCount`: the album's track count, so a partial purchase reads `.partial`

Unlike `AlbumPurchase.including`, it appears even when a CD or vinyl item exists for the key (D20).

**Primary copy and marks.** `mark(albumKey:)` uses the preferred copy, in this order: the labeled CD with the lowest
number, then any CD, a labeled vinyl, any vinyl, other, a stored download, a derived download.
`more` is the number of copies minus 1. `digitized` is `digitalState(item).hasMusic`.

### 3.3 Covers (`Sources/MusicLibraryCore/CollectionCovers.swift`)

```swift
public enum CollectionCovers {
    public static let folder = "Music/Collection Covers"
    public static func isFileName(_ s: String) -> Bool          // ^[a-z0-9-]{1,80}\.jpg$, no leading "-"
    public static func path(_ file: String) -> String?          // "Music/Collection Covers/<file>" when valid
    public static func url(_ file: String, root: URL) -> URL?   // via LibraryPath.resolve
    /// Writes `jpeg` atomically as "<itemID>-<8 random hex>.jpg" and returns the name; the old file is removed by
    /// the caller after the row is saved.
    public static func write(_ jpeg: Data, itemID: String, root: URL) throws -> String
    /// Copies an album's cover.jpg in as the item's own cover (before the album leaves the library).
    public static func adopt(albumCover: URL, itemID: String, root: URL) throws -> String
}
```

- **Sources of the image**: the Cover Art Archive front for the release (falling back to the release group), a file, a
  dropped web image or the clipboard (`ImageInput`). Every image goes through `CoverImage.jpeg`, at most 1600 px.
- **Display order** everywhere:
  1. the item's own `cover_file`;
  2. the linked album's `cover.jpg`, when that album has tracks;
  3. a drawn placeholder: the case or sleeve with the title.
- **Folder location**: the folder sits under `Music`, so `SyncPlan.isManaged` and current phones' `SyncReceiver`
  accept it. It isn't an album folder, so `emptiedFolders` never trashes it. `ExportPreview` lists only audio files,
  and the Organizer never writes a top-level `.jpg` there (an artist folder that happened to be named "Collection
  Covers" would only hold album subfolders).

### 3.4 Migration, projection and reconcile (`Sources/MusicLibraryCore/CollectionLegacy.swift`)

These are pure functions shared by the Mac (which persists the results) and the phone (which applies them in memory).

```swift
public enum CollectionLegacy {
    public struct Row: Hashable, Sendable { public var key: String; public var purchase: AlbumPurchase; public var updatedAt: Date }
    /// Projectable copies of a key: stored, editable items whose albumKey is the key and medium is .cd or .download.
    public static func primary(_ items: [CollectionItem], albumKey: String) -> CollectionItem?
    public static func reconcile(items: [CollectionItem], legacy: [Row]) -> (items: [CollectionItem], changed: [CollectionItem])
    public static func projection(items: [CollectionItem]) -> [String: Row]
    public static func overlay(events: [SyncEvent], on items: [CollectionItem], albumKey: (Int64) -> String?) -> [CollectionItem]
    public static func applyLegacyPurchase(_ purchase: AlbumPurchase?, key: String, album: String, artist: String,
                                           at: Date, to items: inout [CollectionItem]) -> Bool
}
```

**Primary copy.** Among the projectable copies of a key, the primary copy is chosen in this order:

1. the CD with the lowest label number;
2. any CD;
3. a download.

Ties go to the earliest `createdAt`, then the lowest `id`.

**Projection.** Each key gets one row from its primary copy. The row takes that copy's own `album`, `artist`,
`purchased_on` and `price` (never sums), with these mappings:

| Column | Value |
|---|---|
| `format` | NULL for a CD, `'digital'` for a download |
| `label_number` | the CD's label number |
| `updated_at` | exactly the item's `updatedAt` |

Vinyl, `other` media and derived downloads are never projected.

`Database.projectLegacyOwnership(keys: Set<String>?)` makes `album_ownership` match the projection:

- With a key set, only those keys are processed; with nil, every key is.
- It writes only rows that differ: INSERT OR REPLACE when a row is missing or different, DELETE for a key that no
  longer has a projectable copy.
- That deletion only happens after a user deletes, relinks or changes the medium of an item.

**Reconcile** runs for each legacy row R with key K:

- **No projectable copy for K.** It creates an item:
  - `id`: `legacyID(K)`, or if that id is taken, the first free `legacyID("K#2")`, `legacyID("K#3")`… (never random:
    the phone reconciles on every load, and links to the item must stay the same)
  - `medium`: `.download` when `format == 'digital'`, otherwise `.cd` (NULL or unknown reads as a CD, as old readers
    do)
  - `stickerNumber`: the CD label, when it validates
  - `album`, `artist`, date and price from R; `albumKey = K`; `digitalSource = nil`
  - `createdAt = updatedAt = R.updatedAt`
- **A primary copy P exists, and R isn't P's projection** (its values, its text once trimmed and clipped, and its
  `updated_at` within 0.001 s; whatever its time, since an older Mac's clock may be behind the device that last
  edited P). An older app edited the row. The reconcile copies `purchasedOn` and `price` into P, then the medium and
  the label as far as R's writer knew them, and sets `P.updatedAt = R.updatedAt`:

  | R's writer | Medium | Label (when the result is a CD) |
  |---|---|---|
  | 1.19 and later (`.current`) | follows R's format both ways (NULL is a CD) | R's, a NULL clears it |
  | 1.18 (`.noFormat`) | `'digital'` never appears; a download becomes a CD only with a label | R's, a NULL clears it |
  | 1.14–1.17 (`.noLabel`), or unmarked (`.unknown`) | as for 1.18 | R's when it has one; otherwise kept |

  **Telling the writers apart** (`Database.markLegacyWriters`, once on the Mac, after the first reconcile): an older
  app's INSERT OR REPLACE leaves the columns it doesn't name NULL, the same as a newer app clearing them. So
  `album_ownership` is made again (rows and rowids as they were, same columns in the same order) with
  `format DEFAULT 'pre-1.19'` and `label_number DEFAULT 'unwritten'`, plus a trigger `album_ownership_writer` that
  turns a text label into NULL with `format = 'pre-1.18'` in the same statement, so no reader ever sees the text.
  Every reader takes both format markers for a CD, as it took the NULL those apps wrote before. The projection names
  every column, so it never leaves a marker; a marked row is always an older app's edit. A table without the trigger
  (a copy from before this version) reads `.unknown`, and a table with other columns (a newer version) isn't remade.
- **Never deletes.** A row that has gone missing is written again by the next projection. The help text and the
  CHANGELOG note say that deleting a copy with an older app version has to be repeated in 1.21.
- **Text is never made up or rewritten.** An item made for a row with neither album nor artist (an album without
  tags) keeps them empty: a legacy id reads back untitled (`CollectionItem.isNamed`). The projection keeps a row's own
  album and artist text when it trims and clips to the item's.

**On the Mac**, `migrate()` runs reconcile against `album_ownership` in one transaction, then
`projectLegacyOwnership(keys: nil)`, then `markLegacyWriters()`. The first run is the migration, and later runs change
nothing unless an older app wrote. Running it twice is a no-op, and a test covers that (`DowngradeRoundTripTests`
covers edits by the exact statements of 1.17, 1.18 and 1.20 in between).

**On the phone**, `LibrarySnapshot` runs reconcile in memory over the snapshot's `collection_items` and its
`album_ownership` rows, so a snapshot edited by a downgraded Mac still shows the edits.

**Legacy phone events** (`SyncEvent.Kind.purchase`, from phones before 1.18). The `.purchase` branch of
`Database.applySyncEvents` now calls `applyLegacyPurchase` for the track's key, then re-projects that key:

- If the primary copy's `updatedAt` is later than the event, the event is skipped.
- A non-nil purchase updates the primary copy's date and price, or creates an unlabeled CD item when the key has no
  projectable copy.
- A nil purchase deletes the primary copy only when it has no label number.
- Medium, label and vinyl are never touched.

On the phone, `CollectionLegacy.overlay` replaces `SyncOutbox.purchases` with the same rules. The `AlbumPurchase`
Codable form is unchanged.

**`track_purchases`** is unchanged: song-derived downloads are recomputed in memory and never migrated.

### 3.5 Database API (`Sources/MusicLibraryCore/CollectionStore.swift`, `extension Database`)

```swift
public struct CollectionRead: Sendable { public var items: [CollectionItem]; public var unreadable: Int; public var hadTable: Bool }
func createCollectionTable() throws                               // from migrate()
func reconcileLegacyOwnership(now: Date = Date()) throws          // from migrate(), Mac only
func markLegacyWriters() throws                                   // from migrate(), Mac only, once
public func collectionItems() throws -> CollectionRead            // probes columns; legacy synthesis when no table
public func legacyOwnershipRows() throws -> [CollectionLegacy.Row]
public func saveCollectionItem(_ item: CollectionItem, at: Date = Date()) throws        // upsert + reproject old & new keys
public func saveCollectionItems(_ items: [CollectionItem], at: Date = Date()) throws    // one transaction
public func deleteCollectionItem(id: String) throws               // + reproject; never touches tracks
public func applyCollectionChanges(_ changes: [CollectionLinker.Change], at: Date = Date()) throws
public func rekeyCollection(from oldKey: String, to newKey: String, at: Date = Date()) throws   // retags
public func projectLegacyOwnership(keys: Set<String>?) throws
public func collectionCoverPaths() throws -> [String]             // valid cover_file paths under Music/Collection Covers
```

`updatedAt` is the time of the user's last edit (or an older app's, taken in): older apps' changes are compared with it
(newest wins), so `applyCollectionChanges` and `rekeyCollection` keep it (their `at:` is unused). Saving writes text
as it reads back (trimmed, clipped to the read limits) and refuses an item with neither album nor artist
(`CollectionError.invalidItem`).

`saveCollectionItem` refuses a non-editable item: it throws `CollectionError.readOnly` for a derived item or an
`.other` medium. Duplicate refusal (D7) is a UI rule enforced by `CollectionEditor`, not by the database, so legacy
duplicates stay saveable.

### 3.6 Linking helpers (`Collection.swift`)

```swift
public enum CollectionLinker {
    public struct Change: Hashable, Sendable {
        public var id: String
        public var albumKey: String?; public var releaseID: String?; public var releaseGroupID: String?
        public var year: Int?; public var digitalSource: DigitalSource?
    }
    /// After a reload: backfills release IDs and year from the most common tags of linked tracks, persists the
    /// inferred source (nil + tracks → .rip for CDs, .download for downloads, .same otherwise), and relinks an item
    /// whose key lost its tracks only when its releaseID is on exactly one live album key. Never by name.
    public static func changes(items: [CollectionItem], tracks: [Track]) -> [Change]
    /// Name-based proposals for "Link to Library Album…": release group first, then CatalogOwnership.tokens/compatible.
    public static func suggestions(for item: CollectionItem, albums: [AlbumSummary], tracks: [Track]) -> [AlbumSummary]
}
```

Release-group matches are only suggestions and are never applied automatically, because they could tie an unripped CD
to a different edition's download.

### 3.7 Snapshot (phone)

`LibrarySnapshot` gains these members:

```swift
public let collection: MusicCollection          // collectionItems() → in-memory reconcile → MusicCollection(...)
public let collectionIndex: CollectionIndex
public let labelUnreadable: Int                 // = collection.unreadable
public var isEmpty: Bool { get }                // tracks.isEmpty && collection.items.isEmpty
public func coverURL(item: CollectionItem) -> URL?   // own cover file if present on disk, else the linked album's cover.jpg
```

- Every read is wrapped in `try?`.
- `datesRelativeToNow` also shifts the items' `purchasedOn`, `createdAt` and `updatedAt`.
- `purchases` stays populated from `collection.legacyPurchases` until the cleanup package.
- `tracks(smartPlaylist:)` goes through `LibrarySearch.tracks(matching:…)`.

### 3.8 Compatibility matrix

| Reader | Reads | Result |
|---|---|---|
| iPhone 1.14–1.17 | `album_ownership` key, album, artist, date, price | CDs and downloads correct. Vinyl-only albums look not owned. Trackless items are invisible, as their records already were. Covers under `Music/Collection Covers` are stored harmlessly. |
| iPhone 1.18 | + `label_number` | CD labels correct; vinyl numbers never appear. |
| iPhone 1.19–1.20 | + `format` | CD and download badges correct; no vinyl ever reads as a CD. |
| iPhone 1.21+ | `collection_items` + in-memory reconcile + overlay | The whole collection. |
| New phone, snapshot or export from an older Mac | no table | Items synthesized from `album_ownership` with deterministic ids; no covers of their own. |
| Older Mac after a downgrade | `album_ownership` | Edits CDs and downloads; the next-label suggestion counts CDs only, and only each album's primary copy: it doesn't see the label of a second CD of the same album, so it can suggest or accept that number (documented; Label Check lists the duplicate after upgrading). Its edits are reconciled when 1.21 reopens (labels cleared and formats changed included; 1.14–1.17 can't clear a label or say a download, so theirs are kept), and its deletes are not applied (documented). |
| Older Mac syncing a new phone | its own plan | Deletes `Music/Collection Covers/*` from the phone (not wanted by its plan); items show placeholders until the next 1.21 sync. Documented. |
| Older watch | `Glance.owned` | Same meanings as today (library albums only); `collection` is ignored; `shelf.json` is dropped (no delegate method). |
| New watch, older phone | no `collection`, no shelf | Shelf page reads "Update Music Library on your iPhone to find items by label." |
| Older widgets (same bundle as the app) | n/a | Widgets ship with the app; no mismatch. |
| Saved smart playlists | `label:`, `format:`, `is:`, … | Unchanged: there's a golden test. Collection keys on old readers become text and match nothing; a *negated* collection key (`-own:vinyl`) matches everything there (documented in help). |
| Exports dragged onto a phone | full `VACUUM INTO` + covers | Same as a sync. |

## 4. Adding and linking items (Mac only)

Every write goes through `AppModel.saveItem(_:)`, which calls `db.saveCollectionItem`. That writes the item and the
projection. `saveItem` then writes or replaces the cover file when there is one, rebuilds `collection`,
`collectionIndex` and `collectionStats` off the main thread, and bumps `collectionVersion`.

### 4.1 Add to Collection… (⇧⌘N, File menu, the Shelf's + button)

`AddToCollectionSheet(medium:prefill:)` has three parts:

1. **Medium.** A **CD | Vinyl | Download** segmented control that remembers the last choice
   (`@AppStorage("addCollectionMedium")`).
2. **One search field.** "Artist and album, or barcode."
   - **8–14 digits** (spaces and dashes allowed) run a barcode lookup with and without a leading 0.
   - **Anything else** runs a word-prefix search: each word must start the release title or the artist, the same
     approach as `CDSearchQuery`. It is filtered by medium (`format:CD`, `format:Vinyl`, or no filter for Download).
     When that finds nothing, it retries looser, and then as `catno:`.
   - **Results** are grouped by release group. Each edition row shows a CAA thumbnail and year · country · record
     label · cat. no. · media ("2×12″ Vinyl") · barcode.
   - **"Not on MusicBrainz? Enter it yourself"** opens empty fields.
3. **Details pane.**
   - Label number: the suggestion is `nextNumber(in:)`. A taken number is refused inline (D7).
   - Bought: defaults to today. Paid, Notes and Cover (the CAA front, or drop an image).
   - **"Link to *X* in your library (12 songs)"**, shown and on by default when `matches(...)` or the album key finds
     a library album. Linking sets `digitalSource`: `.rip` for a CD, `.same` for vinyl, `.download` for a download.

Buttons:

- **Add** (⌘↩) saves and opens the item page.
- **Add & Next** (⌥⌘↩) saves, clears the search, keeps the medium, moves the suggestion to the next number and
  refocuses the field.

The footer counts the session: "Added 14 · next Vinyl #58". With a USB barcode scanner (digits then Return), a single
exact match is selected automatically, and Return adds it.

Network rules:

- Every lookup goes through the rate-limited `MusicBrainzClient` (at least 1.1 s apart, `AppInfo.userAgent`,
  validated MBIDs).
- The cover comes from `CoverArtClient.fetchFront`, only after an edition is picked.
- `AlbumInfoStore.ensure` then fetches the tracklist, genres and reviews for the item's key and release IDs.

### 4.2 From a library album

- **Album page.** The **Your Copies** section has **Add a Copy ▾ CD (next CD #213) / Vinyl (next Vinyl #49) /
  Download**. It creates the item with one click, prefilled from the album: key, release IDs and year from the tracks'
  tags, record label, barcode and catalog number from tags, and `digitalSource` as in §4.1. The cover stays NULL (the
  album's). It then shows inline Bought/Paid fields.
- **Albums grid.** The context menu has **Add to Collection ▸ As CD / As Vinyl / As Download**, which uses the next
  number. ⌘Z undoes it.
- **Bulk.** **Collection ▸ Add Library Albums…** opens `BulkAddSheet`:
  - a `Table` of library albums with no copy;
  - columns: checkbox, cover, album, artist, year, Medium (CD by default), Label;
  - "Number them in this order from CD #343 / Vinyl #58" assigns numbers in the current sort order;
  - **Add N Items** calls `saveCollectionItems` once;
  - cells get the model passed in, never `@Environment(AppModel.self)`.

### 4.3 Ripping, and cataloging a CD without ripping (`CDController`, `CDView`)

- **Matching an existing item.** When a disc's release is chosen, `matchCollectionItem(disc)` calls
  `collection.matches(releaseID: disc.release.id, releaseGroupID:, albumKey: disc.albumKey, barcode:, medium: .cd)`.
  - **One match**: `CDCollectionPanel` shows *"This is CD #37 in your collection, not ripped yet. This rip will be
    linked to it."* The match is stored in `disc.collectionItemID`, and its date, price and label are editable.
  - **Several matches**: a picker.
  - **None**: the panel shows **"Add to your collection as CD #343"**, a toggle with Bought/Paid. It is on by default.
    Settings ▸ Collection ▸ "Ask whether a CD is yours when it's inserted" turns it into a question instead.
- **Rip start.** The CD item is created or updated:
  - `albumKey = disc.albumKey`, plus `trackCount` and `discCount` from the release;
  - release IDs and other fields are filled only where blank;
  - **the medium is never changed**, and vinyl and download items are never matched or overwritten.
- **First imported track.** When the first track of the disc is imported, `digitalSource = .rip` (D4).
  `ripToImportQueue` does the same.
- **Turning the toggle off** removes only an item this disc session created (`disc.createdItemID`). It **never**
  deletes an existing item. This replaces today's destructive "No".
- **Label numbers.** `nextLabelNumber()` = `collection.nextNumber(in: .cd, pending: numbers of other discs in drives)`.
- **Catalog Without Ripping.** The new footer button (next to Rip) creates or updates the item with no source, takes
  the cover from the disc lookup or CAA, and ejects the disc when Settings ▸ Collection ▸ "Eject after cataloging" is
  on (the default).
- **A disc that is already a ripped item** shows "CD #57 · ripped" next to the existing "In library" rows.

### 4.4 Import page (needle-drops, downloads)

`ImportCollectionBar` sits above `ImportBatchPurchaseBar`. It has two controls:

- **"These files are the digital copy of: [None ▾]".**
  - **Choices**: physical items whose `needsDigitizing` is true, with items matching the import's release ID, release
    group or album key first (pre-selected), then a search over the rest. Items show their labels.
  - **Source**: a "Digitized from this record / Came with it as a download" choice (`.rip` / `.download`).
  - **After the batch**: the item's `albumKey` becomes the imported album's key and `digitalSource` is set. No
    `TrackPurchase`s are created.
- **"Bought as: Songs | Whole album".** Whole album creates one stored `.download` item with the batch's day and
  total, instead of per-song `TrackPurchase`s.

### 4.5 Linking later and fixing

The item page has three actions:

- **Link to Library Album…** (`LinkAlbumPicker`): `CollectionLinker.suggestions` first, then a search, then None.
- **Digital copy ▾**: Ripped from this copy / Digitized from this record / Came with it / Same music from elsewhere /
  Unlink. This edits `digitalSource`, and Unlink also sets it to nil.
- **Missing state**: "Digital copy no longer in your library", with **Unlink** and **Rip Again** (CDs).

On the album page, **Your Copies ▸ Add Existing Item…** links an item with no music, such as the vinyl you bought
before the download.

### 4.6 Keeping links right

- **After every reload**, `AppModel` runs `CollectionLinker.changes` off the main thread and persists the result with
  `db.applyCollectionChanges`.
- **When the Mac changes album or album-artist tags** (Get Info, album edits, MusicBrainz rematch), every path that
  writes them calls `db.rekeyCollection(from:to:)` for each changed key.
- **`removeFromLibrary`** (D12) works in three steps:
  1. For each removed album key, each linked item with no `coverFile` adopts the album's `cover.jpg`
     (`CollectionCovers.adopt`).
  2. Their `digitalSource` is cleared.
  3. The files are then trashed as today. The confirmation says *"Your copy CD #12 stays in your collection, marked
     not ripped."*

## 5. Mac UX

### 5.1 Sidebar and commands

```
COLLECTION
  Shelf            (books.vertical)      badge: all items        ← default when the collection isn't empty
  CDs              (opticaldisc)         badge
  Vinyl            (record.circle)       badge
  Downloads        (arrow.down.circle)   badge
  To Digitize      (waveform.slash)      badge; hidden when 0
LIBRARY
  Songs · Albums · Artists · Insights · Music DNA · Concerts
IMPORT …  LIBRARY CATALOG …  SHOPPING …  EXPORT …  PLAYLISTS …  SMART PLAYLISTS …
```

- **Sidebar.** `SidebarItem` gains `.collection(CollectionScope)`. Badges use `.sidebarBadge`. The default selection
  is `.collection(.all)` when `collection.items` isn't empty, else `.songs`.
- **Navigation.** The single root `NavigationStack` gains `navigationDestination(for: CollectionItemRoute.self)` →
  `CollectionItemDetail(id:)`. Pages push with `NavigationLink(value:)` or `model.navigationPath.append`, and no stack
  is nested.
- **Commands.** **Find by Label…** (⌘L), **Add to Collection…** (⇧⌘N) and **Add Library Albums…**, under a new
  **Collection** menu.
- **Settings ▸ Collection** (next to CD ripping): "Ask whether a CD is yours when it's inserted" (on), "Eject after
  cataloging" (on).

### 5.2 Shelf page: `CollectionView(scope:)` (new `CollectionViews.swift`)

- **Header.**
  - Title and clickable counts: "312 CDs · 48 vinyl · 97 downloads · 9 to digitize".
  - An inline **Go to** finder: a **CD | Vinyl** segmented control (remembered) plus a number field. Return scrolls to
    the item, highlights it briefly and opens its card. Typing "cd 12" or "v12" into it works too (`Sticker.parse`).
  - A filter field in the collection query language (§8).
  - A **Label Check** link ("3 free · 1 duplicate") that opens `LabelCheckSheet`: gaps and duplicates per series,
    with Open on each item.
- **Toolbar.**
  - Grid | List (`@AppStorage("collectionLayout")`).
  - Sort (`CollectionSort`, `@AppStorage("collectionSort.<scope>")`): the default is `sticker` for CDs, Vinyl and To
    Digitize, and `added` for Shelf and Downloads.
  - **Show**: Any / Digitized / Not digitized / Unlabeled / Needs details.
  - The **+** menu: Add CD… / Add Vinyl… / Add Download… / Add Library Albums….
- **Grid.**
  - Each cell is a `CollectionCell`: `CopyArt(mark:)` at 150 pt, then title, artist, and a third line with a
    `StickerPill` plus a `DigitalStatusLabel`.
  - **Status icons**: none for digitized, `waveform.slash` "Not ripped"/"Not digitized", a half circle for partial, an
    exclamation mark for missing, `arrow.triangle.2.circlepath` for "from your CD #142".
  - **Owned items are never dimmed.**
  - **Section headers**: when sorted by label, sticky headers per series and per hundred: "CD 100–199 · 97 labeled ·
    3 free".
- **List.**
  - A `CollectionTable` (SwiftUI `Table`) with columns Label (monospaced pill; sorts by series, then number), Title,
    Artist, Year, Medium (with format detail), Digital ("12/12", "8/12", "—"), Bought, Paid, Record Label, Cat. No.
  - Cells get the model or an action passed in and **never** read `@Environment(AppModel.self)`.
- **Context menu.**
  - Open; Open Album in Library (when it has music).
  - Play / Shuffle; Add to iPhone / Add to Export List (they resolve to `.album` of the linked key).
  - Rip This CD (when a matching disc is in a drive); Link to Library Album…; Change Cover….
  - Shop for This CD (CD items; seeds `CDShoppingTarget` from the release ID).
  - Remove from Collection…, with a confirmation naming the label: "Remove CD #57? Its number becomes free."
- **Empty state.** "Your shelf is empty", with **Add to Collection…** and **Add Albums You Own from Your Library…**.

### 5.3 Item page: `CollectionItemDetail(id:)` (new `CollectionItemDetail.swift`)

The page works for every item and never dismisses itself for lack of tracks.

1. **Hero.**
   - A `JewelCase(width: 300, mark:)` or a `RecordSleeve(width: 300, mark:)`.
   - A large `StickerPill`, the title, and the artist as an `ArtistSummary` link (ArtistDetail no longer dismisses when
     the artist has items).
   - "1959 · 12″ Vinyl · Columbia CL 1355 · US".
   - **‹ Previous on Shelf / Next on Shelf ›** (⌘[ / ⌘]), using `neighbors(of:)`.
2. **Buttons.** Play and Shuffle (only when `hasMusic`), Open Album, and a **…** menu: Change Cover…, Link to Library
   Album…, Digital copy ▸, Add to iPhone, Add to Export List, Shop for This CD, Remove from Collection….
3. **Digital Copy card**, one of these states:
   - **Digitized**: "In your library · 12 songs · 46 min · FLAC 16/44.1" + Open Album.
   - **Partly**: "8 of 12 songs".
   - **otherCopy**: "Same album in your library, from your CD #142", or "…from elsewhere".
   - **Not ripped CD**: "Insert this CD to rip it". It lights up with **Rip Now** when the disc is in a drive. Plus
     Link… and Import Files….
   - **Vinyl not digitized**: "No digital copy yet", with **Import a Transfer…** (opens Import with the bar preset)
     and Link….
   - **Missing**: "Digital copy no longer in your library", with Unlink / Rip Again.
4. **Tracks.** `AlbumTracklist.merge` of the `album_info` tracklist with the library tracks. Library rows play, the
   rest are greyed out. Vinyl shows side positions (A1, B2) from `TracklistEntry.position`.
5. **Your Copy.** `CollectionItemEditor`, edited inline and saved on commit:
   - Medium (CD / Vinyl / Download): switching series clears the number and suggests the next one in the new series.
   - Label (`StickerField(series:)`): the suggestion, "taken by Vinyl #12 · Rumours" with **Use #58 (next)** and
     **Use #31 (first free)**, and save refused.
   - Bought, Paid, Notes; Record label, Cat. No., Barcode, Country, Media, Discs; **Change Edition…** reopens the
     edition picker.
   - Price per play, when it has music.
   - A derived download is read-only and offers **Make It an Album Download**. An `.other` medium shows "Added by a
     newer version of Music Library", read-only.
6. **Other Copies** of the same album key, each linking to its own page.
7. **About, Reviews, Links** from `AlbumInfo`. External URLs go through `URL(webLink:)`.

### 5.4 Find by Label (⌘L, anywhere): `FindByLabelPanel` (new `FindByLabelPanel.swift`)

- **Layout.** A HUD sheet with a **CD | Vinyl** segmented control (remembered) and a large monospaced number field.
- **Result card**, updated as you type: the case or sleeve at 160 pt, title, artist, year, status, the purchase line,
  and the **shelf neighbors**: "between CD #141 *Sketches of Spain* and CD #143 *Time Out*".
- **Keys.** ↑/↓ step ±1, ⇥ flips the series, ↩ opens the item page.
- **No item.** A free number reads "CD #157 is free". Past the end it reads "CD #313 is the next free number".
  Duplicates list both items.
- **Toolbar search.** When the whole query parses as a label (`#142`, `cd 142`, `vinyl 12`, or a bare 1–7 digit
  number), a **Label** hit card appears above the normal results (§8).

### 5.5 Album page, Albums grid, artist page

- **Album page.**
  - The cover uses `CopyArt(mark: collection.mark(albumKey:))`: a `JewelCase` when there is a CD copy, a
    `RecordSleeve` when the only physical copy is vinyl, a flat cover with a download badge, or the Borrowed badge.
  - `YourCopiesSection` replaces `AlbumOwnershipSection`. It has one row per copy (small case or sleeve, `StickerPill`,
    medium/format, bought, paid, digital-source line, chevron to the item page), **Add a Copy ▾**, **Add Existing
    Item…**, and the footer "Yours since 2009 · 34 plays · $0.41 a play".
  - Release details: "Label" becomes **"Record label"**.
- **Albums grid.**
  - The All/Owned picker becomes a **Collection** menu: All Albums / In Your Collection / Not in Your Collection
    (`@AppStorage("albumsCollectionFilter")`). An old `albumsOwnedOnly == true` reads as In Your Collection.
  - Covers use `CopyArt`. A "2" chip appears when `more > 0`.
- **Artist page.**
  - An **In Your Collection** row with every item by the artist, trackless ones included.
  - The page opens for artists who only have items.
  - Concerts and artist info include collection-only artists (`concertArtists`, `syncArtistInfo` and
    `artistRequests` union `collection.artists`). Album info requests include items' keys and release IDs.

### 5.6 Search UI (Mac)

`runSearch` goes through `LibrarySearch.run`, and the results page shows:

- a **Label** hit card, when the query is a label (with neighbors);
- an **In Your Collection** strip of up to 12 `CollectionCell`s, trackless items included, above `TopHitsStrip`;
- then today's top hits and `TrackTable`. When the query has collection filters, the tracks are limited to the
  matching items' linked albums.

Supporting UI:

- `SearchHelpView` gets a **Collection** section from `CollectionSearchQuery.keys`, which notes that collection
  filters apply across the whole query, and that phones before 1.21 show such smart playlists empty (or unfiltered
  when negated).
- `RefineMenus` gets a **Collection** menu: On CD, On Vinyl, Download, Not in Collection, Not Ripped.
- Completions include the new keys.
- The smart playlist editor previews through `LibrarySearch.tracks`, and saves the text through
  `CollectionSearchQuery.canonical`, which rewrites `#12`-style shorthand to `sticker:12`.

### 5.7 Insights: the Collection pane

`InsightsView.Pane` is shown as **Collection | Library | Listening**, and the Collection pane is first. The raw values
stay (`owned = "Owned"`), so `@AppStorage` and `GlanceLink.insights(.owned)` keep working. The pane is built from
`CollectionStats` (§9), and the "No Insights Yet" gate becomes no tracks **and** no items.

Cards:

- **Tiles**: Items, Digitized % (ring), To Digitize, Spent, This Year.
- **Your Shelves**: one per series, with range, count, next number, free numbers and duplicates. A link opens Label
  Check, and a find field is included.
- **How You Own It**: a bar per medium with its digitized, partial, from-another-copy and to-digitize portions, plus
  Not in Your Collection.
- **Spending Over Time**: stacked by medium, with a cumulative line.
- **Shelves list**: Recently Added / To Digitize / Priciest / Best Value / Still in the Wrapper / Needs Details / By
  Label (with a CD|Vinyl picker; rows always read "CD #12").
- **Artists**, **Genres / Decades / Record Labels**, **Facts**.

Rows push `CollectionItemRoute`. Drill-downs open the Shelf with a collection query, never a track search.

### 5.8 Library CDs and Shop for CDs

- **Library CDs.** `CatalogCard` and `CatalogDetail` show **"In your collection: CD #142 (not ripped)"** or **"You have
  it on Vinyl #12"**, matched by release group, then by `CatalogOwnership` name rules against the items.
  - `is:owned` keeps its meaning ("in your music library").
  - The new catalog key `own:any|cd|vinyl|download|none` means "in your collection".
  - **I Own This** opens `AddToCollectionSheet` prefilled.
- **Shop for CDs.** Edition rows and the locked target show **"You own this edition (CD #142)"** or "You own another
  edition", plus I Own This. The shop stays CD-only.

### 5.9 Visuals (Mac; the iPhone keeps twin copies)

- **`JewelCase(width:mark:booklet:)`** is the new init, next to the deprecated `ownership:` one.
  - A CD draws today's `LabelSticker` on the hinge.
  - When the item isn't digitized, a small `waveform.slash` badge appears bottom-right on the booklet.
- **`RecordSleeve(width:mark:booklet:)`** (new) is a square cardboard sleeve with a soft edge shadow. The black disc
  shows about 12 % on the right, with its centre label tinted from the cover. A vinyl sticker sits top-left, and the
  same undigitized badge is used.
- **`LabelSticker(number:series:)`.**
  - The CD sticker is today's white strip, read bottom to top.
  - The vinyl sticker is a round dot in `#F4C542` with near-black text, read horizontally.
  - Both use fixed colours, like today's sticker, so `ThemeTests` aren't affected.
- **`StickerPill(sticker:size:)`**, for lists and captions: a white pill with a small "CD" prefix, or a yellow pill
  with a small "VINYL" prefix, and monospaced digits.
- **`CopyArt(mark:url:width:)`** chooses the case, sleeve or flat cover.
- **`CoverCopyMark`** replaces `CoverOwnershipMark` for covers shown without a case: a `StickerPill` top-left and
  badges bottom-right. A cover inside a case never gets a mark.
- **`DigitalStatusLabel(state:medium:)`** shows the status icon and text.
- **Theme rules**: secondary text uses `.subtext`, and sheets use `.themedSheet()`.

## 6. iPhone UX (read-only)

- **Tabs.** **Collection** (`books.vertical`), then Library, Insights, Sync and Search. `RootView.Tabs` gains
  `.collection`. The first launch with items opens Collection; after that, `@SceneStorage` remembers the tab.
- **Collection home** (`CollectionHome`, inside a `LibraryStack`):
  - A **Find by Label** card at the top: a CD | Vinyl segmented control, a number field with the number pad, and the
    live result (cover, title, artist, status, "between CD #141 and CD #143"). **‹ ›** buttons step ±1, and the
    choices are remembered (`@AppStorage("findSeries")`). Tapping the card pushes the item.
  - Tiles: **CDs · Vinyl · Downloads · To Digitize**.
  - Rows with `CountPill`: Shelf (all), CDs, Vinyl, Downloads, To Digitize, and **Ready to Download**: digitized items
    whose songs aren't all on this iPhone. Ready to Download has **Download All**, which queues
    `SyncRequest(.album, include: true)` for each.
  - **Recently Added** (covers) and a Label Check footnote ("CD: 3 free numbers · 1 duplicate").
  - When `unreadable > 0`, a footnote: "N items need a newer version of Music Library."
- **Routes.** `CollectionRoute` (`.scope(CollectionScope)`, `.readyToDownload`, `.labelCheck(StickerSeries)`) and
  `CollectionItemRoute`, both registered in `.libraryDestinations()`, so every tab can push them via `openRoute`.
- **`CollectionListPage(route:)`**:
  - a grid of `CopyArt` cells or a list;
  - a sort menu (`CollectionSort`) with sticky "CD 100–199" headers when sorted by label;
  - `.searchable` in the collection query language;
  - a bare number or `#12` typed in it jumps to that label.
- **Item page** (`CollectionItemPage`):
  - Hero with a large `StickerPill`, the medium and format.
  - Your Copy rows: Label, Bought, Paid, Notes.
  - Release details ("Record label"), the tracklist with sides (greyed out when there is no music), Other Copies,
    About and Reviews.
  - ‹ Previous / Next › on the shelf.
  - Footnote: "Edit your collection in Music Library on your Mac."
  - **Digital Copy section**:
    - on this phone: Play / Shuffle / Open Album;
    - digitized but not here: `AvailabilityBar(item: .album…)` with Download;
    - none: "No digital copy yet. Rip it with Music Library on your Mac." (CD) or "…Digitize it…" (vinyl), and **no
      Download**;
    - missing: "Digital copy no longer in the library".
- **Three looks, never confused:**
  1. **Playable here**: normal.
  2. **Digitized, on the Mac only**: dimmed to 0.55 with the existing iCloud `AvailabilityMark` and download actions.
     This applies in the Library tab and in an item's Digital Copy section.
  3. **No digital copy**: **full brightness**, an `opticaldisc` or `record.circle` glyph where the availability mark
     goes, and no download actions.

  Collection views decide from `DigitalState` before they look at availability. `PhoneModel.Availability` is
  unchanged.
- **Library tab.** The digital library is unchanged. Album pages get a read-only **Your Copies** list linking to item
  pages, "Record label", and a `CopyArt` header. Artist pages get **In Your Collection**. Their gates become
  `library.isEmpty` (no tracks **and** no items), so a collection-only snapshot is a real library, not the sample
  offer.
- **Search tab.** It uses `LibrarySearch.run` off the main thread with the 150 ms debounce. Sections: **Label** (exact
  hits for "142", in both series), **Collection** (items with pills), then Artists, Albums and Songs. The tab is no
  longer gated on tracks.
- **Insights.** The Owned pane is shown as **Collection** (raw value kept) and is a port of the Mac cards.
  `PhoneModel.loadCollectionStats()` runs it detached through a `nonisolated static` helper.
- **Settings.** The Library section adds "Collection: 312 CDs · 48 vinyl · 97 downloads · 9 to digitize".
- **Widgets and watch commands.** `perform(.playAlbum(key:))` answers `GlanceCommandResult.failed("No digital copy")`
  for a key with no tracks. A `GlanceLink` whose `itemID` is set (`GlanceLink.item(id:)`) sets `pendingItemID`, and `PendingAlbumOpener` falls back to the
  item when `album(forKey:)` is nil.
- **Siri and Shortcuts.** `FindByLabelIntent(series:number:)` (new `CollectionIntents.swift`, with an
  `AppShortcutsProvider`: "Find CD 12 in Music Library"). Its dialog says "CD #12 is Kind of Blue by Miles Davis", it
  opens the item page, and it loads the library first through `PhoneModel.shared`.
- **No editing.** There are no new sync events.

## 7. Watch and widgets

### 7.1 Glance additions (`Sources/MusicLibraryGlance/Glance.swift`; every new field optional)

```swift
public var collection: Collection?          // Glance.init gains `collection: Collection? = nil`
public struct Collection: Codable, Hashable, Sendable {
    public var items: Int?, cds: Int?, vinyl: Int?, downloads: Int?
    public var toRip: Int?                   // CDs with no digital copy
    public var vinylToDigitize: Int?
    public var nextCD: Int?, nextVinyl: Int? // next free label per series
    public var recent: [Item]?               // ≤ 8, newest createdAt (as the iPhone's Recently Added), any medium, trackless included
    public var toRipList: [Item]?            // ≤ 8 unripped CDs, oldest bought first
    public struct Item: Codable, Hashable, Sendable, Identifiable {
        public var id: String                // item id
        public var albumKey: String
        public var title: String, artist: String
        public var year: Int?
        public var medium: String            // raw string ("cd" | "vinyl" | "download" | other): never an enum
        public var sticker: Int?
        public var digitized: Bool?
        public var playable: Bool?           // some of its songs are on this iPhone
        public var cover: String?            // coverName(albumKey: "item:" + id) for its own cover, else the album's
        public var purchasedOn: String?
        public var price: Decimal?
        public var stickerText: String? { get }   // computed, not encoded: "CD #12" / "Vinyl #12"
    }
}
```

- **`Glance.Owned` is unchanged in shape and meaning** (D16). `ownedCount` counts library albums with tracks that have
  any copy; `libraryAlbumCount` is unchanged; `recent` holds library albums only, one per key, using the latest dated
  copy's date and price. `boughtThisYear`, `spentThisYear` and `totalSpent` cover every copy.
- **`Glance.coverNames`** adds `collection.recent` and `collection.toRipList` covers.
- **`GlanceLink` gains no enum cases.** `RootView.open` switches over it exhaustively, so a new case would break the
  iPhone build before P2 lands. Instead, item links ride on the existing `album` host:
  `public static func item(id: String) -> GlanceLink` returns `.album(key: "item:" + id)`, and
  `public var itemID: String?` reads it back. Old phones look the key up as an album, find nothing and do nothing,
  and widgets ship with the app anyway. "Open the collection" uses the existing `.insights(.owned)`, which is the
  Collection pane.
- **`GlanceFormat.sticker(medium: String, number: Int) -> String`** returns "CD #12" or "Vinyl #12", and the plain
  number for an unknown medium.

### 7.2 Shelf index (`GlanceShelf`, MusicLibraryGlance)

```swift
public struct GlanceShelf: Codable, Hashable, Sendable {
    public static let currentVersion = 1
    public static let fileName = "shelf.json"
    public static let maxBytes = 2_000_000, maxEntries = 20_000
    public var version: Int
    public var generatedAt: Date
    public var entries: [Entry]              // labeled physical items, series then number
    public struct Entry: Codable, Hashable, Sendable, Identifiable {
        public var i: String                 // item id
        public var s: String                 // "cd" | "vinyl"
        public var n: Int
        public var t: String                 // title, ≤ 80 chars
        public var a: String                 // artist, ≤ 80 chars
        public var y: Int?
        public var d: Bool?                  // digitized
        public var c: String?                // cover name
        public var id: String { i }
    }
    public func entries(series: String, number: Int) -> [Entry]
    public func neighbors(series: String, number: Int) -> (previous: Entry?, next: Entry?)
    public var contentHash: String { get }   // FNV-1a over entries (not generatedAt)
    public var coverNames: Set<String> { get }
}
extension GlanceStore {
    public var shelfURL: URL { get }
    public func readShelf() -> GlanceShelf?
    public func writeShelf(_ shelf: GlanceShelf) throws           // atomic, fixed name
    public static func decodeShelf(_ data: Data) -> GlanceShelf?  // rejects > maxBytes, other versions, > maxEntries;
                                                                  // drops entries with bad cover names or series
}
// GlanceMessage additions: shelfKind = "shelf", shelfVersion = "v", shelfHash = "shelfHash" (refresh carries the watch's hash)
```

- **Phone side** (`GlanceFeed`/`WatchLink`):
  - After each full build, `Glance.shelf(collection:…)` is written to the app group.
  - When `contentHash` differs from the last one sent, or a watch `refresh` reports another hash, the phone cancels
    outstanding shelf transfers and calls `WCSession.transferFile(url, metadata: ["kind": "shelf", "v": 1, "hash": …])`.
    At about 100 bytes per entry, 3,000 items come to about 300 KB.
  - `WatchLink.covers` serves names from `glance.coverNames ∪ shelf.coverNames`, thumbnailed at 160 px from
    `GlanceCoverSource`s.
- **Watch side** (`WatchModel`):
  - The `nonisolated` `session(_:didReceive file:)` accepts only `kind == "shelf"`, `v == 1` and files of at most
    2 MB. It decodes with `decodeShelf` and writes **synchronously, before returning**, to the fixed `shelf.json`. No
    peer-supplied name is ever used. It then hops to the main actor.
  - `pruneCovers(keeping:)` keeps `glance.coverNames` ∪ the **shelf cover cache**: the 40 most recently looked-up
    shelf covers, listed in `shelf-covers.json` in the watch's store. This fixes the cache being wiped on every
    update.
- **Older and newer peers.** An old watch has no file delegate, so the file is dropped. A new watch with an old phone
  has no shelf and shows the "update the iPhone" state.
- **PrivacyInfo.** No new required-reason APIs: no file timestamps, no disk space, no new user defaults.
  `site/privacy.html` adds the shelf index (titles, artists, label numbers) to what goes to the watch.

### 7.3 Watch UI

The vertical pages are Now Playing · **Shelf** · Listening · Play. Shelf replaces Purchases and absorbs it.

- **`ShelfPage`.**
  - A **Find** button, then counts: "CD 312 · Vinyl 48 · 9 to rip".
  - **Recently added**: `collection.recent ?? owned.recent`.
  - **To Rip**: `toRipList`.
  - Rows show `stickerText` and a medium glyph. A trackless row reads "On your shelf · no digital copy".
- **`WatchFindPage`.**
  - A CD | Vinyl toggle and a big number.
  - The **Digital Crown** changes the number, moving through existing entries with detents. It starts at the last
    lookup or the highest number. ±1 taps are also available.
  - Below: cover, title, artist, year, "Ripped"/"Not ripped", and "← #141 · #143 →".
  - The lookup works offline from `shelf.json`. Covers come by message while the phone is reachable.
- **`AlbumPage` copy.** "Not on your iPhone. Download it there." stays for digitized albums. Not-digitized items say
  "No digital copy · Vinyl #12".
- **Empty states.** Stale copy becomes "Add CDs, records and downloads in Music Library on your Mac."

### 7.4 Widgets

`PurchasesWidget` is shown as **"Collection"**. Its kind stays `"Purchases"`, so widgets already placed survive. When
`collection` is nil (an older snapshot), it falls back to today's `owned` content.

| Family | Shows |
|---|---|
| Small | The latest addition in its case or sleeve with its label, and "Added 3 days ago" |
| Medium | Counts (CDs, Vinyl, To Rip) and 2 additions |
| Large | Counts, **"Next: CD #313 · Vinyl #49"**, 4 additions, this year's spend |
| Accessory rectangular (iOS + watch) | "312 CDs · 48 vinyl" / "9 to rip" |
| Accessory inline | "Next label: CD #313" |

- **Taps.** `GlanceLink.item(id:)` for an item, `.insights(.owned)` (the Collection pane) otherwise.
- **Play.** `PlayAlbumIntent` is offered only when `playable == true`.
- **Samples.** `GlanceSample` gains collection samples with both series.

## 8. Search keys

`CollectionSearchQuery.parse` (Core, `CollectionSearch.swift`) follows the `CatalogSearchQuery` pattern: it peels off
the collection keys and hands the rest to `SearchQuery.parse` as `base`. **None of these keys go into
`SearchFilterKey.all`**, and nothing is added to `is:`, `missing:` or `has:` (D13).

| Key (aliases) | Values | Meaning |
|---|---|---|
| `own:` (`medium:`, `media:`) | `cd`, `vinyl` (`lp`, `record`), `download` (`dl`), `physical`, `any`, `none`, raw other | The copy's medium; `own:none` = library albums with no copy |
| `ripped:` (`digitized:`) | `yes`, `no`, `partial`, `missing`, `other` | `DigitalState`: yes = has music from this copy (or digitized), no = needsDigitizing, other = otherCopy |
| `sticker:` (`labelno:`, `shelf:`) | `12`, `10-20`, `>=100`, `cd`, `vinyl`, `cd12`, `vinyl10-20`, `lp>300`, `none` | Label number in either or one series; `none` = physical without a label |
| `#12`, `cd#12`, `vinyl#12`, `lp#12`, `v#12` | shorthand | Exact label (`#12` = both series); search boxes only, for the items (songs and saved smart playlists read it as text, so "#9 Dream" still matches); saved as `sticker:` |
| `bought:` (`purchased:`) | the `added:` grammar (`2024`, `<90d`, `2020-2022`), `none` | Purchase day |
| `paid:` (`price:`) | `>20`, `0`, `10-15`, `none` | Price |
| `copies:` | `>1`, `2` | Copies with the same album key |
| `barcode:`, `catno:` | text | Release fields |

- **Collection filters apply across the whole query** (ANDed), as the catalog's do.
- **Base terms against an item** (`CollectionIndex`; one `Entry` per item, `IndexedText` and `CompiledTerm` reused):
  - Text and text fields match the item's own fields, `album_info` genres and the tracklist titles, merged with its
    linked tracks' text.
  - `label:` matches the item's record label, else the tracks' tag.
  - `year:` and `decade:` use `item.year`, else the tracks'.
  - Track-only terms (`format:`, `bits:`, `rate:`, `bitrate:`, `time:`, `track:`, `disc:`, `added:`, `is:…`,
    `missing:…`) are true when **any linked track** satisfies them.
- **Track results** (`LibrarySearch.run`):
  - With no collection filters, they're exactly `index.search(text)`.
  - With them, they're `index.search(base)` limited to the album keys of items matching the filters (`own:none` → keys
    with no copy). So `own:vinyl genre:jazz` lists the songs of your jazz records, and `ripped:no` lists no songs.
- **Label hits.** When the whole query is a label form (`#12`, `cd 12`, `vinyl 12`, or a bare 1–7 digit number), the
  exact items are returned in `labelHits`. Text results are **unchanged**, so "1999" and "21" still find songs. In the
  Collection page filter, a bare number jumps to the label. 8–14 digits match `barcode`, as text in the item's
  "all" field.
- **Smart playlists.** `LibrarySearch.tracks(matching:…)` with no collection keys calls `index.tracks(matching:)`
  unchanged (golden test). Playlists with collection keys refresh on `collectionVersion`.
- **Library CDs.** `CatalogSearchQuery` gains `own:any|cd|vinyl|download|none` (collection), with
  `CatalogSearchContext.collection: [String: Set<String>]` (record id → media). `is:owned` is unchanged.

```swift
public struct CollectionSearchQuery: Sendable {
    public var base: SearchQuery
    public var filters: [Filter]                         // own, ripped, sticker, bought, paid, copies, barcode, catno
    public var hasCollectionFilters: Bool
    public static func parse(_ text: String, now: Date = Date()) -> CollectionSearchQuery
    public static func labelForm(_ text: String) -> (series: StickerSeries?, number: Int)?   // whole-query label
    public static func canonical(_ text: String) -> String
    public static let keys: [(key: String, example: String, help: String)]
}
public struct CollectionIndex: Sendable {
    public static let empty: CollectionIndex
    public init(collection: MusicCollection, tracks: [Track], albumInfos: [String: AlbumInfo])
    public func search(_ query: CollectionSearchQuery, now: Date = Date()) -> [CollectionItem]
    public func search(_ text: String, now: Date = Date()) -> [CollectionItem]
    public func completions(for text: String, limit: Int = 8) -> [SearchCompletion]
}
public enum LibrarySearch {
    public struct Results: Sendable {
        public var library: SearchResults
        public var items: [CollectionItem]
        public var labelHits: [CollectionItem]
    }
    public static func run(_ text: String, index: SearchIndex, collectionIndex: CollectionIndex,
                           collection: MusicCollection, now: Date = Date(), autocorrect: Bool = true) -> Results
    public static func tracks(matching text: String, index: SearchIndex, collectionIndex: CollectionIndex,
                              collection: MusicCollection, now: Date = Date()) -> [Track]
}
```

## 9. Stats (`CollectionStats`, Core `CollectionStats.swift`, one pass, off the main thread)

```swift
public struct CollectionStats: Sendable {
    public init(collection: MusicCollection, tracks: [Track], playTotals: [Int64: PlayTotal],
                albumInfos: [String: AlbumInfo], now: Date = Date(), calendar: Calendar = .current, listLimit: Int = 50)
    public struct MediumShare: Sendable { medium, items, digitized, partial, otherCopy, toDigitize, missing, labeled, unlabeled, priced, spent, averagePrice }
    public struct SeriesStats: Sendable { series, labeled, unlabeled, highest: Int?, next: Int, gaps: [ClosedRange<Int>], gapCount, duplicates: [Int: [String]] }
    public struct Period: Sendable { start: PurchaseDay, spentByMedium: [String: Decimal], items: Int, cumulative: Decimal }
    public struct ItemRow: Sendable, Identifiable { item: CollectionItem, plays: Int, pricePerPlay: Decimal? ; id }
    // counts, media, series, spending, value, lists, breakdowns and facts as defined below
}
```

**Definitions:**

- **Counts.**
  - **Item**: a stored item or a derived download. **Physical**: cd, vinyl and other.
  - **Albums owned**: distinct album keys among items.
  - **Not in your collection** (the Borrowed badge): library album keys with tracks and no item. This replaces
    `libraryAlbumCount - ownedCount` and can't go negative.
- **Per medium (`MediumShare`).** The digital-state counts follow `DigitalState`. `labeled` and `unlabeled` apply to
  physical items only.
- **Digitization.**
  - **Digitized share**: physical items with `hasMusic` ÷ physical items.
  - **To Digitize**: physical items with `needsDigitizing`, oldest bought first (undated by `createdAt`).
  - **To Rip**: CDs among them. **Waiting for a turntable**: vinyl among them.
- **Series (`SeriesStats`, per series).**
  - Labeled and unlabeled counts (physical items of that medium with no number), and `highest`.
  - `next` = `highest + 1` (1 when empty, capped at the maximum).
  - `gaps`: numbers missing from 1…highest, folded into ranges.
  - `duplicates`: numbers used by more than one item.
- **Spending.**
  - `totalSpent`: priced items, derived downloads included, each copy separately.
  - `spentThisYear` / `boughtThisYear`: `purchasedOn.year` = the current calendar year.
  - Average and median over priced items, per medium and overall; priciest and cheapest.
  - Timeline: monthly when dated purchases span less than 24 months, else yearly; stacked by medium, with a
    cumulative line. Undated items are left out.
- **Value** (per album key with music).
  - Spend = the sum of that key's priced copies.
  - Plays and listened seconds = that key's tracks, **counted once** even with two copies.
  - **Cost per play** = Σ spend ÷ Σ counted plays over keys with plays; **cost per hour** works the same way.
  - **Best value**: lowest spend ÷ plays (at least 1 play).
  - **Still in the wrapper**: items with music whose key has 0 counted plays. Physical items with no music are listed
    under To Digitize, not here.
- **Needs details**: editable items with no date or no price, plus physical items with no label number.
- **Breakdowns** (items and spend for each):
  - Artists (the item's artist).
  - Genres: the linked tracks' genres, else `album_info` genres.
  - Decades: `item.year`, else the tracks'.
  - Record labels: `record_label`, else the tracks' tag.
- **Facts**: oldest release among physical items; newest addition; most copies of one album; biggest box (largest
  `discCount`); collection runtime (the duration of distinct keys with music, plus the `album_info` tracklist length
  for trackless items when known); "Waiting for a turntable: 31 records".
- **Glance mapping**:
  - `collection.items/cds/vinyl/downloads` come from the item counts.
  - `toRip` and `vinylToDigitize` come from the To Digitize subsets.
  - `nextCD` and `nextVinyl` come from `SeriesStats.next`.
  - `Owned` keeps its definitions (D16).
- **`LibraryStats`** (the Library pane) is unchanged; it describes the digital music.

## 10. Sync and export

- **What reaches the phone.**
  - Every item, through `collection_items` in the snapshot.
  - The `album_ownership` projection, for older phones.
  - Every item cover: `SyncMacSession.sync` reads `database.collectionCoverPaths()` and passes them to
    `SyncPlan(tracks:library:collectionCovers:libraryRoot:phone:)`. They're always wanted, like album covers, so the
    phone never deletes them, and they count toward `SyncPlanSummary.needed`.
  - `album_info` for item keys, and artist info and photos for collection-only artists.
  - Digitized songs, only as the selection says.
- **No protocol changes.** There are no new `SyncMessage`, `SyncEvent.Kind` or `ExportItem` cases and no new managed
  folders. Legacy `.purchase` events still apply (§3.4).
- **Collection on iPhone** (per phone, in Mac `SyncStore`, stored in UserDefaults by phone ID): Off / Digitized CDs /
  Digitized vinyl / Everything digitized.
  - It becomes `collection.syncItems(scope)`, implicit `.album` include rules placed **before** the user's rules:
    `SyncSelection.resolve(_:implicit:)`, `apply(_:include:tracks:implicit:)` and `dropMissing(tracks:implicit:)`.
  - Compaction counts implicit adds when it decides whether an exclude still matters. It never drops a user include
    because an implicit rule covers it, so turning the scope off doesn't remove albums the user added.
  - Remove from iPhone (an exclude) wins, and new rips join on the next sync.
  - The page shows "Digital copies of 330 of your 399 CDs and records: 4,210 songs, 98 GB".
- **Sync Now** is enabled when the selection resolves to songs **or** the collection isn't empty.
- **Phone requests.** Download and Remove on item pages and in Ready to Download send `SyncRequest(.album)`, which older
  Macs understand.
- **Export.** When the database is exported, `LibraryExporter.plan(…collectionCovers:)` copies the referenced covers
  next to `Artist Images` (never overwriting, as always), and `ExportPreview` doesn't list them as albums. `backUp` is
  unchanged.

## 11. Copy and doc changes (owned by the Docs package)

- **README.md.**
  - A new **Your collection** section: CDs, vinyl and downloads with label numbers per medium, Find by Label, To
    Digitize, item pages, adding by barcode, Catalog Without Ripping, Collection on iPhone.
  - Highlights and Insights become a Collection pane.
  - A search key table with the collection keys, and the catalog `is:owned` vs `own:` difference.
  - The iPhone steps (Collection tab, read-only), widgets ("Collection") and the watch (Shelf, Find).
  - Fix the stale line about editing Your Copy on the phone.
- **site/index.html.** Feature copy in line with the README: the Owned definition becomes the Collection, plus a
  collection feature block and screenshot tab. **site/privacy.html**: the watch gets a shelf index.
- **docs/app-store/README.md.** A new subtitle, promotional text, keywords, description and review notes, all marked
  "to review in App Store Connect" (promotional text can change any time). The sample library now shows vinyl and
  unripped CDs.
- **docs/ios-companion-plan.md:188.** Ownership is read-only, edited on the Mac.
- **CHANGELOG.md `## Unreleased`.** Plain bullets with absolute links for:
  - Collection and Shelf; vinyl and labels per medium; unripped CDs and Catalog Without Ripping; Find by Label (Mac,
    iPhone, watch, Siri); search keys; the Collection pane; Your Copies; the Collection widget; Collection on iPhone;
    "Record label" rename.
  - A note that deleting a copy with an older version has to be repeated.
  - A note that older phones show vinyl-only albums as not owned.
  - A note that an older Mac (after a downgrade) doesn't see the label numbers of second CD copies of an album, so it
    may suggest one already in use; Label Check finds it after upgrading again.
- **AGENTS.md.**
  - Replace the AlbumOwnership bullet with a Collection bullet: `collection_items`, `album_ownership` as a projection
    (format NULL/'digital' only, CD-only labels), reconcile, legacy ids, covers in `Music/Collection Covers`, search
    keys outside `is:`, `GlanceShelf`.
  - Extend the JewelCase convention to `RecordSleeve`, `LabelSticker(series:)` and `StickerPill` (twin copies).
- **docs/screenshots/.** New `collection.png` (Shelf), `collection-item.png`, `iphone-collection.png` (composed with
  `scripts/compose-iphone-screenshots.swift`) and a watch Find screen in `watch.png`, taken after the UI packages merge.

## 12. Out of scope

- **Phone-side editing.** A future hook would be an optional `SyncManifest.collectionDrafts`, never a new
  `SyncEvent.Kind`.
- **Shopping and library catalogs.** Vinyl shopping and vinyl Library CDs scans stay out; both stay CD-only.
- **Imports from other tools.** CSV or Discogs collection import is out (a later optional package:
  `CollectionCSV.swift`).
- **Shelf extras.** Spine and shelf views, empty-slot tiles, renumber/swap, configurable prefixes, and swipe or haptic
  extras are out.
- **More media and multi-album items.** Real cases for cassettes, SACD and so on are out; they read as `.other`. So is
  one item linked to several album keys (box sets imported as separate albums).
- **Per-copy tracklists.** Edition-specific tracklists per copy are out: `album_info` stays per album key.
- **Renames.** Renaming `AlbumTracklist.Row.owned` is out.

## 13. Work packages

**Order.**

1. **P0 Core** lands first, and leaves `swift build`, `swift test` and the iOS `xcodebuild` green, with the apps
   unchanged and still compiling against the deprecated shims.
2. **P1 Mac**, **P2 iPhone**, **P3 Watch and widgets**, and **P4 Docs** then run in parallel. No file is in two
   packages, and each one compiles against P0 alone.
3. **P5 Cleanup** runs alone after everything else has merged.

**Invariants every package checks before merging:**

- `Database.schemaVersion == 14`, `SyncProtocol.version == 3`, `Glance.currentVersion == 1`, and
  `GlanceShelf.currentVersion == 1`.
- No new cases in `SyncMessage`, `SyncEvent.Kind`, `ExportItem` or `GlanceCommand`, and no new enum-typed fields in the
  Glance.
- `album_ownership.format` is only ever written as NULL or `'digital'`, and `label_number` only holds CD numbers.
- Every cover or item path goes through `LibraryPath.resolve` and `CollectionCovers.isFileName`; the watch writes only
  fixed names.
- `Table` cells never read `@Environment(AppModel.self)`. Secondary text uses `.subtext`.
- Core has no AppKit, UIKit, `XMLDocument` or `Process`, and every new type is `Sendable`.
- MusicBrainz and CAA traffic is user-initiated and rate-limited, and tests stay off the network.

### P0: Core

**Owns.**

- **New Core sources**: `Sources/MusicLibraryCore/Collection.swift`, `CollectionStore.swift`,
  `CollectionLegacy.swift`, `CollectionCovers.swift`, `CollectionSearch.swift`, `CollectionStats.swift`,
  `CollectionLookup.swift`.
- **Edited Core sources**:
  - `AlbumOwnership.swift`: deprecation notes on `OwnershipMark`, `OwnershipStats`, `including`,
    `nextLabelNumber` and `album(labeled:)`.
  - `Database.swift`: the `migrate()` calls only.
  - `SyncEvents.swift`: the `.purchase` branch → `applyLegacyPurchase`, then reproject.
  - `SyncFiles.swift`: `SyncPlan(collectionCovers:)`.
  - `SyncSession.swift`: passes `collectionCoverPaths()`.
  - `SyncSelection.swift`: the `implicit:` overloads.
  - `LibrarySnapshot.swift`, `LibraryExport.swift`, `LibrarySort.swift` (`CollectionSort`).
  - `AlbumInfo.swift`: `TracklistEntry.position`.
  - `MusicBrainz.swift`: parse the track `number` into `position`.
  - `LibraryCatalogMatching.swift`: `MBReleaseSummary.isVinyl`, `medium`.
  - `CDShopping.swift`: an editions parser parameterized by medium; the CD default is unchanged.
  - `LibraryCatalogIndex.swift`: `own:` and `CatalogSearchContext.collection`.
  - `GlanceBuilder.swift`.
- **Glance target**: `Sources/MusicLibraryGlance/Glance.swift`, `Sources/MusicLibraryGlance/GlanceLinks.swift`.
- **Sample library**: `Sources/SampleLibraryMaker/Catalog.swift`, `main.swift`, `Artwork.swift`, the regenerated
  `iOS/MusicLibraryMobile/SampleLibrary.bundle/**` (via `scripts/make-sample-library.sh`, still `journal_mode=DELETE`),
  and `scripts/make-sample-library.sh` only if it needs a change.
- **Tests**: everything under `Tests/MusicLibraryCoreTests/` listed below, plus new fixtures.

**Scope.**

- All of §3, plus the Core halves of §4, §8, §9 and §10.
- **App code keeps compiling unchanged.** Every new parameter on an existing public API has a default:
  `Glance.init(collection:)`, `SyncPlan.init(collectionCovers:)`, `TracklistEntry.init(position:)` and
  `CatalogSearchContext.init(collection:)`. No case is added to an enum that app code switches over exhaustively
  (`GlanceLink`, `GlanceWidgetKind`, `GlanceCommand`, `AlbumPurchase.Format`, `SearchQuery.*`). Deprecations are
  written in doc comments only.
- **`Glance.build` gains a new overload** (the old `purchases:` one stays as a deprecated wrapper):

  ```swift
  public enum GlanceCoverSource: Hashable, Sendable { case track(Track), file(relativePath: String) }
  public static func build(tracks: [Track], present: Set<Int64>, plays: [Play], likedDates: [Int64: Date],
                           collection: MusicCollection, playTotals: [Int64: PlayTotal], playing: Playing?,
                           currencyCode: String, now: Date = Date(), calendar: Calendar = .current,
                           listLimit: Int = 8) -> (glance: Glance, covers: [String: GlanceCoverSource])
  public static func shelf(collection: MusicCollection, now: Date = Date()) -> (shelf: GlanceShelf, covers: [String: GlanceCoverSource])
  ```
- **Adding items** (`CollectionLookup.swift`):

  ```swift
  public struct CollectionReleaseQuery: Hashable, Sendable {
      public var text: String; public var medium: CollectionMedium
      public init(text: String, medium: CollectionMedium)
      public var barcode: String? { get }                     // 8–14 digits
      public func luceneQuery(loose: Bool = false) -> String
  }
  public struct CollectionEdition: Identifiable, Hashable, Sendable {
      public var id: String; public var title: String; public var artist: String; public var date: String
      public var country: String; public var recordLabel: String; public var catalogNumber: String; public var barcode: String
      public var formatDetail: String; public var discCount: Int; public var trackCount: Int
      public var releaseGroupId: String?; public var releaseGroupTitle: String; public var medium: CollectionMedium?
  }
  extension MusicBrainzClient {
      public func searchEditions(_ query: CollectionReleaseQuery) async throws -> [CollectionEdition]   // loose + catno retries
  }
  public enum CollectionDraft {
      public static func item(from edition: CollectionEdition, medium: CollectionMedium, sticker: Int?, now: Date = Date()) -> CollectionItem
      public static func item(album: AlbumSummary, tracks: [Track], medium: CollectionMedium, sticker: Int?, now: Date = Date()) -> CollectionItem
  }
  ```
- **Sample library.** `SampleCatalog.Album` gains `medium` and `sticker`. The sample gets:
  - labeled ripped CDs from CD #1;
  - 2 trackless vinyl (Vinyl #1, #2) with `Artwork` covers in `Music/Collection Covers`;
  - 1 digitized vinyl (Vinyl #3, source rip);
  - 2 unripped CDs;
  - one album owned on both CD and vinyl;
  - one stored download.

**Tests.**

- **New `CollectionModelTests`.**
  - `Sticker.parse` forms, text and spoken.
  - Series independence (nextNumber, taken and duplicates per series; CD #12 and Vinyl #12 coexist).
  - Gaps and firstGap, neighbors.
  - Medium raw round trip, unknown → `.other`.
  - Every `DigitalState` row of the table.
  - Derived downloads next to a CD; mark precedence and `more`.
  - `matches` order; `syncItems`.
  - Linker: backfill, exact relink only, no release-group auto-link, source inference.
- **New `CollectionStoreTests`.**
  - The table is created with `user_version` still 14.
  - Migration of NULL / `'digital'` / `'vinyl'` (→ CD) / labeled / duplicate-label / orphan rows, with deterministic
    ids; idempotent reopen.
  - The projection holds the primary copy's own price (never a sum), only CDs and downloads, and CD-only labels.
  - **Legacy reader SQL matrix**: run the exact 1.17, 1.18 and 1.19/1.20 `SELECT`s on a projected DB → no vinyl, no
    vinyl numbers, correct CD labels.
  - Reconcile of an older-Mac edit; an older-Mac delete never deletes; a snapshot without the table → synthesized
    items with the same ids.
  - Malformed rows (sticker 0 / 10^7, `../x`, `/abs`, `Artist Images/x.jpg`, bad MBIDs, a 1 MB notes field, a bad id)
    → nulled or dropped and counted.
  - Duplicate legacy labels → no failure.
  - `saveCollectionItem` refuses derived and `.other` items; `rekeyCollection`.
- **New `CollectionSearchTests`.**
  - Every key and alias; `#12` in both series; `labelForm`; `canonical`.
  - A **golden test**: a corpus of existing queries (`label:"blue note"`, `format:flac`, `is:hires`, `missing:label`,
    `year:1990-1999`, `-genre:jazz`, OR groups) gives identical `SearchQuery.parse` and `index.search` results, and
    smart playlists without collection keys give identical tracks.
  - Bare "1999" keeps its text results; track restriction; `own:none`.
  - Old-reader degradation: `SearchQuery.parse("own:vinyl")` is text and matches nothing.
- **New `CollectionStatsTests`.** Every §9 definition, including: trackless items counted; Not in Collection never
  negative; plays counted once per key; cost per play over keys with music only; gaps folded.
- **New `CollectionLookupTests`.** `CollectionReleaseQuery` Lucene; `Medium(musicBrainzFormats:)`; parsing a real
  MusicBrainz vinyl release-search response captured once (`Fixtures/mb_release_search_vinyl.json`) and the existing
  barcode fixtures.
- **Updated suites.**
  - `OwnershipTests`: keep "unknown format reads as CD" for `albumPurchases`.
  - `SyncSelectionTests`:
    - legacy events change only the primary CD/download copy;
    - a nil event keeps a labeled copy;
    - vinyl is untouched;
    - the newest change wins;
    - implicit rules: excludes win, user includes survive scope off, compaction.
  - `SyncTests` (real TLS):
    - collection covers are sent and accepted by a real `SyncReceiver` at `Music/Collection Covers/…`;
    - they aren't deleted on the next sync;
    - the snapshot keeps `collection_items`;
    - other folders are still refused.
  - `LibraryExportTests`: covers are exported.
  - `LibrarySnapshotTests`: the collection is loaded; legacy synthesis; in-memory reconcile; dates shifted;
    `isEmpty`.
  - `GlanceTests`:
    - an old payload decodes with `collection == nil`;
    - a new payload decodes with extra keys;
    - `Owned` is library-only and one per key;
    - shelf round trip; rejection of other versions, oversize and bad names;
    - `coverNames`; `GlanceLink.item(id:)` round-trips through its URL and `itemID`; existing links are unchanged.
  - `AlbumInfoTests`: old JSON without `position`.
  - `CatalogIndexTests`: `own:`, with `is:owned` unchanged.
  - `CDShoppingTests`: CD behaviour unchanged; vinyl editions only with `medium: .vinyl`.
  - `LibrarySortTests`: `CollectionSort`.
  - `SampleLibraryTests`: both series present, a trackless item's cover resolves, no vinyl in `album_ownership`, not in
    WAL mode.

### P1: Mac app

**Owns.**

- **Edited**: `Sources/MusicLibrary/AppModel.swift`, `ContentView.swift`, `MusicLibraryApp.swift`, `SettingsView.swift`,
  `LibraryViews.swift`, `AlbumViews.swift`, `ArtistViews.swift`, `OwnershipViews.swift`, `JewelCase.swift`,
  `Support.swift`, `AlbumCoverSheet.swift`, `CDController.swift`, `CDView.swift`, `ImportController.swift`,
  `ImportView.swift`, `InsightsView.swift`, `OwnedInsightsView.swift`, `SearchViews.swift`, `IPhoneSyncView.swift`,
  `SyncStore.swift`, `ExportViews.swift`, `LibraryCatalogViews.swift`, `LibraryCatalogStore.swift`,
  `LibraryCatalogDownload.swift`, `CDShopViews.swift`.
- **New**: `CollectionViews.swift` (`CollectionView`, `CollectionCell`, `CollectionTable`, `LabelCheckSheet`),
  `CollectionItemDetail.swift`, `CollectionEditor.swift` (`CollectionItemEditor`, `StickerField`, `LinkAlbumPicker`,
  `BulkAddSheet`), `AddToCollectionSheet.swift`, `FindByLabelPanel.swift`, `CollectionCoverSheet.swift`,
  `RecordSleeve.swift`, `CDCollectionPanel.swift`.

**Scope.** All of §4 and §5, plus the Mac halves of §10 (scope picker, Sync Now gate, summary, export covers line).

`AppModel` gains:

- state: `collection`, `collectionIndex`, `collectionVersion`, `collectionStats`, `loadCollectionStatsIfNeeded()`;
- actions: `saveItem`, `deleteItem`, `item(id:)`, `showItem(id:)`, `showShelf(query:)`;
- the linker pass after `reloadLibrary`; `rekeyCollection` on retags; the `removeFromLibrary` adoption;
- `runSearch` and `smartPlaylistTracks` through `LibrarySearch`;
- `syncArtistInfo`, `albumRequest` and `concertArtists` including items;
- `purchases` fed from `collection.legacyPurchases` for any view not yet moved.

**Core API consumed.**

- Types: `CollectionItem`, `CollectionMedium`, `StickerSeries`, `Sticker`, `DigitalSource`, `DigitalState`,
  `CopyMark`, `CollectionScope`, `CollectionItemRoute`, `CollectionSyncScope`, `CollectionSort`, `MusicCollection`
  (all members in §3.2), `CollectionLinker.changes(items:tracks:)` / `suggestions(for:albums:tracks:)`.
- Database: `collectionItems()`, `saveCollectionItem(_:at:)`, `saveCollectionItems(_:at:)`, `deleteCollectionItem(id:)`,
  `applyCollectionChanges(_:at:)`, `rekeyCollection(from:to:at:)`.
- Covers: `CollectionCovers.write(_:itemID:root:)`, `adopt(albumCover:itemID:root:)`, `url(_:root:)`.
- Search: `CollectionSearchQuery.parse/labelForm/canonical/keys`, `CollectionIndex`, `LibrarySearch.run/tracks`.
- Stats: `CollectionStats.init(collection:tracks:playTotals:albumInfos:now:calendar:listLimit:)`.
- Adding: `CollectionReleaseQuery`, `MusicBrainzClient.searchEditions(_:)`, `CollectionDraft.item(from:medium:sticker:now:)`
  / `item(album:tracks:medium:sticker:now:)`, `CoverArtClient.fetchFront(releaseId:releaseGroupId:size:)`.
- Sync: `SyncSelection.resolve(_:implicit:)`, `contains(_:tracks:implicit:)`, `apply(_:include:tracks:implicit:)`,
  `dropMissing(tracks:implicit:)`, `MusicCollection.syncItems(_:)`.
- Catalog: `CatalogSearchContext(owned:onList:siteLibrary:collection:)`.

**Tests.** The logic is covered by P0. The manual checklist:

1. Migrate a copy of a real library and check that every CD keeps its label.
2. Add vinyl by barcode in an Add & Next loop.
3. Check that a duplicate label is refused within a series and allowed across series.
4. Rip an unripped CD item: it links on the first track, with no second item.
5. Catalog Without Ripping, then eject.
6. Answering No keeps existing items.
7. Remove an album: the item keeps its cover and reads Not ripped.
8. Do a needle-drop import linked to a vinyl.
9. Run ⌘L find with neighbors.
10. Sync a collection-only phone.
11. Try every theme.
12. Build with `scripts/build-app.sh`.

### P2: iPhone app

**Owns.**

- **Edited**: `iOS/MusicLibraryMobile/PhoneModel.swift`, `RootView.swift`, `LibraryViews.swift`, `Components.swift`,
  `AlbumPage.swift`, `ArtistPage.swift`, `SearchView.swift`, `InsightsViews.swift`, `OwnedInsightsViews.swift`,
  `SettingsView.swift`, `SyncView.swift`, `JewelCase.swift`, `CoverImage.swift`, `GlanceFeed.swift`, `WatchLink.swift`.
- **New**: `CollectionViews.swift` (`CollectionTab`, `CollectionHome`, `CollectionListPage`, `CollectionRoute`,
  `ReadyToDownloadPage`, `LabelCheckPage`), `CollectionItemPage.swift`, `FindByLabelCard.swift`, `RecordSleeve.swift`,
  `CollectionIntents.swift`.

**Scope.**

- All of §6.
- The phone side of §7: `GlanceFeed.Inputs.collection` and the `GlanceCoverSource` thumbnails; writing the shelf;
  `WatchLink` sending it with `transferFile`, resending on a `refresh` hash mismatch, and serving shelf covers.
- `PhoneModel` gains `collection`, `collectionIndex`, `collectionStats`, `loadCollectionStats()`, `item(id:)`,
  `copyMark(for:)`, `pendingItemID`, and `CollectionLegacy.overlay` replacing `refreshPurchases`.
- `perform(.playAlbum)` for trackless keys.
- Swift 6 with main-actor default isolation: off-main helpers are `nonisolated static`.

**Core API consumed.**

- Snapshot: `LibrarySnapshot.collection/collectionIndex/labelUnreadable/isEmpty/coverURL(item:)`.
- Collection: `MusicCollection` (§3.2), `CollectionItem`, `Sticker.parse`, `StickerSeries`, `DigitalState`, `CopyMark`,
  `CollectionScope`, `CollectionItemRoute`, `CollectionSort`, `CollectionLegacy.overlay(events:on:albumKey:)`.
- Search and stats: `LibrarySearch.run`, `CollectionSearchQuery.labelForm`, `CollectionStats.init(...)`.
- Glance and links: `Glance.build(tracks:present:plays:likedDates:collection:playTotals:playing:currencyCode:now:calendar:listLimit:)`,
  `Glance.shelf(collection:now:)`, `GlanceCoverSource`, `GlanceStore.writeShelf/shelfURL`, `GlanceShelf.contentHash/coverNames`,
  `GlanceMessage.shelfKind/shelfVersion/shelfHash`, `GlanceLink.item(id:)`, `GlanceLink.itemID`.

**Tests.** Build with `xcodebuild -project iOS/MusicLibraryMobile.xcodeproj -scheme MusicLibraryMobile -destination
'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`. Then check on a simulator:

- the sample library;
- an old snapshot with no table;
- a collection-only snapshot;
- Ready to Download → Download All;
- Find by Label with neighbors;
- the Siri intent.

Then on the device, via devicectl.

### P3: Watch and widgets

**Owns.**

- **Edited**: `iOS/MusicLibraryWidgets/PurchasesWidget.swift`, `GlanceSample.swift`, `WidgetSupport.swift`,
  `MusicLibraryWidgets.swift`, `iOS/MusicLibraryWatch/WatchModel.swift`, `WatchPages.swift`,
  `MusicLibraryWatchApp.swift`, `iOS/Shared/PlaybackIntents.swift` (only if Play gating needs it).
- **New**: `iOS/MusicLibraryWatch/ShelfPage.swift` (`ShelfPage`, `WatchFindPage`).

**Scope.** The watch and widget halves of §7:

- the widget shown as "Collection", with its kind unchanged, families, taps and Play gating;
- watch shelf receipt with validation, synchronous write, the bounded shelf cover cache in `pruneCovers`, the Shelf and
  Find pages, the "update the iPhone" state, and copy fixes;
- `PrivacyInfo.xcprivacy` files left untouched (confirm no new APIs).

**Core API consumed** (MusicLibraryGlance only):

- `Glance.collection`, `Glance.Collection`, `Glance.Collection.Item` (including `stickerText`), `Glance.coverNames`;
- `GlanceShelf`, `GlanceShelf.Entry`, `entries(series:number:)`, `neighbors(series:number:)`, `coverNames`;
- `GlanceStore.readShelf()/writeShelf(_:)/decodeShelf(_:)/shelfURL/pruneCovers(keeping:)`;
- `GlanceMessage.shelfKind/shelfVersion/shelfHash`;
- `GlanceLink.item(id:)`, `GlanceLink.itemID`, `GlanceFormat.sticker(medium:number:)`.

**Tests.** `GlanceTests` in P0 cover the data. Manual checks:

- the widget gallery in both series;
- paired simulators: an old phone with the new watch (update state), and the new phone with an old watch build;
- an offline Find;
- covers that survive a glance update.

### P4: Docs

**Owns.** `README.md`, `site/index.html`, `site/privacy.html`, `docs/app-store/README.md`, `docs/ios-companion-plan.md`,
`CHANGELOG.md`, `AGENTS.md`, `docs/screenshots/*` (new `collection.png`, `collection-item.png`,
`iphone-collection.png`, an updated `watch.png`), and `docs/physical-collection-plan.md` (this file: mark it done at
the end).

**Scope.** §11. The text work can start right after P0. The screenshots, the final README and site pass, and the
App Store screenshots wait until P1–P3 have merged.

**Core API consumed.** None (the key names in §8 and the copy in §5–§7).

**Tests.** `scripts/build-site.sh` builds, and the README and site copy match.

### P5: Cleanup (after P1–P4 merge, alone)

**Owns.** Whatever files still reference the removed symbols:

- `Sources/MusicLibraryCore/AlbumOwnership.swift`, `GlanceBuilder.swift`, `LibrarySnapshot.swift`, `Collection.swift`;
- `Sources/MusicLibrary/OwnershipViews.swift`, `Support.swift`, `JewelCase.swift`, `AppModel.swift`;
- `iOS/MusicLibraryMobile/JewelCase.swift`, `CoverImage.swift`, `PhoneModel.swift`;
- `Tests/MusicLibraryCoreTests/OwnershipTests.swift`.

**Scope.**

- Remove `OwnershipMark`, `OwnershipStats` (and `OwnedAlbum`, `FormatShare`), `AlbumPurchase.including`,
  `nextLabelNumber` and `album(labeled:)`.
- Remove the old `Glance.build(purchases:)`, `MusicCollection.legacyPurchases`, `LibrarySnapshot.purchases`,
  `AppModel.purchases/purchaseRecords/setPurchase` and `PhoneModel.purchases/purchase(for:)`.
- Remove the `JewelCase(ownership:)`/`CoverThumb(ownership:)`/`CoverImage(ownership:)` inits, plus
  `LabelNumberField`, `CDOwnershipPanel`, `CDOwnershipSheet` and `AlbumOwnershipSection`.
- Keep `AlbumPurchase` (legacy Codable, projection, migration), `TrackPurchase` and `PurchaseDay` (Concerts use it).

**Tests.** The full `swift test`, the run with `MUSICLIB_TOOLS_DIR=build/tools`, and the iOS build. Keep the
legacy-reader assertions ("unknown format reads as CD", the pre-label-number snapshot).

## 14. As implemented: deviations from the plan

- **Older apps' edits (D9, §3.4).** Telling an older app's NULL from a newer app's clear needed the writer markers
  (`Database.markLegacyWriters`, `CollectionLegacy.Writer`), added during P0 review and already described in §3.4; a
  row that isn't the projection counts as an older app's edit whatever its time, so a Mac with a slow clock isn't
  ignored. An owned album with neither album nor artist keeps its empty title (`CollectionItem.isNamed`).
- **Migration tests.** Beyond the P0 list: `LegacyLibraryMigrationTests` open libraries made by the released code of
  1.14–1.20 (`Tests/MusicLibraryCoreTests/Fixtures/legacy-libraries`), `DowngradeRoundTripTests` replay the exact 1.17,
  1.18 and 1.20 writes, and `MigrationRehearsalTests` (opt-in, `MUSICLIB_MIGRATION_REHEARSAL`) runs the same checks on a
  copy of a real library. After P5, `Tests/MusicLibraryCoreTests/LegacyOwnership.swift` keeps private copies of 1.20's
  ownership algorithms so they still compare against the old behavior.
- **Linker.** A missing release ID is never backfilled from another copy's songs (source `.same`); only the release
  group, which every edition shares, is. Albums whose songs are retagged into several keys move their items to the
  biggest part.
- **Mac sync gate (§10).** The Mac doesn't tidy the iPhone selection or plan a sync until the open library's collection
  is built (`SyncContext.collectionReady`; a sync waits up to 8 s, then refuses), so a launch can't drop Remove from
  iPhone rules for albums only Collection on iPhone adds.
- **CD insertion (§4.3, §5.1).** "Ask whether a CD is yours when it's inserted" is **off** by default: a CD that isn't
  in the collection is added (the panel's toggle is on) unless the setting is turned on. Ripping or cataloging another
  edition never copies that edition's barcode, catalog number, record label, country or format into an item that
  names another release.
- **Adding (§4.1).** Lookups run on Return (barcode, then words, then catalog number), not as you type, to keep
  MusicBrainz traffic user-initiated; a barcode with one match is picked and the next Return adds it.
- **Item page (§5.3).** Switching a labeled CD or record to another medium asks first (its number comes off) and can be
  undone. Items without a label step along the others without one.
- **Import page (§4.4).** Files added for one item (Import a Transfer…, Import Files…, a CD ripped to the queue) are a
  batch of their own, and the songs' price and date go onto the chosen item only where it has none
  (`CollectionItem.takeSongsPurchase`).
- **Insights (§5.7).** The breakdown card is "Record Labels & Countries"; the runtime fact says how many albums it covers
  ("across 8 of 12 albums"); album-info genres are capitalized. Both apps open on the Collection pane.
- **iPhone (§6).** The tab choice is kept in app storage (it survives the app being closed) and the default is settled
  once the library has loaded, so the tab doesn't jump while the snapshot loads. Siri phrases can't hold a number, so
  the labels in use are `LabelEntity` values given to Siri (`updateAppShortcutParameters` when they change), with
  `OpenCollectionItemIntent` and `PhoneModel.pendingLink` opening the item; the series-and-number form stays for
  Shortcuts. Find by Label reads digits in any script (`Sticker.typedNumber`).
- **Glance and watch (§7).** `Glance.Collection.Item` gained `addedOn`, and `collection.recent` is sorted by date added
  (To Rip stays oldest bought first). The watch accepts any validated shelf (no `generatedAt` check), keeps Find's
  series and last numbers in `watch-find.json` in its store instead of user defaults, and an older watch app (no shelf
  hash in its refresh) isn't sent the index. Widgets' accessory families show two lines, and next labels only for the
  series you have.
- **Visuals (§5.9).** The CD hinge sticker reads "CD 12" and its number scales with the strip; the vinyl disc has a
  light rim; grid cells drop the status mark the status line already states.
- **Docs (§11, P4).** The README, site, privacy page, App Store copy (proposed, marked "to review"), CHANGELOG and
  AGENTS.md are updated; the new screenshots (`collection.png`, `collection-item.png`, `iphone-collection.png`, the
  watch Find screen) and the site's Collection screenshot tab wait for a real library window, so the site's collection
  block has no screenshot yet.
