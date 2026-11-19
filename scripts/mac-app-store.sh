#!/usr/bin/env bash
# Builds the Mac app for the Mac App Store and uploads it to App Store Connect, the way scripts/testflight.sh uploads
# the iPhone app. The Mac app has its own App Store record ("Dave's Music Library for Mac", bundle ID
# io.github.davidlago.MusicLibrary, docs/distribution.md ▸ The Mac App Store). Releases upload from CI (the
# `mac-app-store` job in .github/workflows/ci.yml).
#
# There's no Xcode project for the Mac app, so the package is put together by hand: scripts/build-app.sh builds the
# universal app, signed with the Apple Distribution certificate, the App Sandbox (SANDBOX=1, implied by the profile)
# and a Mac App Store profile with iCloud; productbuild wraps it in a .pkg signed with the "3rd Party Mac Developer
# Installer" certificate; the .pkg is checked inside out and uploaded with altool.
#
#   VERSION=1.37.0       version (default: MARKETING_VERSION in iOS/Version.xcconfig, kept at the Mac release's)
#   BUILD=202611191530   build number (default: the current UTC time, so every upload gets a new, higher one)
#   UPLOAD=0             only build and check build/mac-app-store/MusicLibrary.pkg
#   ASC_KEY=path/to/AuthKey_XXXX.p8 ASC_KEY_ID=XXXX ASC_ISSUER=…
#                        the App Store Connect API key: makes or renews the "<bundle ID> Mac App Store (CI)" profile
#                        (scripts/provisioning-profiles.swift --mac-app-store) and uploads
#   PROVISIONING_PROFILE=path/to/profile.provisionprofile
#                        a Mac App Store profile to use instead of making one with the API key
#   BUNDLE_ID=…          the App ID (default io.github.davidlago.MusicLibrary)
#
# Needs Xcode (a universal build) and, in the keychain, an "Apple Distribution" and a "3rd Party Mac Developer
# Installer" identity (scripts/mac-installer-certificate.sh makes the second).
set -euo pipefail

cd "$(dirname "$0")/.."

fail() { echo "error: $1" >&2; exit 1; }
config_value() { sed -n "s/^ *$1 *= *\\([^ ]*\\).*/\\1/p" "$2" | head -1; }

BUILD="${BUILD:-$(date -u +%Y%m%d%H%M)}"
VERSION="${VERSION:-$(config_value MARKETING_VERSION iOS/Version.xcconfig)}"
[[ -n "$VERSION" ]] || fail "no VERSION, and no MARKETING_VERSION in iOS/Version.xcconfig"
BUNDLE_ID="${BUNDLE_ID:-io.github.davidlago.MusicLibrary}"
UPLOAD="${UPLOAD:-1}"
OUT=build/mac-app-store
PKG="$OUT/MusicLibrary.pkg"

# The App Store refuses builds from a beta Xcode.
if xcodebuild -version | grep -qi beta || [[ "$(xcode-select -p)" == *[Bb]eta* ]]; then
    fail "$(xcode-select -p) is a beta Xcode; App Store Connect only accepts builds from a release Xcode"
fi

identity() {
    security find-identity -v ${2:+-p "$2"} | sed -n "s/^ *[0-9]*) [0-9A-F]\\{40\\} \"\\($1: .*\\)\"$/\\1/p" | sort -u | head -1
}
APP_IDENTITY="$(identity "Apple Distribution" codesigning)"
[[ -n "$APP_IDENTITY" ]] || fail "no \"Apple Distribution\" identity in the keychain"
# Installer certificates aren't code signing ones, so they're looked up without that policy.
INSTALLER_IDENTITY="$(identity "3rd Party Mac Developer Installer")"
[[ -n "$INSTALLER_IDENTITY" ]] || fail "no \"3rd Party Mac Developer Installer\" identity in the keychain (scripts/mac-installer-certificate.sh)"

if [[ -n "${ASC_KEY:-}" ]]; then
    : "${ASC_KEY_ID:?set ASC_KEY_ID with ASC_KEY}" "${ASC_ISSUER:?set ASC_ISSUER with ASC_KEY}"
    ASC_KEY="$(cd "$(dirname "$ASC_KEY")" && pwd)/$(basename "$ASC_KEY")"
fi
if [[ -z "${PROVISIONING_PROFILE:-}" ]]; then
    [[ -n "${ASC_KEY:-}" ]] || fail "set ASC_KEY, ASC_KEY_ID and ASC_ISSUER (or PROVISIONING_PROFILE)"
    swift scripts/provisioning-profiles.swift --mac-app-store "$ASC_KEY" "$ASC_KEY_ID" "$ASC_ISSUER" "$BUNDLE_ID"
    PROVISIONING_PROFILE="build/profiles/$BUNDLE_ID.provisionprofile"
