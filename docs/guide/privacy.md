# Privacy

Music Library has no account, no cloud service of its own, no ads, no analytics and no tracking. Your library, your
listening history and your settings stay on your devices. The app talks to other services only to look things up, and
most of them only once you turn them on. The [privacy policy](https://davidlago.github.io/music-library/privacy.html)
has the formal version.

## On the Mac

Everything is in your library folder and your Mac's preferences. API keys, secrets, your library PIN and your Claude and
OpenRouter keys are kept in your keychain.

| Service | When | What it receives |
|---|---|---|
| MusicBrainz and the Cover Art Archive | Matching, covers, artist and album info | Titles, artists, IDs, barcodes |
| Wikipedia, Wikidata, Wikimedia Commons | Descriptions and photos | Artist and album names and IDs |
| Deezer | Choosing an artist photo | The artist's name |
| AcoustID | Only with your key, when fingerprinting | An audio fingerprint and the song's length |
| AccurateRip | Checking rips | The disc's identifier |
| Last.fm | Only when you connect it | What you play, and info lookups |
| Ticketmaster, JamBase | Only with your keys | Your artists' names and the area searched (a coarse cell around your ZIP code, not the code itself) |
| Apple's geocoder | When you enter a ZIP code | The ZIP code |
| Your library's catalog website | Only once you open Local Library CDs | Searches, and your card number and PIN if you sign in (sent only to that site) |
| Apple's iTunes Search | When you open a library CD you don't own, or ask for a song preview | The album, artist or song |
| Discogs | When you search it for an edition you own, and for the track lists of copies found there | What you type (barcode, words or catalog number) and release IDs |
| Discogs, eBay, CDandLP, Alibris, Frankfurter | Only when you shop for a CD or record | Its barcode, catalog number or names |
| Anthropic (Claude API) | Only with your key, while the Radio DJ is on the air | The page's details, your questions, photos you show it (without location or camera details) and the rows of collection searches it runs |
| OpenRouter (and the model's provider) | Only with your key and an OpenRouter model chosen, while the Radio DJ is on the air | The same as Anthropic above |

Downloading artist and album info can be turned off in **Settings ▸ General**, and looking up library CDs in **Settings ▸
Local Library**.

## On the iPhone and Apple Watch

The iPhone keeps its music and its copy of the library on the phone, out of iCloud backups. It talks to:

- **Your paired Mac**, over your local network, encrypted with a key the two exchange when pairing. While the Mac app
  runs it listens on the local network for its paired phones (macOS may ask to allow incoming connections).
- **Last.fm**, if you connect it.
- **Ticketmaster and JamBase**, for concerts on artist pages, only if the Mac has keys for them.
- **Anthropic** (or **OpenRouter**, with an OpenRouter model), while the Radio DJ is on the air, only if the Mac handed
  over a key. Photos you take or pick for the DJ go only there, without their location; the app asks for the camera the first time you take one.
- **Apple's iTunes Search**, for previews of songs the DJ mentions.

The widgets and the watch get a small summary (stats, recent additions to your physical collection, the song playing and
a few covers) kept on the phone and sent to your paired watch, which also gets an index of your labeled CDs and records
(titles, artists, years and label numbers) for Find by Label.

The App Store privacy label lists listening data (sent to Last.fm when you connect it) and coarse location (the area
searched for concerts).
