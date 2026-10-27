# Troubleshooting

## Keychain prompts

The first time a new version reads your saved keys and passwords, macOS asks to allow access to the keychain. Choose
**Always Allow**. The app keeps every secret in one keychain item, so it's one prompt per update. (Builds you make
yourself without a signing certificate ask after every rebuild.)

## The iPhone can't find the Mac, or a sync times out

- Both need to be on the same Wi-Fi network, with Music Library open on the Mac and Sync open on the phone (the button at the top of Listen Now).
- Both apps need **Local Network** access: on the iPhone in Settings ▸ Apps ▸ Dave's Music Library, on the Mac in System
  Settings ▸ Privacy & Security ▸ Local Network.
- Right after launch, macOS sometimes refuses the Mac app's first local network connection. The app tries again with a
  new connection by itself, and says so if macOS keeps blocking it.
- Networks that keep devices apart (guest networks, some office and hotel Wi-Fi) block syncing. Use your home network.
- Keep the iPhone app open while it syncs: iOS pauses it in the background.
- Still stuck? **Unpair** on both sides and pair again.

## The iPhone won't sync: not enough space

The Mac works out how much space a sync needs, and the phone refuses one that doesn't fit. Remove some music from the
phone (**Remove from iPhone**) or turn down **Owned Music on iPhone**.

## A song or album wasn't matched

Open it on the Import page, edit the Title, Artist and Album and press **Search**, or **Fingerprint** with an AcoustID
key. `is:unmatched` in search lists what was imported without a match.

## A ripped track is "inaccurate"

Clean the disc and use **Rip Again** on the CD page; the app reads the track several times and repairs what it can (see
[Ripping CDs](ripping-cds.md#checking-rips-with-accuraterip)). A track that's still misread after five reads is kept as
it was.

## Playback doesn't switch rates

- Check **Settings ▸ Playback ▸ Match output device sample rate to the song**.
- Bluetooth and AirPlay devices run at a fixed rate.
- When the player bar's output text is orange, your device doesn't support the song's rate; hover it for details.
- On the iPhone, a DAC must be connected before the song starts or it restarts the song at its rate; Now Playing says
  when the output was resampled.

## Local Library CDs is slow or paused

The catalog's website asks apps to go easy, so the download takes its time (about a quarter of an hour for a couple of
thousand CDs), and when the site asks for a break the app waits ("paused until…") and resumes by itself. MusicBrainz
lookups run at one per second.

## The Radio DJ says something's wrong

- **Check** in Settings ▸ Radio DJ tests the key.
- A failed answer can be retried with **Try Again**.
- The DJ needs the internet; on the iPhone it needs the key from a sync with the Mac.

## Apps built yourself stop opening on the iPhone

Apps installed with a free Apple ID stop opening after 7 days. See
[Building from source](building-from-source.md#every-7-days-free-apple-id).

## Getting help

Search or open an issue on [GitHub](https://github.com/davidlago/music-library/issues), or see the
[support page](https://davidlago.github.io/music-library/support.html).