fi
[[ "$UPLOAD" != "1" || -n "${ASC_KEY:-}" ]] || fail "uploading needs ASC_KEY, ASC_KEY_ID and ASC_ISSUER (or UPLOAD=0)"

echo "Building Music Library $VERSION ($BUILD) for the Mac App Store…"
VERSION="$VERSION" BUILD="$BUILD" UNIVERSAL=1 SANDBOX=1 SIGN_IDENTITY="$APP_IDENTITY" \
    PROVISIONING_PROFILE="$PROVISIONING_PROFILE" scripts/build-app.sh
APP=build/MusicLibrary.app
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")" == "$BUNDLE_ID" ]] \
    || fail "the app isn't $BUNDLE_ID (is the profile for another App ID?)"

rm -rf "$OUT" && mkdir -p "$OUT"
productbuild --component "$APP" /Applications --sign "$INSTALLER_IDENTITY" "$PKG"

# Check the package the way App Store Connect will look at it.
echo "Checking $PKG…"
# An installer certificate shows as "signed by a developer certificate issued by Apple (Development)"; what matters is
# that it's signed, by the installer identity.
signature="$(pkgutil --check-signature "$PKG")"
grep -q "Status: signed" <<< "$signature" && grep -qF "1. $INSTALLER_IDENTITY" <<< "$signature" || {
    echo "$signature" >&2; fail "the package isn't signed with $INSTALLER_IDENTITY"
}
EXPANDED="$OUT/expanded"
pkgutil --expand-full "$PKG" "$EXPANDED"
INNER="$(find "$EXPANDED" -maxdepth 3 -name MusicLibrary.app -type d | head -1)"
[[ -d "$INNER" ]] || fail "no MusicLibrary.app in the package"
codesign --verify --strict --deep "$INNER"
entitlements() { codesign -d --entitlements - --xml "$1" 2> /dev/null | plutil -convert json -o - - 2> /dev/null; }
has() { python3 -I -c "import json,sys; e=json.load(sys.stdin); sys.exit(0 if e.get(sys.argv[1]) not in (None, False) else 1)" "$1"; }
entitlements "$INNER" | has com.apple.security.app-sandbox || fail "the app isn't sandboxed"
entitlements "$INNER" | has com.apple.application-identifier || fail "the app has no application identifier"
[[ -f "$INNER/Contents/embedded.provisionprofile" ]] || fail "no embedded provisioning profile"
for tool in "$INNER"/Contents/Helpers/*; do
    codesign --verify --strict "$tool"
    keys="$(entitlements "$tool" | python3 -I -c "import json,sys; print(' '.join(sorted(json.load(sys.stdin))))")"
    [[ "$keys" == "com.apple.security.app-sandbox com.apple.security.inherit" ]] \
        || fail "$(basename "$tool") must have only the sandbox and inherit entitlements (has: $keys)"
done
for binary in "$INNER/Contents/MacOS/MusicLibrary" "$INNER"/Contents/Helpers/*; do
    archs="$(lipo -archs "$binary")"
    [[ "$archs" == *arm64* && "$archs" == *x86_64* ]] || fail "$(basename "$binary") isn't universal ($archs)"
done
info() { /usr/libexec/PlistBuddy -c "Print :$1" "$INNER/Contents/Info.plist"; }
[[ "$(info CFBundleShortVersionString)" == "$VERSION" && "$(info CFBundleVersion)" == "$BUILD" ]] || fail "wrong version in the Info.plist"
[[ "$(info ITSAppUsesNonExemptEncryption)" == "false" ]] || fail "no ITSAppUsesNonExemptEncryption"
[[ -f "$INNER/Contents/Resources/PrivacyInfo.xcprivacy" ]] || fail "no privacy manifest"
[[ -f "$INNER/Contents/Resources/Assets.car" ]] || fail "no asset catalog (Assets.car) with the app icon"
[[ "$(info CFBundleIconName)" == "AppIcon" ]] || fail "no CFBundleIconName"
rm -rf "$EXPANDED"
echo "Checked: signed, sandboxed, universal, profile embedded, helpers inherit the sandbox."

if [[ "$UPLOAD" == "1" ]]; then
    # altool finds the key by its file name in API_PRIVATE_KEYS_DIR.
    KEYS="$(mktemp -d)"
    trap 'rm -rf "$KEYS"' EXIT
    cp "$ASC_KEY" "$KEYS/AuthKey_$ASC_KEY_ID.p8"
    API_PRIVATE_KEYS_DIR="$KEYS" xcrun altool --upload-package "$PKG" -t macos \
        --api-key "$ASC_KEY_ID" --api-issuer "$ASC_ISSUER"
    echo "Uploaded Music Library $VERSION ($BUILD) for the Mac. It shows up in App Store Connect ▸ TestFlight ▸ macOS once Apple has processed it."
else
    echo "Built $PKG ($VERSION, $BUILD); not uploaded (UPLOAD=0)"
fi
