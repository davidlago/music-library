#!/usr/bin/env bash
# Builds build/MusicLibrary.app (ad-hoc signed unless SIGN_IDENTITY is set).
#
#   VERSION=1.2.0   version shown in Finder and About (default: 0.0.0-dev)
#   BUILD=42        build number (default: 1)
#   UNIVERSAL=1     build for both Apple Silicon and Intel (needs Xcode, not just the Command Line Tools)
#   SIGN_IDENTITY="Developer ID Application: …"
#                   sign with this certificate instead of ad hoc, with the hardened runtime (and a secure timestamp for a
#                   Developer ID one, which notarization needs: scripts/notarize.sh). Keychain access is tied to an
#                   ad-hoc build's exact code hash, so macOS asks once after every rebuild; a certificate with a Team ID
#                   (Developer ID, or an Apple Development one from Xcode) keeps access across builds.
#   BUNDLE_TOOLS=0  leave out ffmpeg, ffprobe and fpcalc (default: build them with scripts/build-tools.sh and put them
#                   in Contents/Helpers, so the app needs nothing from Homebrew)
#   PROVISIONING_PROFILE=path/to/MusicLibrary.provisionprofile
#                   a Developer ID profile with iCloud (docs/distribution.md), embedded in the app; it's then signed with
#                   the iCloud entitlements for ICLOUD_CONTAINER (default iCloud.io.github.davidlago.MusicLibrary) and
#                   takes its bundle ID from the profile. Needs SIGN_IDENTITY. Such a build has its own user defaults, so
#                   it imports local.musiclibrary's once at launch (DefaultsImport). Without a profile the app is
#                   local.musiclibrary, has no iCloud and shows none (docs/icloud-plan.md). A Mac App Store profile
#                   (scripts/mac-app-store.sh) is taken the same way and implies SANDBOX=1 (no defaults import).
#   SANDBOX=1       sign the app for the App Sandbox (Resources/MusicLibrary-AppStore.entitlements) and the helpers to
#                   inherit it (Resources/Helper-Sandbox.entitlements), as the Mac App Store build is
#   BUNDLE_ID=…     another bundle ID for a build without a profile (default local.musiclibrary), for a test copy that
#                   keeps its own settings and container, e.g. BUNDLE_ID=local.musiclibrary.sandboxtest SANDBOX=1
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

# iCloud needs an explicit App ID, an embedded profile that allows the container and entitlements matching it.
fail() { echo "error: $1" >&2; exit 1; }
DEFAULT_BUNDLE_ID=local.musiclibrary
BUNDLE_ID="${BUNDLE_ID:-$DEFAULT_BUNDLE_ID}"
SANDBOX="${SANDBOX:-0}"
EXTRA_INFO=""
SIGNING=build/signing
rm -rf "$SIGNING" && mkdir -p "$SIGNING"
if [[ -n "${PROVISIONING_PROFILE:-}" ]]; then
    [[ "${SIGN_IDENTITY:--}" != "-" ]] || fail "PROVISIONING_PROFILE needs SIGN_IDENTITY (an ad-hoc signature can't use a profile)"
    security cms -D -i "$PROVISIONING_PROFILE" > "$SIGNING/profile.plist" 2> /dev/null \
        || fail "can't read the provisioning profile $PROVISIONING_PROFILE"
    # A Developer ID profile provisions every Mac; a Mac App Store one names no devices at all (a development
    # profile lists them, and isn't for either).
    profile_key() { /usr/libexec/PlistBuddy -c "Print :$1" "$SIGNING/profile.plist" 2> /dev/null || true; }
    if [[ "$(profile_key ProvisionsAllDevices)" == "true" ]]; then
        MAC_APP_STORE=0
    elif [[ -z "$(profile_key ProvisionedDevices)" ]]; then
        MAC_APP_STORE=1
        SANDBOX=1
        [[ "$SIGN_IDENTITY" == "Apple Distribution"* || "$SIGN_IDENTITY" == "3rd Party Mac Developer Application"* ]] \
            || fail "a Mac App Store profile needs an Apple Distribution SIGN_IDENTITY"
    else
        fail "the profile is a development profile; use a Developer ID or Mac App Store one"
    fi
