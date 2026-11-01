# App Store listing

What's entered in [App Store Connect](https://appstoreconnect.apple.com) for the iPhone app (with its widgets and
Apple Watch app), live at https://apps.apple.com/us/app/daves-music-library/id6822005512. Keep it in step with the app,
the README and the [user guide](../guide/README.md); [docs/distribution.md](../distribution.md#the-app-store) says how a
version is submitted.

## Screenshots

All taken from a real library (the developer's own, synced from the Mac app), in light mode, with the status bar set to
9:41 (`xcrun simctl status_bar … override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4
--wifiBars 3`) and captured with `xcrun simctl io <device> screenshot`:

- `iphone-6.3/` (1206 × 2622, iPhone 18 Pro simulator): the required "iPhone with Dynamic Island (medium display)" set
  that App Store Connect scales for every iPhone.
- `iphone/` (1320 × 2868): the optional 6.9-inch "large display" set, the same screens scaled up (the two sizes have the
  same proportions). Replace the old 6.9-inch set in App Store Connect too, or delete it there, so large iPhones don't
  keep showing the old screenshots.
- `watch/` (416 × 496, the Apple Watch paired with the iPhone 18 Pro simulator; its status bar can't be overridden).

In order: Physical (Find by Label), an item page (CD #14), records to digitize, Albums, an album page, an artist page,
Listening, Music DNA; on the watch: Now Playing, Physical, Find by Label.

The review demo video is made with `xcrun simctl io booted recordVideo` from the sample library and isn't committed.

## App information

| Field | Value |
|---|---|
| Name | Dave's Music Library |
| Subtitle | Your CDs, vinyl and music |
| Category | Music |
| Content rights | Contains third-party content (artist and album descriptions from Wikipedia, photos from Wikimedia Commons and Deezer, covers from the Cover Art Archive, looked up by the Mac app and shown with credit; the screenshots show the developer's own albums with their covers) |
| Age rating | 4+ (every question answered None or No; links open in Safari, so no unrestricted web access) |
| Privacy policy URL | https://davidlago.github.io/music-library/privacy.html |
| Support URL | https://davidlago.github.io/music-library/support.html |
| Marketing URL | https://davidlago.github.io/music-library/ |
| Copyright | 2026 Dave Lago |
| Price | Free, all territories |
| EU trader status | Not a trader |

The subtitle can only change with a new version.

## App Privacy

The developer collects nothing, but optional features send data to other companies, so the answers are:

- **Usage Data ▸ Product Interaction** (music listening data): sent to Last.fm when you connect your account. Linked to
  you (your Last.fm account), used for App Functionality, not for tracking.
- **Location ▸ Coarse Location**: the area searched for concerts (a geohash cell, from the ZIP code entered on the Mac)
  goes to Ticketmaster and JamBase when the Mac has keys for them. Not linked to you, App Functionality, not for
  tracking.

**To decide before submitting 1.24 (the Radio DJ):** with a Claude API key from the user's Mac, the iPhone sends the
page being viewed (album or artist details, the user's copies and plays of it), the user's questions and the rows of
collection searches to Anthropic, with the user's own key. That's likely **User Content ▸ Other User Content** (the
questions) and **Usage Data ▸ Product Interaction** (plays sent as context), linked to the user's own Anthropic account,
App Functionality, not for tracking. App Review's guideline 5.1.2(i) also asks apps to disclose where personal data goes
to a third-party AI and get permission first; the DJ only runs when the user presses its button after adding their own
key, but a one-time notice on the phone ("The DJ sends this page and your questions to Anthropic with your key") may be
needed if review asks.

**Since photos for the DJ (after 1.25.1):** photos the user takes or picks in the DJ's sheet go to Anthropic too
(re-encoded without location or camera metadata), which adds **User Content ▸ Photos or Videos**, linked to the user's
own Anthropic account, App Functionality, not for tracking. The camera needs `NSCameraUsageDescription` (in
`iOS/MusicLibraryMobile-Info.plist`); the photo library goes through the system picker, which needs no permission.

**Since OpenRouter models for the DJ (after 1.26.0):** with an OpenRouter key and model chosen on the Mac, the same data
goes to OpenRouter (and the model's provider) instead of Anthropic, with the user's own key. Same privacy label
categories; the review notes and privacy policy name OpenRouter as a possible recipient.

**Since iCloud backup (1.30.0):** the phone reads the library, covers and songs from the Mac's backup in
the app's private iCloud container, and writes its plays, likes and download requests there. That's the user's own
iCloud, which the developer can't access, so it isn't data the developer collects: the privacy label doesn't change.
The TestFlight and App Store builds need the iCloud entitlement (`ICLOUD` repository variable for CI, `ICLOUD=1` for
`scripts/testflight.sh`).

Nothing else leaves the phone except to the user's own paired Mac (local network or the user's own iCloud) and watch. No tracking, no ads, no
analytics. Export compliance: `ITSAppUsesNonExemptEncryption = NO` (only the encryption built into iOS).

## Version text

**Promotional text** (at most 170 characters; can change at any time without a review, but doesn't carry over to a new
version):

```
New: back up to your own iCloud and get your music on iPhone even when your Mac isn't nearby. Find any CD or record by its label, and play your music offline.
```

**Keywords** (at most 100 characters):

```
cd,vinyl,record,collection,shelf,flac,lossless,offline,hi-res,dac,scrobble,lastfm,dj,musicbrainz
```

**Description** (at most 4,000 characters; changes only with a new version):

```
Your CDs, your records and your music files, on your iPhone and Apple Watch. Dave's Music Library is the companion to Music Library for Mac, a free and open-source app for people who own their music: catalog your CDs and vinyl with a label number on every case, rip and digitize them, tag everything from MusicBrainz, and explore your collection in ways streaming apps don't.

Your shelf, by its label
Every CD and record you own comes over from your Mac, ripped or not, in its jewel case or sleeve, with its edition, label number, purchase date and price. Find by Label shows what's at a number and what sits on either side of it, so you can go and grab it from the shelf. On Apple Watch, turn the Digital Crown to a label, even away from your iPhone. Or ask Siri: "Find CD 12 in Music Library".

Every album and artist
Browse your whole digital collection with the Mac's album and artist pages: descriptions, ratings, credits, the full track list, your copies and your plays. Choose which music to keep on the phone; everything else can still be browsed and downloaded when you want it, from your Mac over Wi-Fi or from its backup in your own iCloud when the Mac isn't nearby, and Ready to Download lists the CDs and records you've digitized that aren't on the phone yet.

A radio DJ who knows your records
With your own Claude API key (set up in the Mac app), tap the radio button on any page and a DJ tells you the story behind what you're looking at: who made it, who played on it and how it connects to everything else you own. Ask anything; the DJ checks the web and searches your own collection to answer, with links to your albums and previews of songs you don't have.

Play it properly
Gapless playback when songs share a sample rate, and with a USB DAC the output switches to each song's own rate. Lock screen and Control Center controls, a play queue with Play Next, Liked Songs, and your queue kept between launches.

Insights and Music DNA
See what you own (how much is digitized, your free label numbers, what you've spent and the cost per play), what your music files are made of, and a listening report for the last week, month, year or all time: top artists, albums and songs, what was new to you, your listening clock and forgotten favorites. Music DNA maps who played, wrote and produced with whom.

Widgets and Apple Watch
Home and lock screen widgets for what's playing (with controls), your listening, your physical collection and next labels, your digital collection and albums to rediscover. On Apple Watch: a remote for your iPhone, your listening, and Find by Label.

Your library stays yours
No account, no ads, no tracking. Your iPhone and Mac sync directly over your Wi-Fi network, encrypted, or through your own iCloud when the Mac backs up there. Plays and likes go back to your Mac, and you can scrobble to Last.fm. What you own is edited in the Mac app and shown read-only on the phone.

No Mac app yet? Tap Explore a Sample Library to try everything with fictional artists, CDs and records.

Get the companion Mac app
Your music comes from Music Library for Mac (free, macOS 14 or later): it catalogs your CDs and records, imports, rips and digitizes your music, then syncs both collections to your iPhone. Download it, and find the full documentation and the source code, at https://davidlago.github.io/music-library/
```

**What's New in 1.31.0**:

```
• A new iPhone tells you it's looking for your library in iCloud, and shows your covers arriving, instead of an empty screen.
• Music your Mac keeps only in iCloud (offloaded there to save space) comes to your iPhone straight from iCloud, right after a Wi-Fi sync.
```

**What's New in 1.30.0** (submitted 2026-11-01; the live version was 1.24.0, so it covers the iPhone changes of 1.25–1.30):

```
Your Mac's iCloud backup
• With iCloud backup turned on in Music Library for Mac, your library, covers and photos stay up to date from your own iCloud, even when the Mac isn't nearby. A new iPhone gets your library without pairing.
• Download gets songs from the backup when your Mac isn't on the same Wi-Fi, and from the Mac as before when it is.
• Your plays, likes and downloads reach the Mac through iCloud too.
• Settings ▸ iCloud shows when the library was last updated, with Check Now.

A new home
• Four tabs: Listen Now (the album playing or played last, what you've been playing, its neighbors on the shelf, your week and what's up next), Collection (your CDs and records, then your digital collection), Explore (Artists, Music DNA and Insights) and Search. Sync and Settings are at the top of Listen Now.
• One look in Light and Dark, following your iPhone, or always Light or Dark in Settings.

Radio DJ
• Show it a photo: tap the camera in the DJ's sheet (touch and hold for your photo library), and it tells you what the record or CD is, which edition, whether you already own it and what a fair price is. Photos are sent without their location.
• Choose the DJ's model on your Mac, from Claude models or models on OpenRouter; your choice comes over at the next sync.
• Going on the air is free: the DJ says hello for your time of day and offers a few questions to start with.
```

**What's New in 1.24.0** (the live version is 1.23.0; 1.23.1 and 1.23.2 only changed the Mac app):

```
A radio DJ
• With a Claude API key added in the Mac app's Settings ▸ Radio DJ (it comes over when you sync), tap the radio button at the top of any page and a DJ tells you the story behind the album or artist you're looking at, then answers your questions, checking facts on the web and showing its sources.
• It can search your own collection ("what else do I have by them, most played first?"); the search runs on your iPhone and only the matching rows are sent.
• Albums and artists you own are links, songs on your iPhone play right from the DJ, and songs you don't own play a 30-second preview.
• Swipe the DJ away to keep browsing while it stays on the air; tap the radio button (red while it's on) to bring it back. Settings shows what it has cost this month.

Also
• Syncing is more reliable right after opening the Mac app.
```

## App Review

**Sign-in required:** No.

**Notes:**

```
Dave's Music Library is the iPhone companion of Music Library for Mac, a free, open-source macOS app (https://github.com/davidlago/music-library, notarized downloads at https://github.com/davidlago/music-library/releases, documentation at https://davidlago.github.io/music-library/docs/). The Mac app holds the user's physical collection (the CDs and records they own) and digital collection (their music files) and syncs a copy of them to the iPhone over the local network.

To review without a Mac: on the first screen, tap "Explore a Sample Library". It opens a library built into the app (fictional artists and albums; the songs were synthesized for it, and the covers and pictures were drawn for it), so nearly every feature can be tried: Listen Now (what's playing and what you've been playing), the Collection tab (CDs and records with label numbers, Find by Label, items with no digital copy, Ready to Download, then the digital collection: browsing, downloads), playback with lock screen controls, likes, Explore (Insights, Music DNA), the widgets, the Apple Watch app (Physical page and Find by Label) and the Siri phrase "Find CD 3 in Music Library". Nothing done in the sample is sent anywhere, and the user's own library replaces it after their first sync.

To sync your own music: install the Mac app, tap Sync at the top of the iPhone's Listen Now tab, then tap "Pair with a Mac", then enter the code it shows in the Mac app (iPhone in the sidebar). Both need to be on the same Wi-Fi network; the app asks for local network access for this. The attached video shows the sample library and the pairing screen.

The screenshots show the developer's own library, synced from the Mac app.

Optional: with iCloud backup turned on in the Mac app (Settings ▸ iCloud), the phone also reads the library and downloads songs from the Mac's backup in the user's own iCloud (the app's private container) when the Mac isn't nearby; Settings ▸ iCloud on the phone shows it. The sample library doesn't use iCloud.

Optional features need the user's own accounts or keys, entered by the user: Last.fm scrobbling (Settings, with a Last.fm API key), concerts on artist pages (Ticketmaster or JamBase keys set on the Mac) and the Radio DJ (the user's own Anthropic Claude API key or OpenRouter key, entered in the Mac app and handed to the phone when they sync; without one, the DJ doesn't appear at all). The DJ runs only when the user taps its button, and sends the page being viewed and the user's questions to Anthropic with the user's own key.
```

**Attachment:** the demo video (`build/app-store/review-demo.mp4`).
