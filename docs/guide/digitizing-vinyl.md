# Digitizing vinyl

**Digitize Vinyl** (in the sidebar's **Import** section) records a record you own from your turntable and turns it into
tracks in your Digital Collection, lossless FLAC tagged and filed like a ripped CD, linked to the record in your
[Physical Collection](physical-collection.md).

![Digitize Vinyl: The Big Reunion recorded at 24-bit / 96 kHz, cut into four tracks on its waveform, two already saved](../screenshots/digitize-vinyl.png)

## What you need

Something that turns the record's sound into a digital input on your Mac: a USB turntable, a phono preamp with USB, or
a phono preamp into an audio interface. The first recording asks for permission to use the microphone (that's how
macOS names every audio input).

## Pick a record

Add the record to your Physical Collection first (the page points you to **Add a Record…** until there's one). Then
choose it on the page, or start from the record itself: **Digitize…** (or **Digitize the Rest…**) on its page, **… ▸
Digitize This Record…**, or the Shelf's context menu.

The record's track list comes from its release on MusicBrainz. For a record MusicBrainz doesn't list, type each track's
number and title, or pick the right edition with **Change Edition…**.

## Set up the input

- **Input**: your turntable, preamp or interface. **Sample rate** and **Bit depth** (16 or 24-bit) are the input's
  standard formats, up to 24-bit / 192 kHz; the app sets the device to them. 24-bit / 96 kHz is a good choice.
- **Check Levels** runs the meter without recording. Aim for loud passages well short of the **CLIP** light.
- **Listen** plays the input through your speakers or headphones while you check levels or record, with its own volume.
  It doesn't change what's recorded.

## Record

Press **Record** and drop the needle. Record a side, **Pause** to turn the record over, **Resume**, and **Stop** when
you're done. **Record More** adds to the same recording. A recording at 24/96 takes about 35 MB a minute.

The recording is kept (also after quitting the app) until you discard it, in your Mac's Application Support folder, so
you can cut and save it at your own pace.

## Cut it into tracks

You make the cuts yourself; the app doesn't guess where songs start (gaps on a record aren't reliable, and a soft
passage would split a long track).

- Click the waveform to move the playhead, and press **Space** to listen from there.
- **Split at Playhead** cuts at that point. While recording, the last track grows with the recording, so you can cut
  as you go.
- Drag a cut's edge to move it; cuts that meet move together. Drag elsewhere to scroll, and ⌘-scroll or pinch to zoom
  (**Fit** shows it all).
- **Delete Cut** removes one.
- For each cut, pick its song from the record's track list (or **Don't Save**). The buttons beside it play it, or its
  last five seconds to check the end.

## Save

**Save to Digital Collection** encodes each cut to FLAC, tags it with the release's details, credits and cover, and
imports it. Tracks already in your digital collection are skipped. The record is marked digitized ("5 of 9 songs
digitized" until it's complete), and its page offers **Digitize the Rest…** for the others.

**Discard Recording…** deletes the recording when you're done with it. Switching to another record with unsaved cuts
asks first.

Saved tracks play, sync to the iPhone and show in Insights like any other music.