fi
ENTITLEMENTS="$SIGNING/MusicLibrary.entitlements"
if [[ "$SANDBOX" == "1" ]]; then
    cp Resources/MusicLibrary-AppStore.entitlements "$ENTITLEMENTS"
else
    cp Resources/MusicLibrary.entitlements "$ENTITLEMENTS"
fi
if [[ -n "${PROVISIONING_PROFILE:-}" ]]; then
    allowed() { /usr/libexec/PlistBuddy -c "Print :Entitlements:$1" "$SIGNING/profile.plist" 2> /dev/null || true; }
    APP_IDENTIFIER="$(allowed com.apple.application-identifier)"
    TEAM_ID="$(allowed com.apple.developer.team-identifier)"
    [[ -n "$TEAM_ID" && "$APP_IDENTIFIER" == "$TEAM_ID".* ]] || fail "the profile has no application identifier for its team"
    BUNDLE_ID="${APP_IDENTIFIER#"$TEAM_ID".}"
    [[ "$BUNDLE_ID" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]] || fail "the profile is for \"$BUNDLE_ID\"; iCloud needs an explicit App ID"
    ICLOUD_CONTAINER="${ICLOUD_CONTAINER:-iCloud.io.github.davidlago.MusicLibrary}"
    for key in com.apple.developer.icloud-container-identifiers com.apple.developer.ubiquity-container-identifiers; do
        allowed "$key" | sed 's/^ *//' | grep -qxF -e "$ICLOUD_CONTAINER" -e '*' \
            || fail "the profile doesn't allow $ICLOUD_CONTAINER ($key); add the container to the App ID and make the profile again"
    done
    allowed com.apple.developer.icloud-services | sed 's/^ *//' | grep -qxF -e CloudDocuments -e '*' \
        || fail "the profile doesn't allow iCloud Documents (com.apple.developer.icloud-services)"

    entitle() { /usr/libexec/PlistBuddy -c "$1" "$ENTITLEMENTS" > /dev/null; }
    entitle "Add :com.apple.application-identifier string $APP_IDENTIFIER"
    entitle "Add :com.apple.developer.team-identifier string $TEAM_ID"
    for key in com.apple.developer.icloud-container-identifiers com.apple.developer.ubiquity-container-identifiers; do
        entitle "Add :$key array"
        entitle "Add :$key:0 string $ICLOUD_CONTAINER"
    done
    entitle "Add :com.apple.developer.icloud-services array"
    entitle "Add :com.apple.developer.icloud-services:0 string CloudDocuments"
    # Developer ID and App Store builds use the production iCloud environment; only name it when the profile does.
    if [[ -n "$(allowed com.apple.developer.icloud-container-environment)" ]]; then
        entitle "Add :com.apple.developer.icloud-container-environment string Production"
    fi
    EXTRA_INFO="    <key>MusicLibraryICloudContainer</key><string>$ICLOUD_CONTAINER</string>"
    # A sandboxed build can't read another app's defaults, so it doesn't ask to (DefaultsImport).
    if [[ "$BUNDLE_ID" != "$DEFAULT_BUNDLE_ID" && "$SANDBOX" != "1" ]]; then
        EXTRA_INFO+=$'\n'"    <key>MusicLibraryImportsDefaultsFrom</key><string>$DEFAULT_BUNDLE_ID</string>"
    fi
fi

ARCH_FLAGS=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then ARCH_FLAGS=(--arch arm64 --arch x86_64); fi
export UNIVERSAL

swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_DIR="$(swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

ICON="Resources/AppIcon.icns"
if [[ ! -f "$ICON" ]]; then
    echo "error: $ICON is missing; generate it with: swift scripts/make-icon.swift" >&2
    exit 1
