# App Store listing

What's entered in [App Store Connect](https://appstoreconnect.apple.com) for the iPhone app (with its widgets and
Apple Watch app), live at https://apps.apple.com/us/app/daves-music-library/id6822005512. Keep it in step with the app and the README; [docs/distribution.md](../distribution.md#the-app-store)
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

**Promotional text** (at most 170 characters; can change at any time without a review):

```
Try it right away with the built-in sample library, then sync your own collection from the free Music Library app for Mac: davidlago.github.io/music-library
```

**Keywords:**

```
player,flac,lossless,offline,hi-res,dac,scrobble,lastfm,mac,sync,collection,albums,cd,bitperfect
```

**Description:**

```
Your own music collection, on your iPhone and Apple Watch. Dave's Music Library is the companion to Music Library for Mac, a free and open-source app for people who keep their music as files: rip your CDs, tag everything from MusicBrainz, and explore your collection in ways streaming apps don't. Get the Mac app at https://davidlago.github.io/music-library/

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

Get the companion Mac app
Your music comes from Music Library for Mac (free, macOS 14 or later): it imports and rips your music, then syncs it to your iPhone. Download it, and find help and the source code, on the website: https://davidlago.github.io/music-library/
```

The description can only be changed with a new version (the promotional text can change at any time).

**What's New** (each version): that version's section of `CHANGELOG.md`, as plain text.

## App Review

**Sign-in required:** No.

**Notes:**

```
Dave's Music Library is the iPhone companion of Music Library for Mac, a free, open-source macOS app (https://github.com/davidlago/music-library, notarized downloads at https://github.com/davidlago/music-library/releases). The Mac app holds the user's music collection and syncs a copy of it to the iPhone over the local network.

To review without a Mac: on the Library tab, tap "Explore a Sample Library". It opens a library built into the app (fictional artists and albums; the songs were synthesized for it, and the covers and pictures were drawn for it), so every feature can be tried: browsing, playback with lock screen controls, likes, Insights, Music DNA, owned albums, the widgets and the Apple Watch app. Nothing done in the sample is sent anywhere, and the user's own library replaces it after their first sync.

To sync your own music: install the Mac app, open the iPhone's Sync tab and tap "Pair with a Mac", then enter the code it shows in the Mac app (iPhone in the sidebar). Both need to be on the same Wi-Fi network; the app asks for local network access for this. The attached video shows the sample library and the pairing screen.

Optional features need the user's own accounts or keys: Last.fm scrobbling (Settings, with a Last.fm API key) and concerts on artist pages (Ticketmaster or JamBase keys set on the Mac).
```

**Attachment:** the demo video (`build/app-store/review-demo.mp4`).
