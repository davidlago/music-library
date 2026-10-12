#!/usr/bin/env bash
# Builds build/MusicLibrary.app (ad-hoc signed).
#
#   VERSION=1.2.0   version shown in Finder and About (default: 0.0.0-dev)
#   BUILD=42        build number (default: 1)
#   UNIVERSAL=1     build for both Apple Silicon and Intel (needs Xcode, not just the Command Line Tools)
#   SIGN_IDENTITY="Apple Development: …"
#                   sign with this certificate instead of ad hoc. Keychain access is tied to an ad-hoc build's exact
#                   code hash, so macOS asks once after every rebuild; a certificate with a Team ID (like a free Apple
#                   Development one from Xcode) keeps access across builds.
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.0.0-dev}"
BUILD="${BUILD:-1}"

# SwiftUI's @State/@Observable macro plugins ship with Xcode only; with just the Command Line Tools
# the macOS 26 SDK compiles the app while the macOS 27 SDK does not.
if [[ -z "${SDKROOT:-}" ]]; then
    sdk="$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX26*.sdk 2>/dev/null | sort -V | tail -1 || true)"
    if [[ -n "$sdk" && ! -d /Applications/Xcode.app ]]; then export SDKROOT="$sdk"; fi
fi

ARCH_FLAGS=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then ARCH_FLAGS=(--arch arm64 --arch x86_64); fi

swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_DIR="$(swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

ICON="Resources/AppIcon.icns"
if [[ ! -f "$ICON" ]]; then
    echo "error: $ICON is missing; generate it with: swift scripts/make-icon.swift" >&2
    exit 1
fi

APP="build/MusicLibrary.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/MusicLibrary" "$APP/Contents/MacOS/MusicLibrary"
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>MusicLibrary</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>local.musiclibrary</string>
    <key>CFBundleName</key><string>MusicLibrary</string>
    <key>CFBundleDisplayName</key><string>Music Library</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD}</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSLocalNetworkUsageDescription</key><string>Music Library finds the iPhone app on your local network to sync music to it.</string>
    <key>NSBonjourServices</key><array><string>_musiclib-sync._tcp</string></array>
    <key>NSHumanReadableCopyright</key><string>© 2026 Dave Lago. MIT License.</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --sign "${SIGN_IDENTITY:--}" "$APP"
echo "Built $APP ($VERSION, $(lipo -archs "$APP/Contents/MacOS/MusicLibrary"))"