fi

if [[ "${BUNDLE_TOOLS:-1}" == "1" ]]; then scripts/build-tools.sh; fi

APP="build/MusicLibrary.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/MusicLibrary" "$APP/Contents/MacOS/MusicLibrary"
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
if [[ "${BUNDLE_TOOLS:-1}" == "1" ]]; then
    mkdir -p "$APP/Contents/Helpers"
    cp build/tools/ffmpeg build/tools/ffprobe build/tools/fpcalc "$APP/Contents/Helpers/"
    cp -R build/tools/Licenses "$APP/Contents/Resources/Licenses"
fi
# The sample library (the iPhone app's, scripts/make-sample-library.sh) for File ▸ Explore a Sample Library.
cp -R iOS/MusicLibraryMobile/SampleLibrary.bundle "$APP/Contents/Resources/SampleLibrary.bundle"
# The required-reason APIs the app uses (the Mac App Store asks for it).
cp Resources/PrivacyInfo.xcprivacy "$APP/Contents/Resources/PrivacyInfo.xcprivacy"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>MusicLibrary</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleName</key><string>MusicLibrary</string>
    <key>CFBundleDisplayName</key><string>Music Library</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD}</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSMicrophoneUsageDescription</key><string>Music Library records your records from the input you choose on the Digitize Vinyl page.</string>
    <key>NSLocalNetworkUsageDescription</key><string>Music Library finds the iPhone app on your local network to sync music to it.</string>
    <key>NSBonjourServices</key><array><string>_musiclib-sync._tcp</string><string>_musiclib-mac._tcp</string></array>
    <key>NSHumanReadableCopyright</key><string>© 2026 Dave Lago. MIT License.</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>ITSAppUsesNonExemptEncryption</key><false/>
${EXTRA_INFO}
</dict>
</plist>
PLIST

IDENTITY="${SIGN_IDENTITY:--}"
SIGN_FLAGS=(--force --sign "$IDENTITY")
if [[ "$IDENTITY" != "-" ]]; then SIGN_FLAGS+=(--options runtime); fi
if [[ "$IDENTITY" == "Developer ID Application"* ]]; then SIGN_FLAGS+=(--timestamp); fi
# Helpers first, then the app around them (no --deep). Sandboxed, each runs in the app's sandbox and has nothing else.
HELPER_FLAGS=()
if [[ "$SANDBOX" == "1" ]]; then HELPER_FLAGS=(--entitlements Resources/Helper-Sandbox.entitlements); fi
if [[ -d "$APP/Contents/Helpers" ]]; then
    for tool in "$APP"/Contents/Helpers/*; do
        # A tool with an embedded Info.plist (fpcalc's says org.acoustid.fpcalc) must be signed under its own bundle
        # identifier: App Store Connect refuses a mismatch.
        id="$(launchctl plist __TEXT,__info_plist "$tool" 2> /dev/null | sed -n 's/.*"CFBundleIdentifier" = "\(.*\)";/\1/p')"
        codesign "${SIGN_FLAGS[@]}" ${HELPER_FLAGS[@]+"${HELPER_FLAGS[@]}"} \
            --identifier "${id:-local.musiclibrary.$(basename "$tool")}" "$tool"
    done
fi
if [[ -n "${PROVISIONING_PROFILE:-}" ]]; then cp "$PROVISIONING_PROFILE" "$APP/Contents/embedded.provisionprofile"; fi
# The hardened runtime blocks recording without the audio input entitlement (Digitize Vinyl).
codesign "${SIGN_FLAGS[@]}" --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --strict --deep "$APP"
echo "Built $APP ($BUNDLE_ID $VERSION, $(lipo -archs "$APP/Contents/MacOS/MusicLibrary"), signed: $IDENTITY${EXTRA_INFO:+, iCloud: ${ICLOUD_CONTAINER:-}}$([[ "$SANDBOX" == "1" ]] && echo ", sandboxed"))"
