# App Store listing

What's entered in [App Store Connect](https://appstoreconnect.apple.com) for the iPhone app (with its widgets and
Apple Watch app). Keep it in step with the app and the README; [docs/distribution.md](../distribution.md#the-app-store)
says how a version is submitted.

Screenshots: `iphone-6.3/` (1206 × 2622, from the iPhone 17 simulator), the required "iPhone with Dynamic Island
(medium display)" set that App Store Connect scales for every iPhone; `iphone/` (6.9-inch, 1320 × 2868, iPhone 18 Pro Max,
optional "large display"); and `watch/` (416 × 496, Apple Watch Series 12 46 mm). All are taken from the sample library
with the status bar set to 9:41. The review demo video is made
the same way (`xcrun simctl io booted recordVideo`) and isn't committed.

## App information

| Field | Value |
|---|---|
| Name | Dave's Music Library |
| Subtitle | Your music, synced from Mac |
| Category | Music |
| Content rights | Contains third-party content (artist and album descriptions from Wikipedia, photos from Wikimedia Commons and Deezer, covers from the Cover Art Archive, looked up by the Mac app and shown with credit) |
| Age rating | 4+ (every question answered None or No; links open in Safari, so no unrestricted web access) |
| Privacy policy URL | https://davidlago.github.io/music-library/privacy.html |
| Support URL | https://davidlago.github.io/music-library/support.html |
| Marketing URL | https://davidlago.github.io/music-library/ |
| Copyright | 2026 Dave Lago |
| Price | Free, all territories |
| EU trader status | Not a trader |

## App Privacy

The developer collects nothing, but two optional features send data to other companies, so the answers are:

- **Usage Data ▸ Product Interaction** (music listening data): sent to Last.fm when you connect your account. Linked to
  you (your Last.fm account), used for App Functionality, not for tracking.
- **Location ▸ Coarse Location**: the area searched for concerts (a geohash cell, from the ZIP code entered on the Mac)
  goes to Ticketmaster and JamBase when the Mac has keys for them. Not linked to you, App Functionality, not for
  tracking.

Nothing else leaves the phone except to the user's own paired Mac (local network) and watch. No tracking, no ads, no
analytics. Export compliance: `ITSAppUsesNonExemptEncryption = NO` (only the encryption built into iOS).

## Version text

**Promotional text** (can change without a review):

```
Try it right away with the built-in sample library, then sync your own collection from the free Music Library app for Mac.
```

**Keywords:**

```
player,flac,lossless,offline,hi-res,dac,scrobble,lastfm,mac,sync,collection,albums,cd,bitperfect
```

**Description:**

```
Your own music collection, on your iPhone and Apple Watch. Dave's Music Library is the companion to Music Library for Mac, a free and open-source app for people who keep their music as files: rip your CDs, tag everything from MusicBrainz, and explore your collection in ways streaming apps don't.

Browse your whole library
Every album, artist, cover and artist photo comes over from your Mac, with album and artist info, credits, your playlists and smart playlists. Choose which music to keep on the iPhone; everything else can still be browsed and downloaded when you want it.

Play it properly
Gapless playback when songs share a sample rate, and with a USB DAC the output switches to each song's own rate. Lock screen and Control Center controls, a play queue with Play Next, and your queue kept between launches.

Insights
See what you listened to over the last week, month, year or all time: top songs, artists, albums and genres, listening streaks, the hours you listen most, and favorites you've forgotten. See what your library is made of, and what you've spent on the albums you own.

Music DNA
Follow the people behind your music: who played, wrote and produced with whom, as an interactive map.

Widgets and Apple Watch
Home screen widgets for listening, now playing, recent purchases and albums to rediscover. On Apple Watch, control playback and glance at your stats.

Your library stays yours
No account, no ads, no tracking. Your iPhone and Mac sync directly over your Wi-Fi network, encrypted. Plays and likes go back to your Mac, and you can scrobble to Last.fm.

No Mac app yet? Tap Explore a Sample Library to try everything with fictional artists and albums.

Requires Music Library for Mac (free, macOS 14 or later) to bring your own music: https://davidlago.github.io/music-library/
```

**What's New** (each version): that version's section of `CHANGELOG.md`, as plain text.

## App Review

**Sign-in required:** No.

**Notes** (what App Review asked for after the first submission, a Guideline 2.1 "Information Needed" request for new
developer accounts: purpose and audience, setup, external services, regions and protected material, plus a recording
from a physical device):

```
Screen recording: the attached video was recorded on a physical iPhone running the latest iOS, starting from launching the app: syncing with the Mac (removing and downloading an album), browsing an album, playback with Now Playing and likes, an artist page, Music DNA and search.

Purpose and audience: Dave's Music Library is the iPhone and Apple Watch companion to Music Library for Mac, a free, open-source app (https://github.com/davidlago/music-library) for people who keep their music collection as their own audio files (ripped CDs, purchased downloads) rather than streaming. The Mac app imports, tags and organizes the collection; this app lets them take it with them: browse the whole library, play the songs they chose to copy offline (gapless, and at each song's own sample rate on USB DACs), see their listening history and who played on their records (Music DNA), and keep track of the albums they own. It doesn't sell, stream or provide any music; it only plays the user's own files.

Setup: no account or login. Without a Mac, tap "Explore a Sample Library" on the Library tab: a library built into the app (fictional artists and albums; the songs were synthesized and the covers and pictures drawn for it), with which every feature can be tried, including the widgets and the Apple Watch app. Nothing done in it is sent anywhere, and the user's own library replaces it after their first sync. With your own music: install the free Mac app (https://github.com/davidlago/music-library/releases) and import music, then on the iPhone open Sync, tap "Pair with a Mac" and enter the code it shows in the Mac app (iPhone in its sidebar); both need to be on the same Wi-Fi network (the app asks for local network access). Choose what to copy with Download on the iPhone or Add to iPhone on the Mac.

External services: none are needed for the core functions; the library and music come from the user's own Mac over the local network (Bonjour, encrypted with TLS), with no server in between. Optional, with the user's own accounts or keys: Last.fm (scrobbling; Settings, with a Last.fm API key) and Ticketmaster and JamBase (upcoming concerts on artist pages; keys set on the Mac). Artist and album descriptions, photos and covers were looked up by the Mac app from MusicBrainz, the Cover Art Archive, Wikipedia, Wikidata, Wikimedia Commons and Deezer. No analytics, advertising, AI or payment services.

Regions: the app works the same in every region; concert listings depend on Ticketmaster's and JamBase's coverage of the user's area.

Regulated or protected material: not a regulated industry. The app doesn't include or distribute protected third-party material: it plays only the user's own audio files; the sample library's songs, covers and artist pictures were created for the app; descriptions and photos come from openly licensed sources (Wikipedia, Wikimedia Commons, MusicBrainz, Cover Art Archive) and are credited in the app.
```

**Attachment:** a screen recording **made on a physical iPhone running the latest iOS**, starting with launching the app
and showing the typical flow (App Review doesn't accept simulator recordings for this). Record it with Control Center's
Screen Recording, then compress it under 10 MB (`ffmpeg -i in.mp4 -vf "scale=-2:1920,fps=30" -c:v libx264 -crf 24 -c:a aac
out.mp4`); it isn't committed. Send the same answers and video as a reply in App Review when they ask.
