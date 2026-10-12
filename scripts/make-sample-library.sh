#!/bin/bash
# Makes the iPhone app's sample library: iOS/MusicLibraryMobile/SampleLibrary.bundle (a library folder with its
# library.sqlite, Music and Artist Images, wrapped as a resource bundle so Xcode copies it whole). Everything in it is
# made by Sources/SampleLibraryMaker: synthesized songs, drawn covers, fictional artists. Needs ffmpeg.
set -euo pipefail
cd "$(dirname "$0")/.."

dest="iOS/MusicLibraryMobile/SampleLibrary.bundle"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

swift build -c release --product SampleLibraryMaker
"$(swift build -c release --show-bin-path)/SampleLibraryMaker" "$work/SampleLibrary.bundle"

# The app opens it read-only inside its bundle, where SQLite can't make a WAL's shared-memory file.
sqlite3 "$work/SampleLibrary.bundle/library.sqlite" "PRAGMA journal_mode=DELETE;" >/dev/null

cat > "$work/SampleLibrary.bundle/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>io.github.davidlago.MusicLibrary.SampleLibrary</string>
	<key>CFBundleName</key>
	<string>SampleLibrary</string>
	<key>CFBundlePackageType</key>
	<string>BNDL</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
</dict>
</plist>
PLIST

rm -rf "$dest"
mv "$work/SampleLibrary.bundle" "$dest"
du -sh "$dest"
